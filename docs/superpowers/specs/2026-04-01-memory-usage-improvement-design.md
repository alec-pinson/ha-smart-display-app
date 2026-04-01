# Memory Usage Improvement — Design Spec

**Date:** 2026-04-01  
**Workstream:** ha-smart-display  
**Task:** Memory usage improvement

---

## Problem

The app's baseline RSS sits at ~420 MB, leaving only ~50 MB headroom before the memory watchdog starts clearing caches (470 MB threshold) and ~100 MB before it force-restarts (520 MB). The goal is to reduce the baseline meaningfully without breaking any functionality.

The app already has good memory discipline for image/GPU memory (explicit `ui.Image.dispose()`, codec disposal, 10 MB image cache cap, `onTrimMemory` handler). The main opportunities are in native Android memory held by idle audio infrastructure and in JPEG bytes retained in state when not needed.

---

## Root Causes

### 1. Always-alive ExoPlayer instances

`just_audio`'s `AudioPlayer` wraps a native Android ExoPlayer. ExoPlayer holds native threads, codec buffers, and other infrastructure even when idle. The app currently keeps two players alive for the entire app lifetime:

- `MediaPlayerService._player` — created at construction, never disposed until app exit
- `TimerService._chimePlayer` — created at construction, never disposed until app exit

Each idle ExoPlayer consumes significant native memory (~20–50 MB). At baseline with nothing playing, these instances provide no value.

### 2. Camera snapshots retained outside camera mode

`DisplayState.cameras` holds a `Uint8List imageBytes` per camera containing the latest JPEG snapshot. These bytes are updated continuously by HA regardless of the current display mode (clock, weather, music). With 4–8 cameras at ~500 KB each, this is 2–4 MB always resident even when the cameras screen is never open.

---

## Design

### Section 1: Lazy AudioPlayer Lifecycle

All `AudioPlayer` instances become short-lived — created on first use, disposed when done. At idle, zero ExoPlayer instances exist.

**MediaPlayerService:**
- Remove eager player construction in the constructor.
- Create the player inside `play()` if one does not already exist.
- Subscribe to `playerStateStream` immediately after creation (as now, but per-player).
- On `stop()` or when the player reaches the completed/idle state, dispose the player and null the reference. Cancel the state subscription before disposal.
- All other public API (pause, resume, volume, etc.) guards against a null player gracefully.

**TimerService:**
- `_chimePlayer` becomes lazy — created when a timer or alarm fires, disposed when the user dismisses it.
- `_haAlarmPlayer`, `_sirenPlayer`, `_notificationPlayer` are already lazy-init; ensure each is explicitly disposed after playback completes (the notification player already does this; verify the others do too on stop/dismiss).

**VoiceAssistantService:**
- Already creates and disposes players per-use. No change needed.

**Net effect:** At idle (nothing playing), there are zero live ExoPlayer instances. A player exists only for the duration of its sound. Brief overlap between two sounds during transition is acceptable — the old player's `dispose()` fires as the new one starts.

---

### Section 2: Ducking Coordination

When a transient sound (notification, chime, TTS) plays while media is active, media should pause and resume automatically — but only if it was already playing (not if the user had paused it).

**Add two methods to `MediaPlayerService`:**

```dart
Future<void> pauseForDucking() async {
  _wasPlayingBeforeDuck = _isPlaying;
  if (_isPlaying) await _player?.pause();
}

Future<void> resumeAfterDucking() async {
  if (_wasPlayingBeforeDuck) await _player?.play();
  _wasPlayingBeforeDuck = false;
}
```

`_wasPlayingBeforeDuck` is a private `bool` field, defaulting to `false`.

**Callers** — `TimerService` and `VoiceAssistantService` both already hold a `Ref` and can read `MediaPlayerService`. They wrap transient sounds:

```dart
await mediaService.pauseForDucking();
try {
  await _playTransientSound();
} finally {
  await mediaService.resumeAfterDucking();
}
```

If the media player is lazily absent (player is null, nothing was playing), `pause()` and `play()` are no-ops. No new service or coordinator needed.

---

### Section 3: Camera Snapshot Cleanup

When the display mode changes away from `cameras`, clear the `imageBytes` from each `CameraData` in the state. Keep all other camera metadata (id, name, config). HA continuously pushes fresh snapshots; clearing bytes client-side is sufficient — fresh frames will arrive when the user returns to cameras mode.

**Prerequisite:** `CameraData.imageBytes` is currently typed as `Uint8List` (non-nullable). Change it to `Uint8List?` and update all read sites to null-check before use (primarily `_CameraImageWidget`, which should show a placeholder/empty state when bytes are null).

**In `DisplayStateNotifier`**, at the point where the display mode is updated:

```dart
if (newMode != 'cameras') {
  state = state.copyWith(
    cameras: state.cameras.map((c) => c.copyWith(imageBytes: null)).toList(),
  );
}
```

No protocol changes. No HA-side changes. One addition to existing mode-change logic plus the `imageBytes` nullability change.

---

## What We Are Not Changing

- Image/GPU memory handling — already correct (`ui.Image.dispose()`, codec disposal, etc.)
- `onTrimMemory` handler and memory watchdog — keep as-is
- `CachedNetworkImage` configuration — already has `memCacheWidth` everywhere
- Photo slideshow memory management — already correct
- Camera live view frame-drop pipeline — already correct
- Any app functionality, UI, or protocol behaviour

---

## Expected Outcome

- **Baseline idle RSS reduced** by freeing 2 always-alive ExoPlayer instances (~40–100 MB native)
- **Camera snapshot bytes freed** when not in cameras mode (~2–4 MB)
- **Media resumes correctly** after transient sounds, only when it was already playing
- No regressions to audio playback, camera display, or any other feature
