# Voice Command Audio Quality Improvement

## Problem

Voice command recognition after wake word detection is hit-and-miss. Commands sometimes aren't recognized at all, and recognition degrades significantly with background noise.

Root cause: the current pipeline uses two separate audio systems — native `AudioRecord` with `VOICE_RECOGNITION` source for wake word detection, and Flutter's `record` package for command recording. This creates:

1. **Mic handoff gap** — releasing and reacquiring the microphone causes intermittent failures
2. **No audio processing** — Flutter's recorder doesn't apply noise suppression, AGC, or echo cancellation to command audio
3. **Lost audio** — a 400ms artificial delay plus trigger sound playback plus recorder initialization means 1-2 seconds of potential command audio is lost
4. **Different audio source** — Flutter's recorder may use a different Android audio source with different processing characteristics

## Solution

Unify wake word detection and command recording into a single native `AudioRecord` session in `WakeWordPlugin.kt`. The same session that runs wake word inference switches to command recording mode after detection, with Android hardware audio effects applied throughout.

## Architecture

### Data Flow

```
AudioRecord (VOICE_RECOGNITION, 16kHz mono) runs continuously
  NoiseSuppressor + AutomaticGainControl + AcousticEchoCanceler attached
  Ring buffer stores last 500ms of raw PCM
  Wake word inference runs on same audio stream

Wake word fires
  → snapshot pre-roll ring buffer
  → mode: DETECTING → WAITING
  → send "detected" via EventChannel

Flutter plays trigger sound, then calls native "start_command_recording"
  → mode: WAITING → RECORDING
  → accumulate PCM + run energy-based VAD

VAD detects end of speech (or timeout)
  → build WAV from pre-roll + command audio
  → send {"type": "command_audio", "audio": "<base64>"} via EventChannel
  → mode: RECORDING → DETECTING (with cooldown)

Flutter receives WAV, forwards to HA via WebSocket (unchanged)
```

### Native State Machine

`WakeWordPlugin` mode transitions:

- `STOPPED` — not running, no AudioRecord
- `DETECTING` — wake word inference active, ring buffer filling
- `WAITING` — wake word fired, AudioRecord still running, audio discarded, waiting for Flutter to finish trigger sound
- `RECORDING` — accumulating PCM for command, VAD active

### Audio Effects

Attached to the `AudioRecord` session at startup (same pattern as existing `AcousticEchoCanceler`):

- `NoiseSuppressor` — hardware-accelerated background noise removal
- `AutomaticGainControl` — normalizes volume for quiet/distant speech
- `AcousticEchoCanceler` — already present, prevents TTS from being picked up

All check `isAvailable()` before `create()` and degrade gracefully if hardware doesn't support them.

### Pre-roll Ring Buffer

A fixed-size circular `ShortArray` (~8000 samples = 500ms at 16kHz) written to continuously during `DETECTING` mode. On wake word detection, the buffer contents are snapshotted. This snapshot is prepended to the command audio so fast-spoken commands ("Alexa turn on the lights" with no pause) aren't clipped.

### Command Recording + VAD

Energy-based VAD ported from Dart `VoiceAssistantService._recordCommand()`:

- 200ms noise floor calibration (20 chunks at 10ms)
- Dynamic threshold: `max(noiseFloor * noiseMultiplier, minEnergyThreshold)`
- Silence duration from `vad_sensitivity` setting (relaxed=2500ms, default=1500ms, aggressive=400ms)
- 10s max duration safety cap
- On completion: build 16-bit PCM WAV (16kHz, mono), base64 encode, send via EventChannel

### MethodChannel Additions

- `start_command_recording` — accepts `vad_sensitivity` string; transitions WAITING → RECORDING
- `cancel_command_recording` — cancels in-progress recording, returns to DETECTING

### EventChannel Protocol

The existing `ha_smart_display/wake_word_events` channel is extended:

- `"detected"` — wake word fired (unchanged, string)
- `{"type": "command_audio", "audio": "<base64>", "sample_rate": 16000}` — command WAV ready (map)
- `{"type": "command_empty"}` — no speech detected (map)

## Flutter Changes

### VoiceAssistantService

Becomes an orchestrator — no longer records audio directly.

**Modified `onWakeWordDetected()`:**
1. Pause music (unchanged)
2. Play trigger sound (unchanged)
3. Call native `start_command_recording` via MethodChannel (replaces Flutter recording)
4. Listen for `command_audio` / `command_empty` on EventChannel

**Removed:**
- `AudioRecorder` instance and `record` package usage for command recording
- `_recordCommand()` method (Dart VAD, calibration, chunk buffering)
- `_computeRms()` and `_addWavHeader()` helpers
- 400ms post-wake-word delay

**Unchanged:**
- State machine (`idle → detected → listening → processing → responding`)
- TTS playback, music ducking/resume
- `_sendToHA()` — receives WAV from native instead of local recorder
- Processing timeout

### WakeWordService

Extended to handle new event types from the EventChannel:
- String `"detected"` → existing detection flow
- Map `{"type": "command_audio", ...}` → forward to VoiceAssistantService
- Map `{"type": "command_empty"}` → forward to VoiceAssistantService

## Testing

On-device validation (Echo Show 8):

- Quiet room: basic commands
- Noisy room: TV/music playing
- Fast speech: no pause after wake word (tests pre-roll)
- Distant speech: commands from across the room (tests AGC)
- No command spoken (tests `command_empty` path)
- Long command (tests 10s cap)
- Verify `NoiseSuppressor.isAvailable()` and `AutomaticGainControl.isAvailable()` return true
- Regression: wake word detection, trigger sound, music ducking, TTS playback
