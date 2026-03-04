# ha-smart-display-app

Flutter kiosk app for Echo Show 8 (LineageOS). See root `CLAUDE.md` for full architecture.

## Quick reference

```bash
# Run on emulator
JAVA_HOME=/usr/local/opt/openjdk@17 flutter run -d emulator-5554

# Reset pairing state
adb shell pm clear com.example.ha_smart_display

# Expose port to LAN for HA testing
adb kill-server && ADB_SERVER_SOCKET=tcp:0.0.0.0:5037 adb -a nodaemon server start &
adb forward tcp:8472 tcp:8472
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
```

## Adding a new command key
1. Add field to `DisplayState` + `copyWith()` + `toJson()`
2. Handle key in `DisplayStateNotifier.applyCommand()`
3. Add corresponding entity in HA integration

## Audio asset
`assets/audio/timer_chime.mp3` — 3-note C-E-G ascending chime, ~2s, generated with numpy/ffmpeg.
Loaded via `just_audio` asset source in `TimerService._playSound()`.
