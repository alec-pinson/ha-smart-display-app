package com.example.ha_smart_display

import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import kotlin.math.roundToInt

private const val TAG = "WakeWordPlugin"

/**
 * Full wake word detection pipeline running entirely in native Android code:
 *   AudioRecord → TFLM microfrontend (C++ JNI) → TFLite inference → sliding-window detection
 *
 * Channels:
 *   MethodChannel  ha_smart_display/wake_word
 *     start(wakeWord, featureStepSize, probabilityCutoff, slidingWindowSize)
 *     stop / pause / resume
 *   EventChannel   ha_smart_display/wake_word_events
 *     Sends the string "detected" when the wake word fires
 */
class WakeWordPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var appContext: Context

    private val mainHandler = Handler(Looper.getMainLooper())

    // Audio config
    private val SAMPLE_RATE = 16000
    private val FEATURE_STRIDE = 3  // inference every 3 frames → matches model input [1,3,40]
    // No gain: VOICE_RECOGNITION audio source applies AGC; amplifying further clips audio and distorts mel features

    // Detection config (set by start())
    private var featureStepMs = 10
    private var probabilityCutoff = 0.97f
    private var slidingWindowSize = 5

    // Runtime state
    private var audioRecord: AudioRecord? = null
    private var echoCanceller: AcousticEchoCanceler? = null
    private var audioThread: HandlerThread? = null
    private var audioHandler: Handler? = null
    private var microFrontend: MicroFrontend? = null
    private var interpreter: Interpreter? = null

    private val frameBuffer = mutableListOf<FloatArray>()
    private val probabilityWindow = mutableListOf<Float>()
    private var inputScale = 1f
    private var inputZeroPoint = 0
    private var outputScale = 0.00390625f
    private var cooldownFrames = 0
    private var loggedSampleFeatures = false

    // Peak probability tracked since last reset (including during cooldown frames).
    // Detection requires BOTH avg >= probabilityCutoff AND peakProbability >= PEAK_THRESHOLD.
    // Real wake-word audio always produces a strong spike early (typically 0.7-0.9); false
    // positives from room audio/echo only reach ~0.36 — well below the threshold.
    private var peakProbability = 0f
    private val PEAK_THRESHOLD = 0.5f

    @Volatile private var running = false
    @Volatile private var paused = false

    private var eventSink: EventChannel.EventSink? = null

    // ── FlutterPlugin ─────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "ha_smart_display/wake_word")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "ha_smart_display/wake_word_events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopAll()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    // ── MethodChannel ─────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val wakeWord = call.argument<String>("wake_word") ?: run {
                    result.error("MISSING_ARG", "wake_word required", null); return
                }
                featureStepMs     = call.argument<Int>("feature_step_size") ?: 10
                probabilityCutoff = (call.argument<Double>("probability_cutoff") ?: 0.97).toFloat()
                slidingWindowSize = call.argument<Int>("sliding_window_size") ?: 5
                startAll(wakeWord)
                result.success(null)
            }
            "stop"   -> { stopAll();          result.success(null) }
            "pause"  -> { paused = true;      result.success(null) }
            "resume" -> {
                // Respond immediately so Dart isn't blocked.
                result.success(null)
                // Poll AudioManager.isMusicActive() until speaker output stops before
                // unpausing detection. This prevents TTS audio still draining through
                // the AudioTrack buffer from re-triggering the wake word.
                // Runs on a new thread so it doesn't block the MethodChannel handler
                // or the audio loop thread.
                Thread {
                    val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val deadline = System.currentTimeMillis() + 8000L
                    while (System.currentTimeMillis() < deadline && running) {
                        if (!am.isMusicActive) break
                        Thread.sleep(100)
                    }
                    if (!running) return@Thread
                    // Extra 500ms for room echo decay after speaker goes quiet.
                    Thread.sleep(500)
                    if (!running) return@Thread
                    // All writes before the volatile paused=false are visible to the
                    // audio thread when it next reads paused (JMM happens-before).
                    probabilityWindow.clear()
                    frameBuffer.clear()
                    peakProbability = 0f
                    cooldownFrames = slidingWindowSize * 5
                    microFrontend?.reset()
                    paused = false
                    Log.d(TAG, "resume: unpaused after audio went quiet")
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    // ── EventChannel ──────────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { eventSink = sink }
    override fun onCancel(arguments: Any?) { eventSink = null }

    // ── Start / stop ──────────────────────────────────────────────────────────

    private fun startAll(wakeWord: String) {
        stopAll()

        Log.d(TAG, "startAll: wakeWord=$wakeWord isSupported=${MicroFrontend.isSupported}")
        if (!MicroFrontend.isSupported) {
            Log.e(TAG, "startAll: MicroFrontend not supported — native lib missing")
            return
        }

        // Load TFLite model from Flutter assets
        val modelBuffer = loadModelFromAssets(wakeWord)
        if (modelBuffer == null) {
            Log.e(TAG, "startAll: failed to load model for $wakeWord")
            return
        }
        val interp = Interpreter(modelBuffer)
        interpreter = interp
        Log.d(TAG, "startAll: model loaded — ${interp.inputTensorCount} inputs, ${interp.outputTensorCount} outputs")
        for (i in 0 until interp.inputTensorCount) {
            val t = interp.getInputTensor(i)
            Log.d(TAG, "  input[$i]: shape=${t.shape().toList()} type=${t.dataType()} scale=${t.quantizationParams().scale} zp=${t.quantizationParams().zeroPoint}")
        }
        for (i in 0 until interp.outputTensorCount) {
            val t = interp.getOutputTensor(i)
            Log.d(TAG, "  output[$i]: shape=${t.shape().toList()} type=${t.dataType()} scale=${t.quantizationParams().scale} zp=${t.quantizationParams().zeroPoint}")
        }

        val iqp = interp.getInputTensor(0).quantizationParams()
        inputScale = if (iqp.scale == 0f) 1f else iqp.scale
        inputZeroPoint = iqp.zeroPoint
        val oqp = interp.getOutputTensor(0).quantizationParams()
        outputScale = if (oqp.scale == 0f) 0.00390625f else oqp.scale
        Log.d(TAG, "input quant: scale=$inputScale zp=$inputZeroPoint | output quant: scale=$outputScale zp=${oqp.zeroPoint} shape=${interp.getOutputTensor(0).shape().toList()}")
        loggedSampleFeatures = false

        // Set up microfrontend
        microFrontend = MicroFrontend(SAMPLE_RATE, featureStepMs)
        frameBuffer.clear()
        probabilityWindow.clear()
        peakProbability = 0f
        cooldownFrames = slidingWindowSize * 2  // discard initial PCAN warmup frames

        // Set up AudioRecord
        val samplesPerStep = SAMPLE_RATE * featureStepMs / 1000
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val bufSize = maxOf(minBuf, samplesPerStep * 2 * 4)
        Log.d(TAG, "startAll: samplesPerStep=$samplesPerStep minBuf=$minBuf bufSize=$bufSize")

        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufSize
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "startAll: AudioRecord failed to initialize (state=${record.state})")
            record.release()
            return
        }
        audioRecord = record

        // Attach acoustic echo canceller so TTS speaker audio isn't picked up by the mic
        echoCanceller = if (AcousticEchoCanceler.isAvailable()) {
            AcousticEchoCanceler.create(record.audioSessionId)?.also { aec ->
                aec.enabled = true
                Log.d(TAG, "startAll: AcousticEchoCanceler attached (enabled=${aec.enabled})")
            }
        } else {
            Log.d(TAG, "startAll: AcousticEchoCanceler not available on this device")
            null
        }

        Log.d(TAG, "startAll: AudioRecord initialized OK")

        running = true
        paused = false

        val thread = HandlerThread("WakeWordAudio").also { it.start() }
        audioThread = thread
        audioHandler = Handler(thread.looper)
        record.startRecording()
        Log.d(TAG, "startAll: recording started")
        audioHandler!!.post { audioLoop(record, samplesPerStep) }
    }

    private fun stopAll() {
        running = false
        echoCanceller?.release(); echoCanceller = null
        audioRecord?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        audioRecord = null
        audioThread?.quitSafely(); audioThread = null; audioHandler = null
        microFrontend?.close(); microFrontend = null
        interpreter?.close(); interpreter = null
        frameBuffer.clear(); probabilityWindow.clear()
    }

    // ── Audio loop ────────────────────────────────────────────────────────────

    private fun audioLoop(record: AudioRecord, samplesPerStep: Int) {
        val buffer = ShortArray(samplesPerStep)
        while (running) {
            val read = record.read(buffer, 0, samplesPerStep)
            if (read <= 0 || paused) continue

            val fe = microFrontend ?: break

            val frames = fe.processSamples(buffer)
            frameBuffer.addAll(frames)

            // Non-overlapping blocks (matches ESPHome/HA Android): run inference every FEATURE_STRIDE frames,
            // then clear all accumulated frames — not a sliding window
            while (frameBuffer.size >= FEATURE_STRIDE) {
                val batch = frameBuffer.take(FEATURE_STRIDE)
                frameBuffer.clear()

                val probability = runInference(batch)
                processDetection(probability)
            }
        }
    }

    // ── TFLite inference ──────────────────────────────────────────────────────

    private fun runInference(batch: List<FloatArray>): Float {
        val interp = interpreter ?: return 0f

        // Skip near-zero feature batches — the model outputs spuriously high probabilities
        // (~0.93) for all-zero inputs (PCAN-suppressed silence or post-reset warmup frames).
        // Real wake word audio always has significant non-zero mel features.
        val maxFeature = batch.maxOf { frame -> frame.maxOrNull() ?: 0f }
        if (maxFeature < 1.0f) return 0f

        // Fill INT8 input ByteBuffer [1 × 3 × 40]
        val inputBuf = ByteBuffer.allocateDirect(FEATURE_STRIDE * 40)
            .also { it.order(ByteOrder.nativeOrder()) }
        for (frame in batch) {
            for (v in frame) {
                val q = ((v / inputScale) + inputZeroPoint).roundToInt().coerceIn(-128, 127)
                inputBuf.put(q.toByte())
            }
        }
        inputBuf.rewind()

        if (!loggedSampleFeatures) {
            val q8 = batch[0].take(8).map { v ->
                ((v / inputScale) + inputZeroPoint).roundToInt().coerceIn(-128, 127)
            }
            val maxFeature = batch[0].max()
            Log.d(TAG, "input INT8 (first 8): $q8  float: ${batch[0].take(8).map { "%.1f".format(it) }}  max=${"%.2f".format(maxFeature)}")
            loggedSampleFeatures = true
        }

        // Minimum 4 bytes — TFLite may write beyond 1 byte due to alignment/padding requirements
        val outputBuf = ByteBuffer.allocateDirect(4).also { it.order(ByteOrder.nativeOrder()) }

        try {
            interp.run(inputBuf, outputBuf)
        } catch (e: Exception) {
            Log.e(TAG, "inference error: $e")
            return 0f
        }

        outputBuf.rewind()
        val rawByte = outputBuf.get().toInt() and 0xFF
        val probability = rawByte * outputScale

        // Always log non-trivial outputs so we can see speech response
        if (rawByte > 5) {
            Log.d(TAG, "spike! rawByte=$rawByte prob=${"%.4f".format(probability)}")
        }
        // Log full 40-bin feature vector on strong spikes to diagnose speech pattern
        if (rawByte > 10) {
            val allBins = batch.flatMap { it.toList() }.map { "%.1f".format(it) }
            Log.d(TAG, "features40: $allBins")
        }
        return probability.coerceIn(0f, 1f)
    }

    // ── Sliding-window detection ───────────────────────────────────────────────

    private var _logThrottle = 0
    private var _featureLogCounter = 0

    private fun processDetection(probability: Float) {
        // Track peak even during cooldown — the strongest "alexa" spike typically
        // occurs in the first few frames (while PCAN is still adapting), which land
        // inside the cooldown window and would otherwise be invisible to the detector.
        peakProbability = maxOf(peakProbability, probability)

        if (cooldownFrames > 0) { cooldownFrames--; return }

        probabilityWindow.add(probability)
        if (probabilityWindow.size > slidingWindowSize) probabilityWindow.removeAt(0)

        // Log probabilities every ~50 frames (~500ms) to avoid logcat spam
        if (++_logThrottle >= 50) {
            _logThrottle = 0
            Log.d(TAG, "prob=${"%.3f".format(probability)} window=${probabilityWindow.map { "%.2f".format(it) }}")
        }
        // Re-enable feature logging every ~500 frames (~5s) so we can see feature changes
        if (++_featureLogCounter >= 500) {
            _featureLogCounter = 0
            loggedSampleFeatures = false
        }

        if (probabilityWindow.size >= slidingWindowSize) {
            val avg = probabilityWindow.sum() / slidingWindowSize
            if (avg >= probabilityCutoff && peakProbability >= PEAK_THRESHOLD) {
                Log.i(TAG, "DETECTED! avg=$avg peak=${"%.4f".format(peakProbability)}")
                // Pause immediately on the native side so the audio loop stops processing
                // before the Dart pause() round-trip arrives. Without this, TTS audio
                // from the speaker can trigger a second detection during the round-trip.
                paused = true
                peakProbability = 0f
                probabilityWindow.clear()
                // Reset microfrontend so residual wake-word audio in PCAN/noise-reduction
                // state doesn't immediately re-trigger detection
                microFrontend?.reset()
                frameBuffer.clear()
                mainHandler.post { eventSink?.success("detected") }
            } else if (avg >= probabilityCutoff) {
                Log.d(TAG, "avg=${"%.4f".format(avg)} >= cutoff but peak=${"%.4f".format(peakProbability)} < $PEAK_THRESHOLD — suppressed")
            }
        }
    }

    // ── Asset loading ─────────────────────────────────────────────────────────

    private fun loadModelFromAssets(wakeWord: String): ByteBuffer? {
        return try {
            // Flutter bundles assets under flutter_assets/ in the APK
            val afd = appContext.assets.openFd("flutter_assets/assets/models/$wakeWord.tflite")
            FileInputStream(afd.fileDescriptor).channel.map(
                FileChannel.MapMode.READ_ONLY,
                afd.startOffset,
                afd.declaredLength
            )
        } catch (e: Exception) {
            Log.e(TAG, "loadModelFromAssets: failed for $wakeWord: $e")
            null
        }
    }
}
