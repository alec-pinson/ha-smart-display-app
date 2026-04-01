# Memory Usage Improvement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce baseline RSS (~420 MB) by making AudioPlayer instances lazy (created on use, disposed after) and clearing camera snapshot bytes when not in cameras mode.

**Architecture:** Three independent changes: (1) `CameraData.imageBytes` becomes nullable so bytes can be cleared, (2) `MediaPlayerService` creates/destroys its `AudioPlayer` around each use and gains `pauseForDucking`/`resumeAfterDucking` methods, (3) `TimerService._chimePlayer` becomes lazy and all transient sounds call the ducking API around playback.

**Tech Stack:** Flutter (master channel), Dart, just_audio 0.9.x, flutter_riverpod 2.x

---

## File Map

| File | Change |
|------|--------|
| `lib/core/display_state/display_state.dart` | `CameraData.imageBytes` → `Uint8List?`, add `CameraData.copyWith()` |
| `lib/core/display_state/display_state_notifier.dart` | Clear camera bytes when leaving cameras mode |
| `lib/features/ambient/ambient_screen.dart` | Update `_CameraImageWidget` + `_CameraFullScreen` for nullable imageBytes |
| `lib/core/media/media_player_service.dart` | Lazy player, ducking methods |
| `lib/core/timer/timer_service.dart` | Lazy chime player, ducking calls |
| `lib/core/voice/voice_assistant_service.dart` | Replace manual pause/resume with ducking API |
| `test/camera_data_test.dart` | Unit tests for `CameraData` nullability + `copyWith` |

---

### Task 1: Make CameraData.imageBytes nullable and add copyWith

**Files:**
- Modify: `lib/core/display_state/display_state.dart:99-114`
- Create: `test/camera_data_test.dart`

- [ ] **Step 1: Write failing tests**

Create `test/camera_data_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ha_smart_display/core/display_state/display_state.dart';

void main() {
  group('CameraData', () {
    final bytes = Uint8List.fromList([1, 2, 3]);

    test('imageBytes can be null', () {
      const cam = CameraData(id: 'camera.test', name: 'Test');
      expect(cam.imageBytes, isNull);
    });

    test('imageBytes can be set', () {
      final cam = CameraData(id: 'camera.test', name: 'Test', imageBytes: bytes);
      expect(cam.imageBytes, same(bytes));
    });

    test('copyWith clears imageBytes to null', () {
      final cam = CameraData(id: 'camera.test', name: 'Test', imageBytes: bytes);
      final cleared = cam.copyWith(imageBytes: null, clearImageBytes: true);
      expect(cleared.imageBytes, isNull);
      expect(cleared.id, 'camera.test');
      expect(cleared.name, 'Test');
    });

    test('copyWith preserves imageBytes when not clearing', () {
      final cam = CameraData(id: 'camera.test', name: 'Test', imageBytes: bytes);
      final copied = cam.copyWith(name: 'Other');
      expect(copied.imageBytes, same(bytes));
      expect(copied.name, 'Other');
    });

    test('copyWith replaces imageBytes with new value', () {
      final cam = CameraData(id: 'camera.test', name: 'Test', imageBytes: bytes);
      final newBytes = Uint8List.fromList([4, 5, 6]);
      final updated = cam.copyWith(imageBytes: newBytes);
      expect(updated.imageBytes, same(newBytes));
    });
  });
}
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
JAVA_HOME=/usr/local/opt/openjdk@17 flutter test test/camera_data_test.dart
```

Expected: compilation error — `imageBytes` is not nullable, `CameraData` has no `copyWith`.

- [ ] **Step 3: Make imageBytes nullable and add copyWith to CameraData**

In `lib/core/display_state/display_state.dart`, replace the `CameraData` class (lines 99–114) with:

```dart
class CameraData {
  final String id;
  final String name;
  final Uint8List? imageBytes;
  final CameraStreamType streamType;
  final String? frigateUrl;
  final String? go2rtcUrl;

  const CameraData({
    required this.id,
    required this.name,
    this.imageBytes,
    this.streamType = CameraStreamType.snapshot,
    this.frigateUrl,
    this.go2rtcUrl,
  });

  CameraData copyWith({
    String? id,
    String? name,
    Uint8List? imageBytes,
    bool clearImageBytes = false,
    CameraStreamType? streamType,
    String? frigateUrl,
    String? go2rtcUrl,
  }) {
    return CameraData(
      id: id ?? this.id,
      name: name ?? this.name,
      imageBytes: clearImageBytes ? null : (imageBytes ?? this.imageBytes),
      streamType: streamType ?? this.streamType,
      frigateUrl: frigateUrl ?? this.frigateUrl,
      go2rtcUrl: go2rtcUrl ?? this.go2rtcUrl,
    );
  }
```

> The rest of the class (getters `_cameraName`, `snapshotPollUrl`, `streamUrl`, `audioUrl`, `fromJson`) is unchanged.

- [ ] **Step 4: Run tests to confirm they pass**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter test test/camera_data_test.dart
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
git add lib/core/display_state/display_state.dart test/camera_data_test.dart
git commit -m "feat: make CameraData.imageBytes nullable and add copyWith"
```

---

### Task 2: Update _CameraImageWidget and _CameraFullScreen for nullable imageBytes

**Files:**
- Modify: `lib/features/ambient/ambient_screen.dart:1306-1357, 2736`

The `imageBytes` field is now `Uint8List?`. Two call sites need updating:
- `_CameraImageWidget` (line 1307): change parameter from `Uint8List` to `Uint8List?`
- `_CameraFullScreen` (line 2736): `_current.imageBytes.isNotEmpty` → null-aware check

- [ ] **Step 1: Update _CameraImageWidget to accept Uint8List?**

Replace lines 1306–1357 (`_CameraImageWidget` and `_CameraImageWidgetState`):

```dart
class _CameraImageWidget extends StatefulWidget {
  final Uint8List? imageBytes;
  final BoxFit fit;
  const _CameraImageWidget({required this.imageBytes, this.fit = BoxFit.cover});

  @override
  State<_CameraImageWidget> createState() => _CameraImageWidgetState();
}

class _CameraImageWidgetState extends State<_CameraImageWidget> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    if (widget.imageBytes != null) _load(widget.imageBytes!);
  }

  @override
  void didUpdateWidget(_CameraImageWidget old) {
    super.didUpdateWidget(old);
    if (!identical(widget.imageBytes, old.imageBytes)) {
      if (widget.imageBytes != null) {
        _load(widget.imageBytes!);
      } else {
        final old = _image;
        setState(() => _image = null);
        old?.dispose();
      }
    }
  }

  Future<void> _load(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1280);
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    final old = _image;
    setState(() => _image = frame.image);
    old?.dispose();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) return const SizedBox.expand();
    return RawImage(image: _image, fit: widget.fit);
  }
}
```

- [ ] **Step 2: Update _CameraFullScreen null check (line ~2736)**

Find this line in `_CameraFullScreen.build()`:
```dart
else if (_current.imageBytes.isNotEmpty)
  _CameraImageWidget(imageBytes: _current.imageBytes, fit: BoxFit.contain)
```

Replace with:
```dart
else if (_current.imageBytes?.isNotEmpty ?? false)
  _CameraImageWidget(imageBytes: _current.imageBytes, fit: BoxFit.contain)
```

- [ ] **Step 3: Verify the app compiles**

```bash
cd ~/git/personal/ha-smart-display/ha-smart-display-app
JAVA_HOME=/usr/local/opt/openjdk@17 flutter analyze
```

Expected: no errors. (Warnings about unused imports are fine.)

- [ ] **Step 4: Commit**

```bash
git add lib/features/ambient/ambient_screen.dart
git commit -m "feat: update _CameraImageWidget for nullable imageBytes"
```

---

### Task 3: Clear camera bytes when leaving cameras mode

**Files:**
- Modify: `lib/core/display_state/display_state_notifier.dart:641-644`

There are two places where `ambientMode` changes: `setAmbientMode()` (user swipe / UI tap) and `applyCommand()` (HA push via `ambient_mode` key). Both must clear camera bytes when the new mode is not `'cameras'`.

- [ ] **Step 1: Extract a private helper in DisplayStateNotifier**

In `lib/core/display_state/display_state_notifier.dart`, replace `setAmbientMode` (lines 641–644):

```dart
void setAmbientMode(String mode) {
  state = _applyModeChange(state, mode);
  _pushState();
}

/// Applies an ambient mode change, clearing camera bytes when leaving cameras mode.
DisplayState _applyModeChange(DisplayState current, String mode) {
  var next = current.copyWith(ambientMode: mode);
  if (mode != 'cameras') {
    next = next.copyWith(
      cameras: next.cameras.map((c) => c.copyWith(clearImageBytes: true)).toList(),
    );
  }
  return next;
}
```

- [ ] **Step 2: Update the applyCommand ambient_mode path**

Find this block in `applyCommand()` (around line 314–316):
```dart
if (payload.containsKey('ambient_mode')) {
  newState = newState.copyWith(ambientMode: payload['ambient_mode'] as String);
}
```

Replace with:
```dart
if (payload.containsKey('ambient_mode')) {
  newState = _applyModeChange(newState, payload['ambient_mode'] as String);
}
```

- [ ] **Step 3: Also update the display_modes fallback path (around line 308–312)**

Find:
```dart
newState = newState.copyWith(
  availableModes: modes,
  ambientMode: modes.contains(currentMode) ? currentMode : 'clock',
);
```

Replace with:
```dart
final newMode = modes.contains(currentMode) ? currentMode : 'clock';
newState = newState.copyWith(availableModes: modes);
newState = _applyModeChange(newState, newMode);
```

- [ ] **Step 4: Verify the app compiles**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter analyze
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add lib/core/display_state/display_state_notifier.dart
git commit -m "feat: clear camera snapshot bytes when leaving cameras mode"
```

---

### Task 4: Make MediaPlayerService._player lazy

**Files:**
- Modify: `lib/core/media/media_player_service.dart`

The player is currently created eagerly at construction. Change it to be created on first `play()` call and disposed when playback ends or `stop()` is called.

- [ ] **Step 1: Rewrite MediaPlayerService**

Replace the entire contents of `lib/core/media/media_player_service.dart` with:

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logger/logger.dart';

import '../display_state/display_state.dart';

final _log = Logger();

class MediaStatus {
  final MediaPlayerState state;
  final int positionMs;
  const MediaStatus({required this.state, required this.positionMs});
}

class MediaPlayerService {
  final _statusController = StreamController<MediaStatus>.broadcast();
  StreamSubscription? _playerStateSub;
  MediaPlayerState _currentState = MediaPlayerState.idle;
  AudioPlayer? _player;
  bool _wasPlayingBeforeDuck = false;

  Stream<MediaStatus> get statusStream => _statusController.stream;

  bool get _isPlaying => _currentState == MediaPlayerState.playing;

  AudioPlayer _ensurePlayer() {
    if (_player != null) return _player!;
    _player = AudioPlayer();
    _playerStateSub = _player!.playerStateStream.listen(_onPlayerState);
    return _player!;
  }

  void _onPlayerState(PlayerState ps) {
    final prev = _currentState;
    _currentState = _mapState(ps);
    if (_currentState != prev) {
      _emit();
    }
    // Release when transitioning TO completed/idle FROM a non-idle state.
    // The guard on `prev` prevents releasing the player immediately after creation,
    // since a new AudioPlayer emits an initial idle event before setUrl is called.
    if (prev != MediaPlayerState.idle &&
        (ps.processingState == ProcessingState.completed ||
         ps.processingState == ProcessingState.idle)) {
      _releasePlayer();
    }
  }

  void _releasePlayer() {
    _playerStateSub?.cancel();
    _playerStateSub = null;
    _player?.dispose();
    _player = null;
  }

  void _emit() {
    if (_statusController.isClosed) return;
    _statusController.add(MediaStatus(
      state: _currentState,
      positionMs: _player?.position.inMilliseconds ?? 0,
    ));
  }

  MediaPlayerState _mapState(PlayerState ps) {
    if (ps.processingState == ProcessingState.loading ||
        ps.processingState == ProcessingState.buffering) {
      return MediaPlayerState.buffering;
    }
    if (ps.processingState == ProcessingState.completed ||
        ps.processingState == ProcessingState.idle) {
      return MediaPlayerState.idle;
    }
    return ps.playing ? MediaPlayerState.playing : MediaPlayerState.paused;
  }

  Future<void> play(String url) async {
    try {
      final player = _ensurePlayer();
      await player.setUrl(url);
      await player.play();
    } catch (e) {
      _log.w('MediaPlayerService: play failed: $e');
    }
  }

  Future<void> pause() async {
    await _player?.pause();
  }

  Future<void> resume() async {
    if (_currentState == MediaPlayerState.paused) {
      await _player?.play();
    }
  }

  Future<void> stop() async {
    await _player?.stop();
    // stop() triggers processingState == idle → _onPlayerState → _releasePlayer
  }

  Future<void> seek(int ms) async {
    await _player?.seek(Duration(milliseconds: ms));
  }

  /// Pauses media for a transient sound. Records whether it was playing so
  /// [resumeAfterDucking] can conditionally resume.
  Future<void> pauseForDucking() async {
    _wasPlayingBeforeDuck = _isPlaying;
    if (_isPlaying) await _player?.pause();
  }

  /// Resumes media after a transient sound, but only if it was playing before
  /// [pauseForDucking] was called.
  Future<void> resumeAfterDucking() async {
    if (_wasPlayingBeforeDuck) await _player?.play();
    _wasPlayingBeforeDuck = false;
  }

  void dispose() {
    _playerStateSub?.cancel();
    _statusController.close();
    _player?.dispose();
    _player = null;
  }
}

final mediaPlayerServiceProvider = Provider<MediaPlayerService>((ref) {
  final service = MediaPlayerService();
  ref.onDispose(service.dispose);
  return service;
});
```

- [ ] **Step 2: Verify the app compiles**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter analyze
```

Expected: no errors.

- [ ] **Step 3: Smoke-test on emulator — verify media playback still works**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter run -d emulator-5554
adb -s emulator-5554 forward tcp:8472 tcp:8472
```

Trigger a `play_media` command from HA (or send one via WebSocket directly). Confirm audio plays, pauses, and resumes correctly. Confirm the now-playing strip appears and disappears.

- [ ] **Step 4: Commit**

```bash
git add lib/core/media/media_player_service.dart
git commit -m "feat: make MediaPlayerService AudioPlayer lazy with ducking support"
```

---

### Task 5: Make TimerService._chimePlayer lazy and add ducking

**Files:**
- Modify: `lib/core/timer/timer_service.dart`

`_chimePlayer` is currently always-alive. Make it lazy (created when a timer fires, disposed when dismissed). Wrap the notification sound in `pauseForDucking`/`resumeAfterDucking`. Wrap the chime loop similarly — pause on start, resume on dismiss.

- [ ] **Step 1: Rewrite TimerService**

Replace the entire contents of `lib/core/timer/timer_service.dart` with:

```dart
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logger/logger.dart';

import '../display_state/display_state.dart';
import '../display_state/display_state_notifier.dart';
import '../media/media_player_service.dart';

const _systemChannel = MethodChannel('ha_smart_display/system');

final _log = Logger();

class TimerService {
  final Ref _ref;
  final _firedTimers = <String>{};
  final _firedAlarms = <String>{};

  // All players are lazy — created when needed, disposed when done.
  AudioPlayer? _chimePlayer;
  AudioPlayer? _haAlarmPlayer;
  AudioPlayer? _sirenPlayer;
  int? _preSirenVolume;
  AudioPlayer? _notificationPlayer;

  Timer? _checkTimer;

  final _firingController = StreamController<FiringAlert?>.broadcast();
  Stream<FiringAlert?> get firingStream => _firingController.stream;

  TimerService(this._ref) {
    _checkTimer = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  void _check() {
    if (_firingController.isClosed) return;
    final state = _ref.read(displayStateProvider);

    for (final timer in state.timers) {
      if (timer.isExpired && !_firedTimers.contains(timer.id)) {
        _firedTimers.add(timer.id);
        _fire(FiringAlert(id: timer.id, label: timer.label, type: AlertType.timer));
      }
    }

    final now = DateTime.now();
    final nowStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    for (final alarm in state.alarms) {
      final key = '${alarm.id}_${now.day}';
      if (alarm.time == nowStr && now.second < 5 && !_firedAlarms.contains(key)) {
        _firedAlarms.add(key);
        _fire(FiringAlert(id: alarm.id, label: alarm.label, type: AlertType.alarm));
      }
    }
  }

  Future<void> _fire(FiringAlert alert) async {
    _log.i('TimerService: firing ${alert.type.name} "${alert.label}"');
    if (!_firingController.isClosed) _firingController.add(alert);
    await _startChimeLoop();
  }

  Future<void> _startChimeLoop() async {
    try {
      final mediaSvc = _ref.read(mediaPlayerServiceProvider);
      await mediaSvc.pauseForDucking();
      _chimePlayer ??= AudioPlayer();
      await _chimePlayer!.setLoopMode(LoopMode.one);
      await _chimePlayer!.setAsset('assets/audio/timer_chime.mp3');
      await _chimePlayer!.play();
    } catch (e) {
      _log.w('TimerService: could not play chime: $e');
    }
  }

  void dismiss(FiringAlert alert) {
    if (!_firingController.isClosed) _firingController.add(null);
    final notifier = _ref.read(displayStateProvider.notifier);
    if (alert.type == AlertType.timer) {
      notifier.dismissTimer(alert.id);
    } else {
      notifier.dismissAlarm(alert.id);
    }
    _chimePlayer?.stop();
    _chimePlayer?.dispose();
    _chimePlayer = null;
    _ref.read(mediaPlayerServiceProvider).resumeAfterDucking();
  }

  /// Called by HA alarm_sounding switch turning ON
  Future<void> startHaAlarm() async {
    try {
      _haAlarmPlayer ??= AudioPlayer();
      await _haAlarmPlayer!.setLoopMode(LoopMode.one);
      await _haAlarmPlayer!.setAsset('assets/audio/timer_chime.mp3');
      await _haAlarmPlayer!.play();
      _log.i('TimerService: HA alarm started');
    } catch (e) {
      _log.w('TimerService: could not start HA alarm: $e');
    }
  }

  /// Called by HA alarm_sounding switch turning OFF
  void stopHaAlarm() {
    _haAlarmPlayer?.stop();
    _haAlarmPlayer?.dispose();
    _haAlarmPlayer = null;
    _log.i('TimerService: HA alarm stopped');
  }

  /// Called by HA siren_sounding switch turning ON
  Future<void> startHaSiren() async {
    try {
      _preSirenVolume = _ref.read(displayStateProvider).volume;
      await _systemChannel.invokeMethod('setVolume', {'volume': 100});
      _sirenPlayer ??= AudioPlayer();
      await _sirenPlayer!.setLoopMode(LoopMode.one);
      await _sirenPlayer!.setAsset('assets/audio/siren.mp3');
      await _sirenPlayer!.play();
      _log.i('TimerService: HA siren started (saved volume: $_preSirenVolume)');
    } catch (e) {
      _log.w('TimerService: could not start HA siren: $e');
    }
  }

  /// Called by HA siren_sounding switch turning OFF
  Future<void> stopHaSiren() async {
    await _sirenPlayer?.stop();
    _sirenPlayer?.dispose();
    _sirenPlayer = null;
    if (_preSirenVolume != null) {
      try {
        await _systemChannel.invokeMethod('setVolume', {'volume': _preSirenVolume});
        _log.i('TimerService: HA siren stopped, volume restored to $_preSirenVolume');
      } catch (e) {
        _log.w('TimerService: could not restore volume: $e');
      }
      _preSirenVolume = null;
    } else {
      _log.i('TimerService: HA siren stopped');
    }
  }

  /// Called when a notification arrives from HA
  Future<void> playNotificationSound() async {
    final mediaSvc = _ref.read(mediaPlayerServiceProvider);
    await mediaSvc.pauseForDucking();
    try {
      _notificationPlayer?.dispose();
      _notificationPlayer = AudioPlayer();
      await _notificationPlayer!.setLoopMode(LoopMode.off);
      await _notificationPlayer!.setAsset('assets/audio/notification.mp3');
      await _notificationPlayer!.play();
      final player = _notificationPlayer!;
      player.processingStateStream
          .firstWhere((s) => s == ProcessingState.completed)
          .timeout(const Duration(seconds: 5), onTimeout: () => ProcessingState.idle)
          .then((_) {
            player.dispose();
            if (_notificationPlayer == player) _notificationPlayer = null;
            mediaSvc.resumeAfterDucking();
          });
    } catch (e) {
      _log.w('TimerService: could not play notification sound: $e');
      mediaSvc.resumeAfterDucking();
    }
  }

  void dispose() {
    _checkTimer?.cancel();
    _firingController.close();
    _chimePlayer?.dispose();
    _haAlarmPlayer?.dispose();
    _sirenPlayer?.dispose();
    _notificationPlayer?.dispose();
  }
}

enum AlertType { timer, alarm }

class FiringAlert {
  final String id;
  final String label;
  final AlertType type;
  const FiringAlert({required this.id, required this.label, required this.type});
}

final timerServiceProvider = Provider<TimerService>((ref) {
  final service = TimerService(ref);
  ref.onDispose(service.dispose);
  return service;
});
```

- [ ] **Step 2: Verify the app compiles**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter analyze
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/core/timer/timer_service.dart
git commit -m "feat: make TimerService chime player lazy with ducking support"
```

---

### Task 6: Update VoiceAssistantService to use ducking API

**Files:**
- Modify: `lib/core/voice/voice_assistant_service.dart`

`VoiceAssistantService` already has correct pause-on-wake-word / resume-on-idle logic, but it does this manually using a `_musicWasPlaying` flag and direct `mediaSvc.pause()` / `mediaSvc.resume()` calls. Replace this with the `pauseForDucking`/`resumeAfterDucking` API so all ducking goes through one path.

- [ ] **Step 1: Remove _musicWasPlaying field and replace ducking logic**

In `lib/core/voice/voice_assistant_service.dart`:

**Remove this field** (line 35):
```dart
bool _musicWasPlaying = false;
```

**In `onWakeWordDetected()`**, replace the manual music-pause block:

Old code (lines 64–71):
```dart
final mediaSvc = _ref.read(mediaPlayerServiceProvider);
final displayState = _ref.read(displayStateProvider);
final mediaState = displayState.mediaState;
_musicWasPlaying = mediaState == MediaPlayerState.playing || mediaState == MediaPlayerState.buffering;
if (_musicWasPlaying) {
  await mediaSvc.pause();
}
```

New code:
```dart
final mediaSvc = _ref.read(mediaPlayerServiceProvider);
await mediaSvc.pauseForDucking();
```

(You can also remove the `displayState` and `mediaState` local variables in that block if they're no longer used after this change — check whether `displayState` is still used lower in the same method for `wakeWordSound`. It is, so keep it but remove `mediaState` and `_musicWasPlaying`.)

**In `_resetToIdle()`**, replace the music-resume block:

Old code (lines 167–174):
```dart
if (_musicWasPlaying) {
  _musicWasPlaying = false;
  _musicResumeTimer?.cancel();
  _musicResumeTimer = Timer(const Duration(milliseconds: 1500), () {
    _musicResumeTimer = null;
    _ref.read(mediaPlayerServiceProvider).resume();
  });
}
```

New code:
```dart
_musicResumeTimer?.cancel();
_musicResumeTimer = Timer(const Duration(milliseconds: 1500), () {
  _musicResumeTimer = null;
  _ref.read(mediaPlayerServiceProvider).resumeAfterDucking();
});
```

- [ ] **Step 2: Verify the app compiles**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter analyze
```

Expected: no errors.

- [ ] **Step 3: Smoke-test on emulator**

```bash
JAVA_HOME=/usr/local/opt/openjdk@17 flutter run -d emulator-5554
adb -s emulator-5554 forward tcp:8472 tcp:8472
```

Test: start music playback from HA, then trigger wake word detection. Confirm music pauses. Complete the voice interaction. Confirm music resumes after ~1.5 seconds.

Test: trigger wake word while music is paused. Complete interaction. Confirm music does NOT resume (it was paused before, not playing).

- [ ] **Step 4: Commit**

```bash
git add lib/core/voice/voice_assistant_service.dart
git commit -m "refactor: use MediaPlayerService ducking API in VoiceAssistantService"
```

---

## Manual Verification Checklist

After all tasks are complete, verify on the Echo Show 8 or emulator:

- [ ] **Camera mode → switch to clock:** Open cameras mode, confirm tiles load. Swipe to clock. Swipe back to cameras — tiles should repopulate within a few seconds (HA resumes pushing frames).
- [ ] **Timer fires while music plays:** Start music, set a 10-second timer. When timer fires, confirm music pauses and chime loops. Dismiss timer. Confirm music resumes.
- [ ] **Notification while music plays:** Trigger a notification from HA. Confirm notification sound plays. Confirm music resumes after.
- [ ] **Wake word while music paused:** Pause music manually, trigger wake word, complete voice interaction. Confirm music stays paused.
- [ ] **Wake word while music playing:** Play music, trigger wake word, complete voice interaction. Confirm music resumes.
- [ ] **Memory baseline:** After the app has been idle for 5+ minutes with no sound playing and not in cameras mode, check RSS via HA Memory Usage sensor (or `adb shell cat /proc/$(adb shell pidof com.example.ha_smart_display)/status | grep VmRSS`). Target: meaningfully lower than ~420 MB baseline.
