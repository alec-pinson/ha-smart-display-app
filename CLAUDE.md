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
| Provider                | File                                             | Purpose                                                   |
| ----------------------- | ------------------------------------------------ | --------------------------------------------------------- |
| `deviceIdProvider`      | `core/device/device_id_service.dart`             | FutureProvider<String> — persistent UUID                  |
| `pairingProvider`       | `core/pairing/pairing_service.dart`              | StateNotifierProvider<PairingNotifier, PairingState>      |
| `displayServerProvider` | `core/server/display_server.dart`                | Provider<DisplayServer> — WebSocket server singleton      |
| `displayStateProvider`  | `core/display_state/display_state_notifier.dart` | StateNotifierProvider<DisplayStateNotifier, DisplayState> |
| `timerServiceProvider`  | `core/timer/timer_service.dart`                  | Provider<TimerService> — expiry watcher + audio           |

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
```

## Key data classes (`display_state.dart`)
| Class           | Fields                                                                         |
| --------------- | ------------------------------------------------------------------------------ |
| `DisplayState`  | all state fields incl. `photos`, `cameras`, `timers`, `alarms`, `climate`      |
| `WeatherData`   | `condition`, `temperature`, `temperatureUnit`, `humidity`, `windSpeed`, `forecast` |
| `ForecastPeriod`| `datetime`, `temperature`, `condition`, `precipitationProbability`             |
| `CameraData`    | `id`, `name`, `imageBytes` (Uint8List)                                         |
| `TimerData`     | `id`, `label`, `endsAt` (uses `remaining_seconds` from HA if present)          |
| `AlarmData`     | `id`, `label`, `time` (HH:MM — seconds stripped from HA time selector output)  |
| `ClimateData`   | `name`, `currentTemperature`, `humidity`, `targetTemperature`, `hvacMode`, `hvacModes`, `minTemp`, `maxTemp`, `unit` |

## Streams exposed by DisplayStateNotifier
| Stream                | Type              | Purpose                                            |
| --------------------- | ----------------- | -------------------------------------------------- |
| `notificationStream`  | `NotificationData`| Transient notification overlays                    |
| `focusedCameraStream` | `CameraData`      | Live camera frames for full-screen view            |
| `openCameraStream`    | `CameraData`      | HA-triggered open_camera command (empty imageBytes)|

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

## Audio (TimerService)
Two independent `AudioPlayer` instances:
- `_chimePlayer` — fires when a timer/alarm expires on-device; loops until user dismisses the alert
- `_haAlarmPlayer` — controlled by HA `alarm_sounding` command; loops until HA turns switch off

Asset: `assets/audio/timer_chime.mp3` — 3-note C-E-G ascending chime, ~2s.

## Brightness
Uses `window.attributes.screenBrightness` (Android `WindowManager.LayoutParams`) — controls
app window brightness directly. No `WRITE_SETTINGS` permission needed.

## Permissions
`permission_handler` package requests `RECORD_AUDIO` at first launch via post-frame callback
in `AmbientScreen.initState` (NOT in `main()` — the Activity isn't ready to show system
dialogs before `runApp`). Needed for future wake-word detection feature.

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
