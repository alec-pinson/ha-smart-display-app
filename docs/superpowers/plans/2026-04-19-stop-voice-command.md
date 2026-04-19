# Stop Voice Command During Firing Timer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user say "Alexa, stop" while a timer chime is firing on the Echo Show and have that dismiss the firing timer, reusing the existing wake-word → STT → HA Assist pipeline.

**Architecture:** On wake-word detection, `TimerService` pauses any actively looping alert players (`_chimePlayer`, `_haAlarmPlayer`, `_sirenPlayer`) so VAD can detect end-of-speech cleanly. On return to `VoiceAssistantState.idle`, players that were paused are resumed — unless they were disposed by a dismissal in the interim. No native changes. No integration changes. HA side is a `Voice - Control` automation the user writes in their config.

**Tech Stack:** Flutter/Dart, Riverpod, `just_audio`, Home Assistant Assist pipeline (already configured).

**Spec:** `docs/superpowers/specs/2026-04-19-stop-voice-command-design.md`

---

### File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/core/timer/timer_service.dart` | Modify | Add `pauseActiveAlerts()` / `resumeActiveAlerts()`, wire subscriptions to wake-word and voice-assistant streams, extend `dispose()` |
| `docs/voice-control-automation.md` | Create | Reference YAML for the user's `Voice - Control` HA automation |

No new files in `android/`, no new test files (behaviour is hardware-dependent — validation is on-device).

---

### Task 1: On-device AEC smoke test (gate)

This task produces **no code**. It validates the core assumption behind the whole design: the wake-word detector can still fire "Alexa" while the timer chime is playing through the same speaker feeding the mic. If this fails, abort this plan and fall back to the second-wake-word-model approach (see spec "Risks" section).

**Files:** none.

- [ ] **Step 1: Build + install the current debug APK on the Echo Show**

The APK will include the pre-roll leak fix (`6a1758a`) and the reused-timer-id fix (`1c71d09`).

Run:
```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug
adb -s G0918309042301JB install -r build/app/outputs/flutter-apk/app-debug.apk
```

Expected: `Success` from adb.

- [ ] **Step 2: Start logcat filtered to the wake-word tag**

Run in a separate terminal:
```bash
adb -s G0918309042301JB logcat -c
adb -s G0918309042301JB logcat WakeWordPlugin:D '*:S'
```

- [ ] **Step 3: Trigger a timer that fires, then say "Alexa" over the chime**

From HA, set a 10-second timer on the device (e.g. `ha_smart_display.set_timer` with `duration_seconds: 10`). Wait for the chime to start. Say "Alexa" clearly.

Expected: a line like `WakeWordPlugin: DETECTED! avg=... peak=...` within ~2s of speaking.

- [ ] **Step 4: Dismiss the firing timer by tapping the screen**

Return the device to normal state for the next test.

- [ ] **Step 5: Record the result and decide**

- If DETECTED fires reliably (try 3–5 times): continue to Task 2.
- If it does not fire, or fires inconsistently (<~60% hit rate): **stop this plan**. Report back to the user; the fallback is the second-wake-word-model approach that was deferred earlier.

Do not commit anything for this task.

---

### Task 2: Add `pauseActiveAlerts` / `resumeActiveAlerts` to `TimerService`

**Files:**
- Modify: `lib/core/timer/timer_service.dart`

Context: three `AudioPlayer?` fields exist on `TimerService` — `_chimePlayer` (timer/alarm expiry chime), `_haAlarmPlayer` (HA `alarm_sounding` switch), `_sirenPlayer` (HA `siren_sounding` switch). All three play `setLoopMode(LoopMode.one)` content and can be active during a wake-word listening window.

- [ ] **Step 1: Add a field tracking which players were paused**

In `timer_service.dart`, add a private field near the other player fields (around line 27, after `Timer? _checkTimer;`):

```dart
  // Players that were active when a wake-word detection paused alerts.
  // Populated by pauseActiveAlerts(), drained by resumeActiveAlerts().
  final _pausedForVoice = <AudioPlayer>{};
```

- [ ] **Step 2: Add `pauseActiveAlerts()` method**

Add this method on `TimerService`, placing it after `dispose()`-style helpers but before `dispose()` itself (a natural spot is just before the `dispose()` method near the bottom of the class):

```dart
  /// Pauses any alert players currently looping so VAD can detect end-of-speech
  /// during a wake-word command recording. Called on wake-word detection.
  /// Safe to call repeatedly; no-op if nothing is playing.
  Future<void> pauseActiveAlerts() async {
    for (final player in [_chimePlayer, _haAlarmPlayer, _sirenPlayer]) {
      if (player == null) continue;
      if (_pausedForVoice.contains(player)) continue;
      if (!player.playing) continue;
      try {
        await player.pause();
        _pausedForVoice.add(player);
      } catch (e) {
        _log.w('TimerService: pause failed on alert player: $e');
      }
    }
    if (_pausedForVoice.isNotEmpty) {
      _log.d('TimerService: paused ${_pausedForVoice.length} alert player(s) for voice');
    }
  }
```

- [ ] **Step 3: Add `resumeActiveAlerts()` method**

Place it immediately after `pauseActiveAlerts()`:

```dart
  /// Resumes alert players that were paused by pauseActiveAlerts(). Silently
  /// skips players that have since been disposed (e.g. dismissed during the
  /// voice interaction). Called on VoiceAssistantState.idle.
  Future<void> resumeActiveAlerts() async {
    if (_pausedForVoice.isEmpty) return;
    // Snapshot current live players so we can tell if something was disposed.
    final live = <AudioPlayer>{};
    if (_chimePlayer != null) live.add(_chimePlayer!);
    if (_haAlarmPlayer != null) live.add(_haAlarmPlayer!);
    if (_sirenPlayer != null) live.add(_sirenPlayer!);

    for (final player in _pausedForVoice) {
      if (!live.contains(player)) continue; // disposed while paused
      try {
        await player.play();
      } catch (e) {
        _log.w('TimerService: resume failed on alert player: $e');
      }
    }
    _pausedForVoice.clear();
  }
```

- [ ] **Step 4: Run the analyzer to catch syntax / typing issues**

Run:
```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
JAVA_HOME=/usr/local/opt/openjdk@17 flutter analyze lib/core/timer/timer_service.dart
```

Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/core/timer/timer_service.dart
git commit -m "$(cat <<'EOF'
feat(timer): add pauseActiveAlerts/resumeActiveAlerts helpers

Lets loud alert playback (chime, HA alarm, siren) step aside during a
wake-word command recording so VAD can detect end-of-speech cleanly.
Not yet wired to the wake-word / voice-assistant streams.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Subscribe to wake-word detection → pause alerts

**Files:**
- Modify: `lib/core/timer/timer_service.dart`

Context: `WakeWordService` exposes `Stream<void> get detectionStream` (see `lib/core/wake_word/wake_word_service.dart:117`). The stream emits every time the native pipeline fires a wake-word detection event.

- [ ] **Step 1: Import WakeWordService**

Add alongside the existing imports near the top of `timer_service.dart`:

```dart
import '../wake_word/wake_word_service.dart';
```

- [ ] **Step 2: Add a subscription field**

Alongside the other private fields (near `Timer? _checkTimer;`):

```dart
  StreamSubscription<void>? _wakeWordSub;
```

- [ ] **Step 3: Subscribe in the constructor**

Update the constructor body — currently only starts `_checkTimer` — to also subscribe to the wake-word detection stream:

```dart
  TimerService(this._ref) {
    _checkTimer = Timer.periodic(const Duration(seconds: 1), (_) => _check());

    final wakeWordSvc = _ref.read(wakeWordServiceProvider);
    _wakeWordSub = wakeWordSvc.detectionStream.listen((_) {
      pauseActiveAlerts();
    });
  }
```

- [ ] **Step 4: Cancel the subscription in `dispose()`**

Update `dispose()` to cancel the new subscription. The existing method:

```dart
  void dispose() {
    _checkTimer?.cancel();
    _firingController.close();
    _chimePlayer?.dispose();
    _haAlarmPlayer?.dispose();
    _sirenPlayer?.dispose();
    _notificationPlayer?.dispose();
  }
```

becomes:

```dart
  void dispose() {
    _checkTimer?.cancel();
    _wakeWordSub?.cancel();
    _firingController.close();
    _chimePlayer?.dispose();
    _haAlarmPlayer?.dispose();
    _sirenPlayer?.dispose();
    _notificationPlayer?.dispose();
  }
```

- [ ] **Step 5: Analyze**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter analyze lib/core/timer/timer_service.dart
```

Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/core/timer/timer_service.dart
git commit -m "$(cat <<'EOF'
feat(timer): pause alerts on wake-word detection

TimerService now subscribes to WakeWordService.detectionStream and pauses
chime/alarm/siren players when the wake word fires, so the following
command recording's VAD isn't blocked by the alert audio.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Subscribe to voice-assistant state → resume alerts on idle

**Files:**
- Modify: `lib/core/timer/timer_service.dart`

Context: `VoiceAssistantService` exposes `Stream<VoiceAssistantState> get stateStream` (see `lib/core/voice/voice_assistant_service.dart:20`). The state machine is `idle → detected → listening → processing → responding → idle`. We want to resume alerts when the service returns to `idle` after any non-idle state — i.e. the voice interaction has ended.

`resumeActiveAlerts()` is already a no-op when nothing is paused, so we don't need to track transitions ourselves. We just call it on every `idle` event.

- [ ] **Step 1: Import VoiceAssistantService**

Add alongside the `wake_word_service` import:

```dart
import '../voice/voice_assistant_service.dart';
```

- [ ] **Step 2: Add a subscription field**

Alongside `_wakeWordSub`:

```dart
  StreamSubscription<VoiceAssistantState>? _voiceStateSub;
```

- [ ] **Step 3: Subscribe in the constructor**

Extend the constructor body to also subscribe to the voice-assistant state stream:

```dart
  TimerService(this._ref) {
    _checkTimer = Timer.periodic(const Duration(seconds: 1), (_) => _check());

    final wakeWordSvc = _ref.read(wakeWordServiceProvider);
    _wakeWordSub = wakeWordSvc.detectionStream.listen((_) {
      pauseActiveAlerts();
    });

    final voiceSvc = _ref.read(voiceAssistantServiceProvider);
    _voiceStateSub = voiceSvc.stateStream.listen((state) {
      if (state == VoiceAssistantState.idle) {
        resumeActiveAlerts();
      }
    });
  }
```

- [ ] **Step 4: Cancel the subscription in `dispose()`**

Update `dispose()`:

```dart
  void dispose() {
    _checkTimer?.cancel();
    _wakeWordSub?.cancel();
    _voiceStateSub?.cancel();
    _firingController.close();
    _chimePlayer?.dispose();
    _haAlarmPlayer?.dispose();
    _sirenPlayer?.dispose();
    _notificationPlayer?.dispose();
  }
```

- [ ] **Step 5: Analyze**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter analyze lib/core/timer/timer_service.dart
```

Expected: `No issues found!`

- [ ] **Step 6: Run the existing test suite to make sure nothing regressed**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter test
```

Expected: all tests pass (only `camera_data_test.dart` + `widget_test.dart` exist today; neither touches `TimerService` so they should remain green).

- [ ] **Step 7: Commit**

```bash
git add lib/core/timer/timer_service.dart
git commit -m "$(cat <<'EOF'
feat(timer): resume alerts when voice assistant returns to idle

TimerService watches VoiceAssistantService.stateStream and resumes
previously-paused alert players when the voice interaction ends.
Disposed players (e.g. dismissed via "Alexa, stop") are silently skipped.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: On-device end-to-end validation

**Files:** none.

Build and install the updated APK, then walk through each success criterion from the spec. Logcat helps but the primary verification is audible / visual.

- [ ] **Step 1: Build + install**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug
adb -s G0918309042301JB install -r build/app/outputs/flutter-apk/app-debug.apk
```

- [ ] **Step 2: Start logcat**

In a separate terminal:
```bash
adb -s G0918309042301JB logcat -c
adb -s G0918309042301JB logcat WakeWordPlugin:D flutter:V '*:S'
```

- [ ] **Step 3: Verify chime pauses on wake-word detection**

Set a 10s timer. Let the chime start. Say "Alexa, what time is it?".

Expected:
- The chime audibly pauses within ~200ms of "Alexa".
- Logcat shows `WakeWordPlugin: DETECTED!` followed (via Flutter log) by `TimerService: paused 1 alert player(s) for voice`.
- The rest of the voice interaction proceeds normally (trigger sound, STT response, TTS reply).
- After the TTS response, chime audibly resumes.

Dismiss the firing timer with a tap to clean up.

- [ ] **Step 4: Verify chime is gone after remote dismissal**

At this stage the user's `Voice - Control` HA automation may not exist yet, so this step simulates the "HA dismisses the firing timer" outcome by using the HA service directly. While a timer is firing:

```
Developer Tools → Actions → ha_smart_display.dismiss_timer
   device_id: <your device>
   timer_id: voice_timer   (or whatever id fired)
```

Expected: chime stops and does not resume.

Now run the full sequence with the voice pipeline in play:
1. Set a timer. Let it fire.
2. Say "Alexa, stop" (assumes default "stop" intent routing or the user's `Voice - Control` automation is not yet wired — this checks the Flutter side regardless of intent outcome).
3. Observe: chime pauses on detection. STT runs. If the intent dismisses the timer on the HA side, the integration sends a `timers` update that removes the firing timer → `_chimePlayer` is disposed → `resumeActiveAlerts()` sees the disposed player and skips it → chime stays silent.
4. If the intent does **not** dismiss the timer (because the automation isn't wired yet), chime resumes after TTS response. That's also correct behaviour — it becomes "stops" once Task 6 is in place.

- [ ] **Step 5: Verify tap-dismiss during listening doesn't leak**

Trigger a chime. Say "Alexa" (chime pauses). Immediately tap to dismiss the timer on-screen while the app is still in `listening` / `processing`. Let the voice flow complete.

Expected:
- No crash, no Flutter errors in logcat.
- Chime stays silent (it's disposed).
- `TimerService: paused 1 alert player(s) for voice` logged; no corresponding resume log (because the resume path sees the disposed player and skips it).

- [ ] **Step 6: Verify no regression for non-chime voice commands**

With no timer firing, say "Alexa, what time is it?".

Expected: existing voice flow is unchanged. No "paused N alert players" log line.

- [ ] **Step 7: Report results**

If all steps pass, proceed to Task 6. If any step fails, diagnose before handing the feature off — do not leave partially-working voice flows in place.

No commit in this task.

---

### Task 6: Write reference automation for the user's `Voice - Control`

**Files:**
- Create: `docs/voice-control-automation.md`

Context: The HA-side automation lives in the user's own HA config (`configuration.yaml` or `automations.yaml`), not in this repo. This task produces a reference document in this repo that documents the expected shape so the user can copy / adapt it.

- [ ] **Step 1: Create the reference document**

Create `docs/voice-control-automation.md` with the following content (replace `<YOUR_DEVICE_ID>` in the final automation):

````markdown
# Voice - Control: dismiss firing timer via "Alexa, stop"

This document describes the Home Assistant automation that completes the
"Alexa, stop" flow for firing timers on the ha-smart-display device. The
device side pauses the chime during wake-word listening (see
`docs/superpowers/specs/2026-04-19-stop-voice-command-design.md`); this
automation is what actually dismisses the timer when the user says "stop".

## Prerequisites

- An HA Assist pipeline is configured and the device's voice command flow
  works (wake word → STT → intent).
- The `stop` intent is routed to a script or automation — typically via
  the `conversation` integration's custom sentence matching or an
  `intent_script` for `HassCancelAllTimers` / similar.

## Automation body

The automation runs on the device's HA device registry ID. It reads the
timer list, filters to any timer whose `ends_at` has passed (that's what
"firing" means — the device only fires expired timers, and dismissed
timers are removed from the cache), and dismisses each one.

```yaml
alias: "Voice - Control: stop firing timer on ha-smart-display"
mode: queued
trigger:
  - platform: conversation
    command:
      - "stop"
      - "stop timer"
action:
  - action: ha_smart_display.get_timers
    data:
      device_id: <YOUR_DEVICE_ID>
    response_variable: resp
  - repeat:
      for_each: >-
        {{ resp.timers
           | selectattr('ends_at', 'le', now().timestamp() | int)
           | map(attribute='id') | list }}
      sequence:
        - action: ha_smart_display.dismiss_timer
          data:
            device_id: <YOUR_DEVICE_ID>
            timer_id: "{{ repeat.item }}"
```

## Notes

- **`<YOUR_DEVICE_ID>`** is the HA device registry ID for the
  ha-smart-display device. Find it in Settings → Devices → your device →
  "⋯" → Download diagnostics (or use the device picker in the UI when
  authoring the automation).
- The `repeat` block is a no-op if no timers are firing, so it's safe
  even when the user says "stop" at other times (the built-in Assist
  pipeline may handle it differently — this automation only dismisses a
  firing timer).
- **Alarms are out of scope.** Their payload has `time: "HH:MM"` rather
  than a unix timestamp, so the `ends_at <= now()` filter cannot be
  applied. Add alarm handling later if/when needed.
- Multiple firing timers: all are dismissed, which matches user
  expectation ("stop everything that's beeping at me").
````

- [ ] **Step 2: Commit**

```bash
git add docs/voice-control-automation.md
git commit -m "$(cat <<'EOF'
docs: add reference Voice - Control automation for firing-timer stop

Documents the HA-side YAML needed to complete the "Alexa, stop" flow
introduced in the device-side pauseActiveAlerts / resumeActiveAlerts
wiring.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Done conditions

- Tasks 2–4 committed. `flutter analyze lib/core/timer/timer_service.dart` reports `No issues found!`.
- Task 5 on-device walkthrough: all six success criteria pass.
- Task 6 reference doc committed. The user has written (or will write) the corresponding automation in their own HA config.
- Spec success criteria (see `docs/superpowers/specs/2026-04-19-stop-voice-command-design.md`) all met on-device.
