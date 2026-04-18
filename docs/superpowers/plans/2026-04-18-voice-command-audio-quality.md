# Voice Command Audio Quality Improvement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify wake word detection and voice command recording into a single native `AudioRecord` session with hardware audio effects (NoiseSuppressor, AGC) and a pre-roll buffer, replacing the current Flutter-side recording.

**Architecture:** The existing `WakeWordPlugin.kt` gains a mode-based state machine (STOPPED → DETECTING → WAITING → RECORDING → WAITING → DETECTING). After wake word detection, the same `AudioRecord` session switches from inference to command recording with native VAD. Flutter's `VoiceAssistantService` becomes an orchestrator that calls native methods instead of recording audio itself.

**Tech Stack:** Kotlin (Android native), Flutter/Dart, Android `AudioRecord` + `audiofx` APIs

**Spec:** `docs/superpowers/specs/2026-04-18-voice-command-audio-quality-design.md`

---

### File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `android/.../WakeWordPlugin.kt` | Modify | State machine, audio effects, pre-roll buffer, command recording + VAD |
| `lib/core/wake_word/wake_word_service.dart` | Modify | Handle new EventChannel event types, expose command audio stream, add `startCommandRecording()` |
| `lib/core/voice/voice_assistant_service.dart` | Modify | Remove Flutter recording, call native via WakeWordService, receive audio events |
| `pubspec.yaml` | Modify | Remove `record` package + dependency overrides |

---

### Task 1: Add NoiseSuppressor and AutomaticGainControl to WakeWordPlugin

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/ha_smart_display/WakeWordPlugin.kt`

- [ ] **Step 1: Add imports and fields**

At the top of WakeWordPlugin.kt, add imports alongside existing `AcousticEchoCanceler`:

```kotlin
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
```

Add fields alongside existing `echoCanceller` (after line 57):

```kotlin
private var noiseSuppressor: NoiseSuppressor? = null
private var gainControl: AutomaticGainControl? = null
```

- [ ] **Step 2: Attach effects in startAll()**

In `startAll()`, after the existing `AcousticEchoCanceler` block (after line 235), add:

```kotlin
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
```

- [ ] **Step 3: Release effects in stopAll()**

In `stopAll()`, after `echoCanceller?.release()` (line 255), add:

```kotlin
noiseSuppressor?.release(); noiseSuppressor = null
gainControl?.release(); gainControl = null
```

- [ ] **Step 4: Verify build compiles**

Run: `cd ~/git/personal/ha-smart-display/ha-smart-display-app && JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug 2>&1 | tail -5`

Expected: BUILD SUCCESSFUL

- [ ] **Step 5: Commit**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
git add android/app/src/main/kotlin/com/example/ha_smart_display/WakeWordPlugin.kt
git commit -m "feat: add NoiseSuppressor and AutomaticGainControl to wake word audio pipeline"
```

---

### Task 2: Add pre-roll ring buffer to WakeWordPlugin

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/ha_smart_display/WakeWordPlugin.kt`

- [ ] **Step 1: Add ring buffer fields**

Add constants and fields in the class body (after the `cooldownFrames` field, around line 76):

```kotlin
    // Pre-roll ring buffer — stores last 500ms of raw PCM for command recording
    private val PRE_ROLL_SAMPLES = SAMPLE_RATE / 2  // 8000 samples = 500ms at 16kHz
    private var preRollBuffer = ShortArray(PRE_ROLL_SAMPLES)
    private var preRollWritePos = 0
    private var preRollFilled = false
    private var preRollSnapshot: ShortArray? = null
```

- [ ] **Step 2: Add writePreRoll() and snapshotPreRoll() methods**

Add before the `loadModelFromAssets` method (before line 393):

```kotlin
    private fun writePreRoll(buffer: ShortArray, count: Int) {
        for (i in 0 until count) {
            preRollBuffer[preRollWritePos] = buffer[i]
            preRollWritePos = (preRollWritePos + 1) % PRE_ROLL_SAMPLES
            if (preRollWritePos == 0) preRollFilled = true
        }
    }

    private fun snapshotPreRoll(): ShortArray {
        val size = if (preRollFilled) PRE_ROLL_SAMPLES else preRollWritePos
        val snapshot = ShortArray(size)
        if (preRollFilled) {
            val tail = PRE_ROLL_SAMPLES - preRollWritePos
            System.arraycopy(preRollBuffer, preRollWritePos, snapshot, 0, tail)
            System.arraycopy(preRollBuffer, 0, snapshot, tail, preRollWritePos)
        } else {
            System.arraycopy(preRollBuffer, 0, snapshot, 0, preRollWritePos)
        }
        return snapshot
    }
```

- [ ] **Step 3: Write to ring buffer in audioLoop()**

In `audioLoop()`, after `val read = record.read(buffer, 0, samplesPerStep)` (line 272), before the `if (read <= 0 || paused) continue` check, add a call to write pre-roll. This will be refactored in Task 3 when the mode-based state machine replaces the `paused` flag — for now, add it after the existing `paused` check so wake word detection still works:

After line 273 (`if (read <= 0 || paused) continue`), add:

```kotlin
            writePreRoll(buffer, read)
```

- [ ] **Step 4: Reset ring buffer in stopAll()**

In `stopAll()`, before `frameBuffer.clear()` (line 264), add:

```kotlin
        preRollWritePos = 0; preRollFilled = false; preRollSnapshot = null
```

- [ ] **Step 5: Verify build compiles**

Run: `cd ~/git/personal/ha-smart-display/ha-smart-display-app && JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug 2>&1 | tail -5`

Expected: BUILD SUCCESSFUL

- [ ] **Step 6: Commit**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
git add android/app/src/main/kotlin/com/example/ha_smart_display/WakeWordPlugin.kt
git commit -m "feat: add pre-roll ring buffer to wake word plugin"
```

---

### Task 3: Add state machine, command recording, and VAD to WakeWordPlugin

This is the largest task. It replaces the `running`/`paused` boolean flags with a `Mode` enum, adds command recording with native energy-based VAD, WAV packaging, and new MethodChannel commands.

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/ha_smart_display/WakeWordPlugin.kt`

- [ ] **Step 1: Add Mode enum and replace running/paused fields**

Add the enum inside the class (before the field declarations):

```kotlin
    private enum class Mode { STOPPED, DETECTING, WAITING, RECORDING }
```

Replace:
```kotlin
    @Volatile private var running = false
    @Volatile private var paused = false
```
With:
```kotlin
    @Volatile private var mode = Mode.STOPPED
```

- [ ] **Step 2: Add VAD fields and command recording fields**

Add after the pre-roll fields:

```kotlin
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
```

- [ ] **Step 3: Add VAD helper methods**

Add before `loadModelFromAssets`:

```kotlin
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
```

- [ ] **Step 4: Add WAV builder and finishCommandRecording()**

Add after `processVad`:

```kotlin
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

        val preRoll = preRollSnapshot ?: ShortArray(0)
        val totalSamples = preRoll.size + commandTotalSamples
        val allSamples = ShortArray(totalSamples)
        System.arraycopy(preRoll, 0, allSamples, 0, preRoll.size)
        var offset = preRoll.size
        for (chunk in commandChunks) {
            System.arraycopy(chunk, 0, allSamples, offset, chunk.size)
            offset += chunk.size
        }

        val speechDetected = vadSpeechStarted
        resetVadState()
        preRollSnapshot = null

        if (totalSamples == 0 || !speechDetected) {
            Log.d(TAG, "finishCommandRecording: no speech detected")
            mainHandler.post { eventSink?.success(mapOf("type" to "command_empty")) }
        } else {
            val wav = buildWav(allSamples, SAMPLE_RATE)
            val b64 = android.util.Base64.encodeToString(wav, android.util.Base64.NO_WRAP)
            Log.d(TAG, "finishCommandRecording: sent ${wav.size} bytes (${totalSamples * 1000 / SAMPLE_RATE}ms, preRoll=${preRoll.size * 1000 / SAMPLE_RATE}ms)")
            mainHandler.post {
                eventSink?.success(mapOf(
                    "type" to "command_audio",
                    "audio" to b64,
                    "sample_rate" to SAMPLE_RATE
                ))
            }
        }
    }
```

- [ ] **Step 5: Rewrite audioLoop() with mode-based branching**

Replace the entire `audioLoop` method:

```kotlin
    private fun audioLoop(record: AudioRecord, samplesPerStep: Int) {
        val buffer = ShortArray(samplesPerStep)
        while (mode != Mode.STOPPED) {
            val read = record.read(buffer, 0, samplesPerStep)
            if (read <= 0) continue

            when (mode) {
                Mode.DETECTING -> {
                    writePreRoll(buffer, read)
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
```

- [ ] **Step 6: Update processDetection() to use mode + snapshot pre-roll**

In `processDetection()`, replace the block that fires the detection (lines 373-388). Find:

```kotlin
                paused = true
                peakProbability = 0f
                probabilityWindow.clear()
                microFrontend?.reset()
                frameBuffer.clear()
                mainHandler.post { eventSink?.success("detected") }
```

Replace with:

```kotlin
                mode = Mode.WAITING
                preRollSnapshot = snapshotPreRoll()
                peakProbability = 0f
                probabilityWindow.clear()
                microFrontend?.reset()
                frameBuffer.clear()
                mainHandler.post { eventSink?.success("detected") }
```

- [ ] **Step 7: Update startAll() to use mode**

In `startAll()`, replace:
```kotlin
        running = true
        paused = false
```
With:
```kotlin
        mode = Mode.DETECTING
```

- [ ] **Step 8: Update stopAll() to use mode**

In `stopAll()`, replace:
```kotlin
        running = false
```
With:
```kotlin
        mode = Mode.STOPPED
```

Also add cleanup for command recording state after the pre-roll reset line:
```kotlin
        resetVadState()
```

- [ ] **Step 9: Update onMethodCall handlers for pause/resume to use mode**

Replace the `"pause"` handler:
```kotlin
            "pause"  -> { paused = true;      result.success(null) }
```
With:
```kotlin
            "pause"  -> { mode = Mode.WAITING; result.success(null) }
```

Replace the `"resume"` handler body. Find the entire `"resume" -> { ... }` block and replace with:

```kotlin
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
                    preRollWritePos = 0
                    preRollFilled = false
                    mode = Mode.DETECTING
                    Log.d(TAG, "resume: back to DETECTING after audio went quiet")
                }
            }
```

- [ ] **Step 10: Add start_command_recording and cancel_command_recording handlers**

In `onMethodCall`, add new cases before the `else` branch:

```kotlin
            "start_command_recording" -> {
                if (mode != Mode.WAITING && mode != Mode.DETECTING) {
                    result.error("INVALID_STATE", "Expected WAITING or DETECTING, got $mode", null)
                    return
                }
                if (mode == Mode.DETECTING) {
                    preRollSnapshot = snapshotPreRoll()
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
                    preRollSnapshot = null
                    probabilityWindow.clear()
                    frameBuffer.clear()
                    peakProbability = 0f
                    cooldownFrames = slidingWindowSize * 5
                    microFrontend?.reset()
                    preRollWritePos = 0
                    preRollFilled = false
                    mode = Mode.DETECTING
                    Log.d(TAG, "cancel_command_recording: back to DETECTING")
                }
                result.success(null)
            }
```

- [ ] **Step 11: Verify build compiles**

Run: `cd ~/git/personal/ha-smart-display/ha-smart-display-app && JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug 2>&1 | tail -5`

Expected: BUILD SUCCESSFUL

- [ ] **Step 12: Commit**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
git add android/app/src/main/kotlin/com/example/ha_smart_display/WakeWordPlugin.kt
git commit -m "feat: add mode state machine, command recording, and native VAD to wake word plugin"
```

---

### Task 4: Update WakeWordService to handle new event types

**Files:**
- Modify: `lib/core/wake_word/wake_word_service.dart`

- [ ] **Step 1: Add command audio stream and startCommandRecording method**

Add a new stream controller and method to `WakeWordService`. After the `_detectionController` (line 104), add:

```dart
  final _commandAudioController = StreamController<String>.broadcast();
  Stream<String> get commandAudioStream => _commandAudioController.stream;

  final _commandEmptyController = StreamController<void>.broadcast();
  Stream<void> get commandEmptyStream => _commandEmptyController.stream;

  Future<void> startCommandRecording(String vadSensitivity) async {
    try {
      await _methodChannel.invokeMethod('start_command_recording', {
        'vad_sensitivity': vadSensitivity,
      });
    } catch (e) {
      _log.w('WakeWordService: start_command_recording failed: $e');
    }
  }

  Future<void> cancelCommandRecording() async {
    try {
      await _methodChannel.invokeMethod('cancel_command_recording');
    } catch (e) {
      _log.w('WakeWordService: cancel_command_recording failed: $e');
    }
  }
```

- [ ] **Step 2: Update EventChannel listener to handle map events**

In `start()`, replace the EventChannel listener (lines 70-75):

```dart
    _eventsSub = _eventsChannel.receiveBroadcastStream().listen(
      (event) {
        if (event == 'detected') _onDetected();
      },
      onError: (e) => _log.w('WakeWordService: event stream error: $e'),
    );
```

With:

```dart
    _eventsSub = _eventsChannel.receiveBroadcastStream().listen(
      (event) {
        if (event == 'detected') {
          _onDetected();
        } else if (event is Map) {
          final type = event['type'];
          if (type == 'command_audio') {
            final audio = event['audio'] as String;
            _commandAudioController.add(audio);
          } else if (type == 'command_empty') {
            _commandEmptyController.add(null);
          }
        }
      },
      onError: (e) => _log.w('WakeWordService: event stream error: $e'),
    );
```

- [ ] **Step 3: Close new controllers in dispose()**

Update `dispose()` to close the new controllers. Replace:

```dart
  void dispose() {
    _detectionController.close();
    unawaited(stop());
  }
```

With:

```dart
  void dispose() {
    _detectionController.close();
    _commandAudioController.close();
    _commandEmptyController.close();
    unawaited(stop());
  }
```

- [ ] **Step 4: Verify build compiles**

Run: `cd ~/git/personal/ha-smart-display/ha-smart-display-app && JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug 2>&1 | tail -5`

Expected: BUILD SUCCESSFUL

- [ ] **Step 5: Commit**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
git add lib/core/wake_word/wake_word_service.dart
git commit -m "feat: extend WakeWordService with command audio events and recording control"
```

---

### Task 5: Simplify VoiceAssistantService to use native recording

**Files:**
- Modify: `lib/core/voice/voice_assistant_service.dart`

- [ ] **Step 1: Remove Flutter recording imports and fields**

Remove these imports:

```dart
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:record/record.dart';
```

(Note: `dart:convert` and `dart:typed_data` were only used by the recording/WAV code being removed.)

Remove these fields from the class:

```dart
  final _recorder = AudioRecorder();
  bool _isRecordingCommand = false;
```

Remove these constants:

```dart
  static const _maxDurationMs = 10000;
  static const _calibrationChunks = 20;
  static const _minEnergyThreshold = 100.0;
```

Remove the `_vadParams` getter (lines 44-54).

- [ ] **Step 2: Add wake word service dependency and command subscriptions**

Add field for subscriptions after `_musicResumeTimer`:

```dart
  StreamSubscription? _commandAudioSub;
  StreamSubscription? _commandEmptySub;
```

Add import for `StreamSubscription` (already imported via `dart:async`).

Add import for wake word service:

```dart
import '../wake_word/wake_word_service.dart';
```

- [ ] **Step 3: Rewrite onWakeWordDetected()**

Replace the entire `onWakeWordDetected()` method:

```dart
  Future<void> onWakeWordDetected() async {
    if (_state != VoiceAssistantState.idle) return;
    _setState(VoiceAssistantState.detected);

    final mediaSvc = _ref.read(mediaPlayerServiceProvider);
    await mediaSvc.pauseForDucking();
    final displayState = _ref.read(displayStateProvider);

    if (displayState.wakeWordSound) {
      try {
        _triggerPlayer?.dispose();
        _triggerPlayer = AudioPlayer();
        await _triggerPlayer!.setLoopMode(LoopMode.off);
        await _triggerPlayer!.setAsset('assets/audio/wake_word_triggered.mp3');
        final completedFuture = _triggerPlayer!.processingStateStream
            .firstWhere((s) => s == ProcessingState.completed)
            .timeout(const Duration(seconds: 3), onTimeout: () => ProcessingState.idle);
        await _triggerPlayer!.play();
        await completedFuture;
        _triggerPlayer?.dispose();
        _triggerPlayer = null;
      } catch (e) {
        _log.w('VoiceAssistant: could not play trigger sound: $e');
      }
    }

    _setState(VoiceAssistantState.listening);

    // Subscribe to command audio events before starting recording
    final wakeWordSvc = _ref.read(wakeWordServiceProvider);
    _commandAudioSub?.cancel();
    _commandEmptySub?.cancel();

    _commandAudioSub = wakeWordSvc.commandAudioStream.listen((audioB64) {
      _commandAudioSub?.cancel();
      _commandEmptySub?.cancel();
      _onCommandAudio(audioB64);
    });

    _commandEmptySub = wakeWordSvc.commandEmptyStream.listen((_) {
      _commandAudioSub?.cancel();
      _commandEmptySub?.cancel();
      _log.d('VoiceAssistant: no audio captured, resetting');
      _resetToIdle();
    });

    await wakeWordSvc.startCommandRecording(displayState.vadSensitivity);
  }
```

- [ ] **Step 4: Add _onCommandAudio() method**

Add after `onWakeWordDetected()`. This sends the base64 audio string directly to HA without decoding/re-encoding:

```dart
  void _onCommandAudio(String audioB64) {
    _log.d('VoiceAssistant: received command audio from native');
    _setState(VoiceAssistantState.processing);
    try {
      _ref.read(displayServerProvider).sendEvent({
        'event': 'voice_command_audio',
        'audio': audioB64,
        'sample_rate': 16000,
        'encoding': 'wav',
      });
    } catch (e) {
      _log.w('VoiceAssistant: failed to send audio: $e');
      _resetToIdle();
      return;
    }
    _processingTimeout?.cancel();
    _processingTimeout = Timer(const Duration(seconds: 10), () {
      if (_state == VoiceAssistantState.processing) _resetToIdle();
    });
  }
```

- [ ] **Step 5: Remove old recording and sending methods**

Delete these entire methods:
- `_recordCommand()` (lines 168-258)
- `_sendToHA()` (lines 261-275) — replaced by inline send in `_onCommandAudio`
- `_computeRms()` (lines 277-287)
- `_addWavHeader()` (lines 289-314)

- [ ] **Step 6: Update dispose()**

Replace:

```dart
  void dispose() {
    _processingTimeout?.cancel();
    _musicResumeTimer?.cancel();
    _recorder.dispose();
    _ttsPlayer?.dispose();
    _triggerPlayer?.dispose();
    _stateController.close();
  }
```

With:

```dart
  void dispose() {
    _processingTimeout?.cancel();
    _musicResumeTimer?.cancel();
    _commandAudioSub?.cancel();
    _commandEmptySub?.cancel();
    _ttsPlayer?.dispose();
    _triggerPlayer?.dispose();
    _stateController.close();
  }
```

- [ ] **Step 7: Verify build compiles**

Run: `cd ~/git/personal/ha-smart-display/ha-smart-display-app && JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug 2>&1 | tail -5`

Expected: BUILD SUCCESSFUL

- [ ] **Step 8: Commit**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
git add lib/core/voice/voice_assistant_service.dart
git commit -m "feat: replace Flutter audio recording with native command recording pipeline"
```

---

### Task 6: Remove record package dependency

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: Remove record package and dependency overrides**

In `pubspec.yaml`, remove these lines:

```yaml
  # Audio recording (Phase 3)
  record: ^5.1.2
```

And remove from `dependency_overrides`:

```yaml
dependency_overrides:
  record_platform_interface: "1.4.0"
  record_linux: "1.3.0"
```

Remove the entire `dependency_overrides` section since those are the only overrides.

- [ ] **Step 2: Run flutter pub get**

Run: `cd ~/git/personal/ha-smart-display/ha-smart-display-app && flutter pub get`

Expected: resolves without errors

- [ ] **Step 3: Verify build compiles**

Run: `cd ~/git/personal/ha-smart-display/ha-smart-display-app && JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug 2>&1 | tail -5`

Expected: BUILD SUCCESSFUL

- [ ] **Step 4: Commit**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
git add pubspec.yaml pubspec.lock
git commit -m "chore: remove record package dependency (recording moved to native)"
```
