package com.alecpinson.ha_smart_display

import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
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

    private enum class Mode { STOPPED, DETECTING, WAITING, RECORDING }

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
    private var noiseSuppressor: NoiseSuppressor? = null
    private var gainControl: AutomaticGainControl? = null
    private var audioThread: HandlerThread? = null
    private var audioHandler: Handler? = null
    private var resumeThread: HandlerThread? = null
    private var resumeHandler: Handler? = null
    private var microFrontend: MicroFrontend? = null
    private var interpreter: Interpreter? = null

    // Pre-allocated inference buffers — reused on every runInference() call to avoid
    // ByteBuffer.allocateDirect() churn that leaks native memory (Android GC doesn't
    // track native pressure from the tiny Java wrapper objects).
    private var inputBuf: ByteBuffer? = null
    private var outputBuf: ByteBuffer? = null

    private val frameBuffer = mutableListOf<FloatArray>()
    private val probabilityWindow = mutableListOf<Float>()
    private var inputScale = 1f
    private var inputZeroPoint = 0
    private var outputScale = 0.00390625f
    private var cooldownFrames = 0

    // Command recording state
    private val commandChunks = mutableListOf<ShortArray>()
    private var commandTotalSamples = 0

    // VAD config (set by start_command_recording)
    private var vadSilenceThresholdMs = 1500
    private var vadNoiseMultiplier = 1.5
    private val VAD_MIN_ENERGY = 100.0
    private val VAD_MAX_DURATION_MS = 10000
    private val VAD_CALIBRATION_CHUNKS = 20  // ~200ms of noise floor sampling

    // VAD runtime state
    private var vadCalibrationCount = 0
    private var vadCalibrationRmsSum = 0.0
    private var vadCalibrated = false
    private var vadEnergyThreshold = VAD_MIN_ENERGY
    private var vadSpeechStarted = false
    private var vadSilenceMs = 0
    private var vadTotalMs = 0

    private var loggedSampleFeatures = false

    // Peak probability tracked since last reset (including during cooldown frames).
    // Detection requires BOTH avg >= probabilityCutoff AND peakProbability >= PEAK_THRESHOLD.
    // Real wake-word audio always produces a strong spike early (typically 0.7-0.9); false
    // positives from room audio/echo only reach ~0.36 — well below the threshold.
    private var peakProbability = 0f
    private val PEAK_THRESHOLD = 0.5f

    @Volatile private var mode = Mode.STOPPED

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
            "pause"  -> { mode = Mode.WAITING; result.success(null) }
            "resume" -> {
                result.success(null)
                val handler = resumeHandler ?: run { mode = Mode.DETECTING; return }
                handler.removeCallbacksAndMessages(null)
                handler.post {
                    val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val deadline = System.currentTimeMillis() + 8000L
                    while (System.currentTimeMillis() < deadline && mode != Mode.STOPPED) {
                        if (!am.isMusicActive) break
                        try { Thread.sleep(100) } catch (_: InterruptedException) { return@post }
                    }
                    if (mode == Mode.STOPPED) return@post
                    try { Thread.sleep(500) } catch (_: InterruptedException) { return@post }
                    if (mode == Mode.STOPPED) return@post
                    probabilityWindow.clear()
                    frameBuffer.clear()
                    peakProbability = 0f
                    cooldownFrames = slidingWindowSize * 5
                    microFrontend?.reset()
                    mode = Mode.DETECTING
                    Log.d(TAG, "resume: back to DETECTING after audio went quiet")
                }
            }
            "start_command_recording" -> {
                if (mode != Mode.WAITING && mode != Mode.DETECTING) {
                    result.error("INVALID_STATE", "Expected WAITING or DETECTING, got $mode", null)
                    return
                }
                val sensitivity = call.argument<String>("vad_sensitivity") ?: "default"
                when (sensitivity) {
                    "relaxed" -> { vadSilenceThresholdMs = 2500; vadNoiseMultiplier = 1.5 }
                    "aggressive" -> { vadSilenceThresholdMs = 400; vadNoiseMultiplier = 1.5 }
                    else -> { vadSilenceThresholdMs = 1500; vadNoiseMultiplier = 1.5 }
                }
                resetVadState()
                mode = Mode.RECORDING
                Log.d(TAG, "start_command_recording: sensitivity=$sensitivity silenceMs=$vadSilenceThresholdMs")
                result.success(null)
            }
            "cancel_command_recording" -> {
                if (mode == Mode.RECORDING) {
                    resetVadState()
                    probabilityWindow.clear()
                    frameBuffer.clear()
                    peakProbability = 0f
                    cooldownFrames = slidingWindowSize * 5
                    microFrontend?.reset()
                    mode = Mode.DETECTING
                    Log.d(TAG, "cancel_command_recording: back to DETECTING")
                }
                result.success(null)
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
        Log.d(TAG, "startAll: model loaded for $wakeWord")

        val iqp = interp.getInputTensor(0).quantizationParams()
        inputScale = if (iqp.scale == 0f) 1f else iqp.scale
        inputZeroPoint = iqp.zeroPoint
        val oqp = interp.getOutputTensor(0).quantizationParams()
        outputScale = if (oqp.scale == 0f) 0.00390625f else oqp.scale
        Log.d(TAG, "startAll: quant in(scale=$inputScale zp=$inputZeroPoint) out(scale=$outputScale)")
        loggedSampleFeatures = false
        inputBuf = ByteBuffer.allocateDirect(FEATURE_STRIDE * 40).also { it.order(ByteOrder.nativeOrder()) }
        outputBuf = ByteBuffer.allocateDirect(4).also { it.order(ByteOrder.nativeOrder()) }
        Log.d(TAG, "startAll: pre-allocated inference buffers (input=${FEATURE_STRIDE * 40}B, output=4B)")

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

        noiseSuppressor = if (NoiseSuppressor.isAvailable()) {
            NoiseSuppressor.create(record.audioSessionId)?.also { ns ->
                ns.enabled = true
                Log.d(TAG, "startAll: NoiseSuppressor attached (enabled=${ns.enabled})")
            }
        } else {
            Log.d(TAG, "startAll: NoiseSuppressor not available on this device")
            null
        }

        gainControl = if (AutomaticGainControl.isAvailable()) {
            AutomaticGainControl.create(record.audioSessionId)?.also { agc ->
                agc.enabled = true
                Log.d(TAG, "startAll: AutomaticGainControl attached (enabled=${agc.enabled})")
            }
        } else {
            Log.d(TAG, "startAll: AutomaticGainControl not available on this device")
            null
        }

        Log.d(TAG, "startAll: AudioRecord initialized OK")

        mode = Mode.DETECTING

        val thread = HandlerThread("WakeWordAudio").also { it.start() }
        audioThread = thread
        audioHandler = Handler(thread.looper)
        val resumeHt = HandlerThread("WakeWordResume").also { it.start() }
        resumeThread = resumeHt
        resumeHandler = Handler(resumeHt.looper)
        record.startRecording()
        Log.d(TAG, "startAll: recording started")
        audioHandler!!.post { audioLoop(record, samplesPerStep) }
    }

    private fun stopAll() {
        mode = Mode.STOPPED
        echoCanceller?.release(); echoCanceller = null
        noiseSuppressor?.release(); noiseSuppressor = null
        gainControl?.release(); gainControl = null
        audioRecord?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        audioRecord = null
        audioThread?.quitSafely(); audioThread = null; audioHandler = null
        resumeThread?.quitSafely(); resumeThread = null; resumeHandler = null
        microFrontend?.close(); microFrontend = null
        interpreter?.close(); interpreter = null
        inputBuf = null
        outputBuf = null
        resetVadState()
        frameBuffer.clear(); probabilityWindow.clear()
    }

    // ── Audio loop ────────────────────────────────────────────────────────────

    private fun audioLoop(record: AudioRecord, samplesPerStep: Int) {
        val buffer = ShortArray(samplesPerStep)
        while (mode != Mode.STOPPED) {
            val read = record.read(buffer, 0, samplesPerStep)
            if (read <= 0) continue

            when (mode) {
                Mode.DETECTING -> {
                    val fe = microFrontend ?: break
                    val frames = fe.processSamples(buffer)
                    frameBuffer.addAll(frames)
                    while (frameBuffer.size >= FEATURE_STRIDE) {
                        val batch = frameBuffer.take(FEATURE_STRIDE)
                        frameBuffer.clear()
                        val probability = runInference(batch)
                        processDetection(probability)
                    }
                }
                Mode.WAITING -> {
                    // Discard audio — waiting for Flutter trigger sound to finish
                }
                Mode.RECORDING -> {
                    val chunk = buffer.copyOfRange(0, read)
                    commandChunks.add(chunk)
                    commandTotalSamples += read
                    processVad(chunk)
                }
                Mode.STOPPED -> break
            }
        }
    }

    // ── TFLite inference ──────────────────────────────────────────────────────

    private fun runInference(batch: List<FloatArray>): Float {
        val interp = interpreter ?: return 0f
        val inBuf = inputBuf ?: return 0f
        val outBuf = outputBuf ?: return 0f

        // Skip near-zero feature batches — the model outputs spuriously high probabilities
        // (~0.93) for all-zero inputs (PCAN-suppressed silence or post-reset warmup frames).
        val maxFeature = batch.maxOf { frame -> frame.maxOrNull() ?: 0f }
        if (maxFeature < 1.0f) return 0f

        // Fill INT8 input ByteBuffer [1 x 3 x 40] — reuse pre-allocated buffer
        inBuf.rewind()
        for (frame in batch) {
            for (v in frame) {
                val q = ((v / inputScale) + inputZeroPoint).roundToInt().coerceIn(-128, 127)
                inBuf.put(q.toByte())
            }
        }
        inBuf.rewind()

        if (!loggedSampleFeatures) {
            val q8 = batch[0].take(8).map { v ->
                ((v / inputScale) + inputZeroPoint).roundToInt().coerceIn(-128, 127)
            }
            val maxFeat = batch[0].max()
            Log.d(TAG, "input INT8 (first 8): $q8  float: ${batch[0].take(8).map { "%.1f".format(it) }}  max=${"%.2f".format(maxFeat)}")
            loggedSampleFeatures = true
        }

        // Reuse pre-allocated output buffer
        outBuf.rewind()

        try {
            interp.run(inBuf, outBuf)
        } catch (e: Exception) {
            Log.e(TAG, "inference error: $e")
            return 0f
        }

        outBuf.rewind()
        val rawByte = outBuf.get().toInt() and 0xFF
        val probability = rawByte * outputScale

        if (rawByte > 20) {
            Log.d(TAG, "spike! rawByte=$rawByte prob=${"%.4f".format(probability)}")
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

        // Log probabilities every ~200 frames (~2s) to avoid logcat spam
        if (++_logThrottle >= 200) {
            _logThrottle = 0
            Log.d(TAG, "prob=${"%.3f".format(probability)} window=${probabilityWindow.map { "%.2f".format(it) }}")
        }
        // Re-enable feature logging every ~1000 frames (~10s)
        if (++_featureLogCounter >= 1000) {
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
                mode = Mode.WAITING
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

    // ── VAD helpers ─────────────────────────────────────────────────────────

    private fun resetVadState() {
        commandChunks.clear()
        commandTotalSamples = 0
        vadCalibrationCount = 0
        vadCalibrationRmsSum = 0.0
        vadCalibrated = false
        vadEnergyThreshold = VAD_MIN_ENERGY
        vadSpeechStarted = false
        vadSilenceMs = 0
        vadTotalMs = 0
    }

    private fun computeRms(samples: ShortArray): Double {
        if (samples.isEmpty()) return 0.0
        var sum = 0.0
        for (s in samples) {
            val d = s.toDouble()
            sum += d * d
        }
        return kotlin.math.sqrt(sum / samples.size)
    }

    private fun processVad(chunk: ShortArray) {
        val chunkMs = chunk.size * 1000 / SAMPLE_RATE
        vadTotalMs += chunkMs

        val rms = computeRms(chunk)

        if (!vadCalibrated) {
            vadCalibrationRmsSum += rms
            vadCalibrationCount++
            if (vadCalibrationCount >= VAD_CALIBRATION_CHUNKS) {
                val noiseFloor = vadCalibrationRmsSum / vadCalibrationCount
                vadEnergyThreshold = maxOf(noiseFloor * vadNoiseMultiplier, VAD_MIN_ENERGY)
                vadCalibrated = true
                Log.d(TAG, "VAD: calibrated noiseFloor=${"%.1f".format(noiseFloor)} threshold=${"%.1f".format(vadEnergyThreshold)}")
            }
            return
        }

        if (rms > vadEnergyThreshold) {
            vadSpeechStarted = true
            vadSilenceMs = 0
        } else if (vadSpeechStarted) {
            vadSilenceMs += chunkMs
        }

        if ((vadSpeechStarted && vadSilenceMs >= vadSilenceThresholdMs) ||
            vadTotalMs >= VAD_MAX_DURATION_MS) {
            finishCommandRecording()
        }
    }

    // ── WAV builder + command recording finish ───────────────────────────────

    private fun buildWav(samples: ShortArray, sampleRate: Int): ByteArray {
        val dataSize = samples.size * 2
        val buf = java.nio.ByteBuffer.allocate(44 + dataSize)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
        // RIFF header
        buf.put("RIFF".toByteArray(Charsets.US_ASCII))
        buf.putInt(36 + dataSize)
        buf.put("WAVE".toByteArray(Charsets.US_ASCII))
        // fmt sub-chunk
        buf.put("fmt ".toByteArray(Charsets.US_ASCII))
        buf.putInt(16)        // sub-chunk size
        buf.putShort(1)       // PCM format
        buf.putShort(1)       // mono
        buf.putInt(sampleRate)
        buf.putInt(sampleRate * 2) // byte rate
        buf.putShort(2)       // block align
        buf.putShort(16)      // bits per sample
        // data sub-chunk
        buf.put("data".toByteArray(Charsets.US_ASCII))
        buf.putInt(dataSize)
        for (s in samples) buf.putShort(s)
        return buf.array()
    }

    private fun finishCommandRecording() {
        // Switch to WAITING — Flutter will call "resume" after TTS playback
        mode = Mode.WAITING

        val totalSamples = commandTotalSamples
        val allSamples = ShortArray(totalSamples)
        var offset = 0
        for (chunk in commandChunks) {
            System.arraycopy(chunk, 0, allSamples, offset, chunk.size)
            offset += chunk.size
        }

        val speechDetected = vadSpeechStarted
        resetVadState()

        if (totalSamples == 0 || !speechDetected) {
            Log.d(TAG, "finishCommandRecording: no speech detected")
            mainHandler.post { eventSink?.success(mapOf("type" to "command_empty")) }
        } else {
            val wav = buildWav(allSamples, SAMPLE_RATE)
            val b64 = android.util.Base64.encodeToString(wav, android.util.Base64.NO_WRAP)
            Log.d(TAG, "finishCommandRecording: sent ${wav.size} bytes (${totalSamples * 1000 / SAMPLE_RATE}ms)")
            mainHandler.post {
                eventSink?.success(mapOf(
                    "type" to "command_audio",
                    "audio" to b64,
                    "sample_rate" to SAMPLE_RATE
                ))
            }
        }
    }

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
