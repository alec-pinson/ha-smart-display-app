# Stop voice command during firing timer — design

Task: HQ `cmo4buvpj0003te01v7csug27` ("Stop voice command during timer or alarm")
Scope: **timer-only**; alarms deferred.

## Goal

While a timer chime is firing on the device, the user says "Alexa, stop" and
the firing timer is dismissed. No new wake-word model; reuses the existing
wake word → STT → HA intent pipeline.

## Overall flow

1. Timer chime is firing (`TimerService._chimePlayer` in looped playback).
2. User says "Alexa, stop".
3. Native wake-word detector fires — `AcousticEchoCanceler` on the
   `VOICE_RECOGNITION` AudioRecord is expected to suppress the chime enough
   for "Alexa" to score above threshold. **This assumption must be validated
   on-device before building HA-side changes** (see Risks).
4. Flutter pauses the chime player immediately on detection, so VAD sees
   silence and end-of-speech is detected normally.
5. Command WAV is sent to HA; Whisper transcribes "stop"; Assist pipeline
   matches it to the existing `Voice - Control` automation.
6. `Voice - Control` calls `ha_smart_display.get_timers`, filters timers
   where `ends_at <= now().timestamp()`, and calls
   `ha_smart_display.dismiss_timer` for each.
7. Integration receives the dismissal, sends `{"timers": [...]}` to the
   device. `TimerService` removes the timer and disposes `_chimePlayer`.
8. If the command *wasn't* "stop" (e.g. "Alexa, what's the weather"), on
   return to `VoiceAssistantState.idle` and if `_chimePlayer` still exists
   and a firing alert is still active, chime is resumed.

## Device-side changes (`ha-smart-display-app`)

### `lib/core/timer/timer_service.dart`

Add:

- `pauseActiveAlerts()` — pauses (does not dispose) `_chimePlayer`,
  `_haAlarmPlayer`, `_sirenPlayer` if non-null and currently playing.
  Tracks which ones were paused so resume only affects those.
- `resumeActiveAlerts()` — resumes the players tracked by the pause call,
  but only if they still exist (not disposed by dismissal in the interim).
- Internal: a `Set<AudioPlayer>` or three booleans tracking pause state.

The existing `dismiss()` path is unchanged — it still disposes
`_chimePlayer`, which is fine: a paused-then-disposed player is the
happy-path "stop" flow, and `resumeActiveAlerts()` is a no-op on a
disposed/null player.

### Wiring to wake-word + voice-assistant lifecycle

- On wake-word detection: `TimerService` subscribes to
  `WakeWordService.detectionStream` and calls `pauseActiveAlerts()`.
- On voice-assistant return to idle: `TimerService` subscribes to
  `VoiceAssistantService.stateStream` and calls `resumeActiveAlerts()`
  when it sees `VoiceAssistantState.idle` after a non-idle state.

Both subscriptions are created in `TimerService`'s constructor (reading
the services via `_ref.read(...)`); the existing
`ref.onDispose(service.dispose)` in `timerServiceProvider` tears them
down. `TimerService.dispose()` is extended to cancel both.

### Unchanged

- `WakeWordPlugin.kt` — no native changes.
- `lib/core/wake_word/wake_word_service.dart` — no API changes.
- `lib/core/voice/voice_assistant_service.dart` — no changes.
- VAD config and recording logic — no changes.

## HA-side changes

### Integration (`ha-smart-display-integration`)

**None.** The timer dict already carries `ends_at` as a unix timestamp,
which is sufficient to identify firing timers in YAML.

### `Voice - Control` automation

Handled by the user in HA config, not in this repo. Reference shape:

```yaml
- action: ha_smart_display.get_timers
  data:
    device_id: <device_id>
  response_variable: resp
- repeat:
    for_each: >-
      {{ resp.timers
         | selectattr('ends_at', 'le', now().timestamp() | int)
         | map(attribute='id') | list }}
    sequence:
      - action: ha_smart_display.dismiss_timer
        data:
          device_id: <device_id>
          timer_id: "{{ repeat.item }}"
```

Triggered from the Assist `stop` intent.

## Out of scope

- **Alarms.** They have `time: "HH:MM"` rather than a timestamp, so the
  `ends_at <= now()` filter doesn't work. Revisit when alarm-stop is
  actually needed. Device-side alert pausing *does* include `_haAlarmPlayer`
  so the listening window stays clean even if the Alexa-stop flow isn't
  wired to alarms yet.
- **Second wake-word model** (`stop.tflite`). Deferred — no pre-trained
  model exists in the ESPHome micro-wake-word-models repo and the
  reuse-existing-wake-word path is simpler. Can be revisited if the
  "Alexa, stop" UX is too clunky.
- **Music / `MediaPlayerService._player` ducking during wake-word
  recording.** Existing behaviour unchanged; not part of this task.

## Risks / validation

- **AEC quality during chime.** The single biggest risk. If "Alexa"
  doesn't score above threshold while the chime is playing, the whole
  design fails and we need to fall back to the second-wake-word-model
  approach. **Gate implementation on a quick on-device smoke test first.**
- **Tail echo after `_chimePlayer.pause()`.** ~50ms of buffered speaker
  audio can still hit the mic before it fully silences. Usually falls off
  before the 200ms VAD calibration window completes. If this shows up as a
  problem, add a ~100ms delay between `pauseActiveAlerts()` and
  `start_command_recording`.
- **Race: user dismisses on-screen while wake-word is listening.** The
  existing `dismiss()` disposes `_chimePlayer`; `resumeActiveAlerts()` no-
  ops on null. Safe.
- **Voice - Control latency.** Timer must still exist on the integration
  side when `get_timers` runs. The device doesn't self-dismiss, only HA
  does, so the timer stays in the integration cache until the stop intent
  completes.

## Success criteria

On the Echo Show 8, with a timer firing in a moderately noisy room:

1. Say "Alexa, stop" → chime stops within ~2 seconds of command finishing.
2. Chime pauses (audibly goes silent) as soon as wake word fires.
3. Say "Alexa, what time is it?" while a timer is firing → wake word
   triggers, chime pauses, response plays, then chime resumes; timer is
   not dismissed.
4. On-screen tap dismissal during a wake-word listening window does not
   cause errors or orphaned players.
