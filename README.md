# HA Smart Display App

The device-side Flutter app for the [HA Smart Display](https://github.com/alec-pinson/ha-smart-display-integration) Home Assistant integration. Runs on an Amazon Echo Show 8 (LineageOS) as a full-screen kiosk that connects to Home Assistant over a local WebSocket.

## Screenshots

_Coming soon._

## Features

- **Weather** — real-time conditions and hourly/daily forecast
- **Cameras** — live snapshots and full-screen RTSP/go2rtc streams with audio
- **Climate** — temperature display and thermostat control
- **Timers & alarms** — synced from HA timers and alarm control panels with audio alerts
- **Music** — Music Assistant integration with track metadata, album art, and playback control
- **Photos** — rotating slideshow from static URLs or an Immich library
- **Voice assistant** — Alexa wake word with HA Assist pipeline via Wyoming protocol
- **Notifications** — push dialog, toast, and banner notifications from HA automations
- **Auto-discovery** — device appears in HA via Zeroconf (no manual IP entry needed)
- **OTA updates** — install new app versions directly from HA Settings → Updates
- **Screenshots** — capture the screen on demand from Home Assistant, for
  remote troubleshooting or grabbing images of each mode

## Requirements

- **Amazon Echo Show 8 running LineageOS.** Getting LineageOS onto an Echo Show is
  out of scope for this project — you will need to research that for your specific
  device and hardware revision before anything here is useful to you.
- Any other Android 8+ device with ADB access will also run the app, though it is
  only developed and tested against the Echo Show 8.
- [HA Smart Display integration](https://github.com/alec-pinson/ha-smart-display-integration)
  installed in Home Assistant.

## Installation

### Download APK

Download the latest `app-release.apk` from the [Releases](https://github.com/alec-pinson/ha-smart-display-app/releases/latest) page.

### Install via ADB

```bash
adb -s <device-id> install app-release.apk
```

To find your device ID: `adb devices`

### One-time setup for OTA updates

Run this once per device to allow the app to install its own updates (the standard system install dialog will still appear on screen):

```bash
adb -s <device-id> shell appops set com.alecpinson.ha_smart_display REQUEST_INSTALL_PACKAGES allow
```

## First Launch

1. Launch the app — it will display a pairing code and start advertising itself on the local network.
2. In Home Assistant, go to **Settings → Integrations**. The device will appear automatically — accept the pairing prompt and enter the code shown on screen.
3. If auto-discovery doesn't appear, click **+ Add Integration**, search for **HA Smart Display**, and enter the device's IP manually.

## OTA Updates

Once paired, the HA integration checks GitHub Releases daily for new app versions. When an update is available:

1. In HA → **Settings → Updates**, click **Install** on the "HA Smart Display App" update.
2. The app downloads the APK and the system install dialog appears on the device screen.
3. Tap **Install** — the app restarts and HA shows "Up to date".

To trigger an immediate check: HA → **Settings → Devices** → find your display → press the **Check for Updates** button.

## Multiple Home Assistant Instances

The display can be paired with more than one Home Assistant instance and switched
between them without re-pairing — useful if you run a test instance alongside your
live one.

Tap the connection dot in the top-right corner to open the **Device Status**
dialog. The dot is hidden in ambient mode, so tap the screen once to wake the
display first if you don't see it.

The **Instances** section lists every instance the display has been paired with,
shows which is currently active, and offers **Add instance** to pair another.

Only the active instance is served. The others stay connected but are held
inactive, and how they appear in Home Assistant depends on how they got there:

- An instance that has **never been active** shows the display as unavailable.
- An instance you have **switched away from** keeps its last-known state and may
  still show as available until it reconnects.

Either way it means "the display is currently on the other instance". Switching
is instant; no reconnect or restart is needed.

## Building from Source

Most users should install the APK from [Releases](https://github.com/alec-pinson/ha-smart-display-app/releases/latest)
and update over the air. Build from source only if you are modifying the app.

Requires Flutter 3.x and Java 17.

```bash
flutter pub get
JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --release
```

The release APK will be at `build/app/outputs/flutter-apk/app-release.apk`.

## Companion Integration

Configure features (weather, cameras, climate, Immich, Music Assistant, etc.) via the [HA Smart Display integration](https://github.com/alec-pinson/ha-smart-display-integration).

## Sponsor

If you find this project useful, you can support its development:

- [Ko-fi](https://ko-fi.com/alecpinson)
- [PayPal](https://paypal.me/alecpinson1)

## Licence

MIT — see [LICENSE](LICENSE).
