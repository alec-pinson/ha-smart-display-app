# ha-smart-display-app

Flutter kiosk app for Echo Show 8 (LineageOS). See root `CLAUDE.md` for full architecture.

## Quick reference

```bash
# Run on emulator
JAVA_HOME=/usr/local/opt/openjdk@17 flutter run -d emulator-5554

# After flutter run restarts, re-forward port (drops on each restart)
adb -s emulator-5554 forward tcp:8472 tcp:8472

# Reset pairing state
adb -s emulator-5554 shell pm clear com.example.ha_smart_display

# Build + install on Echo Show 8 (device ID: G0918309042301JB)
JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --debug
adb -s G0918309042301JB install -r build/app/outputs/flutter-apk/app-debug.apk
```

## Key providers
| Provider                     | File                                             | Purpose                                                             |
| ---------------------------- | ------------------------------------------------ | ------------------------------------------------------------------- |
| `deviceIdProvider`           | `core/device/device_id_service.dart`             | FutureProvider<String> — persistent UUID                            |
| `pairingProvider`            | `core/pairing/pairing_service.dart`              | StateNotifierProvider<PairingNotifier, PairingState>                |
| `displayServerProvider`      | `core/server/display_server.dart`                | Provider<DisplayServer> — WebSocket server singleton                |
| `displayStateProvider`       | `core/display_state/display_state_notifier.dart` | StateNotifierProvider<DisplayStateNotifier, DisplayState>; initialised with persisted wake word + sensitivity + vad_sensitivity + brightness |
| `timerServiceProvider`       | `core/timer/timer_service.dart`                  | Provider<TimerService> — expiry watcher + audio                     |
| `wakeWordServiceProvider`    | `core/wake_word/wake_word_service.dart`          | Provider<WakeWordService> — native wake word pipeline; detectionStream |
| `voiceAssistantServiceProvider` | `core/voice/voice_assistant_service.dart`     | Provider<VoiceAssistantService> — record + VAD + send to HA        |
| `cameraAnalysisServiceProvider` | `core/camera_analysis/camera_analysis_service.dart` | Provider<CameraAnalysisService> — reads hardware lux sensor via CameraAnalysisPlugin |
| `mediaPlayerServiceProvider`    | `core/media/media_player_service.dart`              | Provider<MediaPlayerService> — wraps just_audio for URL-based media playback; emits MediaStatus |

## State flow
```
HA sends command → DisplayServer._handleCommand()
  → DisplayStateNotifier.applyCommand()
  → state updated
  → DisplayServer.broadcastState() → back to HA

User dismisses timer → DisplayStateNotifier.dismissTimer()
  → DisplayServer.broadcastState(dismissedTimer: id) → HA removes it

User taps camera tile → DisplayStateNotifier.setFocusedCamera(id)
  → broadcastState(focusedCamera: id) → HA starts 1fps focused_camera_data loop
  → _CameraFullScreen subscribes to focusedCameraStream → shows live feed
  → on dismiss: setFocusedCamera(null) → HA stops fast loop

HA sends open_camera → openCameraStream fires → _CameraFullScreen dialog shown
  → same focused camera loop as above

User presses notification button → DisplayStateNotifier.sendNotificationAction()
  → DisplayServer.sendEvent({event: notification_action, button, index}) → HA event fired

User adjusts thermostat → DisplayStateNotifier.setClimateTemperature(temp) / setClimateHvacMode(mode)
  → DisplayServer.sendEvent({event: climate_set_temperature/climate_set_hvac_mode, ...}) → HA calls climate service

HA sends play_media → applyCommand() → MediaPlayerService.play(url); if title non-empty also sets mediaTrack
  → if title empty (MA flow), keep current track displayed until media_track arrives
  → MediaPlayerService emits MediaStatus every 5s while playing → _onMediaStatus() → broadcastState() → HA entity updates
  → idle state debounced 1.5s (_mediaIdleTimer) to avoid strip flickering during track changes

HA sends media_track → applyCommand() → updates mediaTrack display without affecting playback
  → used by MA integration to push real track title/artist/art when ma_media_player is configured

User taps play/pause in NowPlayingStrip → DisplayStateNotifier.sendMediaCommand()
  → play/pause/stop: MediaPlayerService acts locally; state flows back to HA via heartbeat
  → next/previous/shuffle: DisplayServer.sendEvent({event: media_command, command}) → HA forwards to MA entity if configured

User taps album art / track info in NowPlayingStrip → setAmbientMode('music') → crossfades to music display mode
  (NowPlayingStrip only visible in clock mode)

User in music display mode: _MusicScreen(isDisplayMode: true) rendered in _buildModeContent
  → initState subscribes to browseResultStream
  → user taps tab → sendBrowseRequest(category) → HA browses MA root then category → browse_result command
  → applyCommand() handles browse_result → pushes to browseResultStream → _MusicScreen updates panel
  → user taps item → sendPlayMediaItem(id, type) → HA calls media_player.play_media on MA entity → closes panel

HA sends shuffle_enabled → applyCommand() → state.shuffleEnabled updated → shuffle icon highlights
  (also sent after shuffle toggle so icon responds immediately)

HA sends immich_config → applyCommand() → DisplayState.immichConfig set (ImmichConfig{url, apiKey})
  → _AmbientPhotoSlideshow reads it; adds x-api-key header to CachedNetworkImage for Immich URLs

HA sends slideshow_interval (seconds) → applyCommand() → DisplayState.slideshowInterval updated
  → _AmbientPhotoSlideshowState.didUpdateWidget() cancels + restarts timer with new duration

HA sends photo_command: next/previous (from button entity press)
  → photoCommandStream emits → _AmbientPhotoSlideshowState._onPhotoCommand() advances _slideIndex + resets timer

Media pauses or stops → _musicInactiveTimer starts (5 min)
  → on fire: ambientMode reverts to 'clock', mediaTrack cleared → strip hides, music mode exits
  → cancelled on play/play_media/buffering

Swipe left/right on _NormalOverlay → _onSwipe() → setAmbientMode(next/prev in ['clock','weather','cameras','music'])
  → HA Display Mode entity updates automatically via broadcastState
```

## Key data classes (`display_state.dart`)
| Class           | Fields                                                                         |
| --------------- | ------------------------------------------------------------------------------ |
| `DisplayState`  | all state fields incl. `wakeWordSensitivity`, `vadSensitivity`, `lux`, `photos`, `cameras`, `timers`, `alarms`, `climate`, `mediaState`, `mediaTrack?`, `shuffleEnabled`, `doors`, `motions`, `immichConfig?`, `slideshowInterval` (seconds, default 60) |
| `PhotoItem`     | `url`, `album?`, `location?` — parsed from `photos` command; `fromJson` handles both string (legacy) and dict format |
| `ImmichConfig`  | `url`, `apiKey` — stored in DisplayState; used by slideshow to add `x-api-key` header for Immich photo URLs; never sent back to HA in `toJson()` |
| `MediaPlayerState` | enum: `idle / buffering / playing / paused`                                    |
| `MediaTrack`    | `title`, `artist?`, `album?`, `artUrl?`, `durationMs`, `positionMs`; `withPosition(ms)` for updates |
| `BrowseItem`    | `title`, `subtitle?`, `thumbnail?`, `mediaContentId`, `mediaContentType`, `canPlay`, `canExpand` |
| `BrowseResult`  | `category`, `items: List<BrowseItem>`                                          |
| `WeatherData`   | `condition`, `temperature`, `temperatureUnit`, `humidity`, `windSpeed`, `forecast` |
| `ForecastPeriod`| `datetime`, `temperature`, `condition`, `precipitationProbability`             |
| `CameraData`    | `id`, `name`, `imageBytes` (Uint8List)                                         |
| `TimerData`     | `id`, `label`, `endsAt` (uses `remaining_seconds` from HA if present)          |
| `AlarmData`     | `id`, `label`, `time` (HH:MM — seconds stripped from HA time selector output)  |
| `ClimateData`   | `name`, `currentTemperature`, `humidity`, `targetTemperature`, `hvacMode`, `hvacModes`, `minTemp`, `maxTemp`, `unit` |
| `DoorData`      | `id`, `name`, `open` — shown as chips below clock when `open == true`; icon: `door_front_door` |
| `MotionData`    | `id`, `name`, `detected` — shown as chips below door chips when `detected == true`; tapping switches to cameras mode; icon: `directions_run` |

## Streams exposed by DisplayStateNotifier
| Stream                | Type              | Purpose                                            |
| --------------------- | ----------------- | -------------------------------------------------- |
| `notificationStream`  | `NotificationData`| Transient notification overlays                    |
| `focusedCameraStream` | `CameraData`      | Live camera frames for full-screen view            |
| `openCameraStream`    | `CameraData`      | HA-triggered open_camera command (empty imageBytes)|
| `browseResultStream`  | `BrowseResult`    | MA library browse results for Music screen         |
| `photoCommandStream`  | `String`          | "next"/"previous" from HA button entities; consumed by `_AmbientPhotoSlideshowState` |

## NotificationData fields
| Field       | Type           | Default    | Notes                                                        |
| ----------- | -------------- | ---------- | ------------------------------------------------------------ |
| `title`     | String         | required   |                                                              |
| `message`   | String         | required   |                                                              |
| `imageUrl`  | String?        | null       |                                                              |
| `duration`  | int            | 10         | seconds before auto-dismiss                                  |
| `buttons`   | List\<String\> | []         | fires `notification_action` event on press                   |
| `style`     | String         | 'dialog'   | dialog / toast / banner                                      |
| `tapAction` | String?        | null       | dialog tap fires `notification_action` with index -1         |
| `position`  | String         | 'center'   | dialog alignment: center / top_left / top_center / top_right / bottom_left / bottom_center / bottom_right |

## Audio
Three independent `AudioPlayer` instances (no conflicts):
- `TimerService._chimePlayer` — fires when a timer/alarm expires on-device; loops until user dismisses
- `TimerService._haAlarmPlayer` — controlled by HA `alarm_sounding` command; loops until HA turns switch off
- `MediaPlayerService._player` — URL-based media playback (music, TTS); controlled by `play_media` / `media_command`

Asset: `assets/audio/timer_chime.mp3` — 3-note C-E-G ascending chime, ~2s.

`android:usesCleartextTraffic="true"` is set in AndroidManifest — required for ExoPlayer to fetch audio over plain HTTP from HA/MA on the local network.

## Brightness
Uses `window.attributes.screenBrightness` (Android `WindowManager.LayoutParams`) — controls
app window brightness directly. No `WRITE_SETTINGS` permission needed.

## Secure storage
`FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true))` is used
consistently across the codebase. Keys stored: `device_id`, `paired`, `pairing_code`,
`wake_word`, `wake_word_sensitivity`, `vad_sensitivity`, `brightness`, `auto_brightness`. Wake word, sensitivity,
brightness, and auto-brightness are loaded in `main()` before the `ProviderContainer` is
created, and injected via `displayStateProvider.overrideWith()`. Brightness is applied to the
screen immediately on startup from the persisted value.

## Permissions
`permission_handler` requests `RECORD_AUDIO` and `CAMERA` at first launch via post-frame
callback in `AmbientScreen.initState` (NOT in `main()` — the Activity isn't ready to show
system dialogs before `runApp`). Camera analysis `start()` is called only after the permissions
future resolves, so the light sensor never races with the permission dialog.

## Connection indicator + status dialog
Dot in top-right, hidden in ambient mode. Tap opens `_StatusDialog` showing: HA connection
state, last message timestamp, client count, local IP (from `NetworkInterface.list()`), WS
port, device ID (from `deviceIdProvider`), uptime, wake word count.

## Ambient ↔ normal crossfade
Two `AnimatedOpacity` + `IgnorePointer` pairs — both overlays always in tree, opacity
crossfades over 800ms. `AnimatedSwitcher` was dropped (unreliable with full-screen children).

## Adding a new command key
1. Add field to `DisplayState` + `copyWith()` + `toJson()`
2. Handle key in `DisplayStateNotifier.applyCommand()`
3. Add corresponding entity/service in HA integration
