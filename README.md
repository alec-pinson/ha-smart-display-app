# HA Smart Display App

The device-side Flutter app for the [HA Smart Display](https://github.com/alec-pinson/ha-smart-display-integration) Home Assistant integration. Runs on an Amazon Echo Show 8 (LineageOS) as a full-screen kiosk that connects to Home Assistant over a local WebSocket.

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

## Requirements

- Amazon Echo Show 8 running LineageOS (or equivalent Android 8+ device with ADB access)
- [HA Smart Display integration](https://github.com/alec-pinson/ha-smart-display-integration) installed in Home Assistant

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

## Building from Source

Requires Flutter 3.x and Java 17.

```bash
flutter pub get
JAVA_HOME=/usr/local/opt/openjdk@17 flutter build apk --release
```

The release APK will be at `build/app/outputs/flutter-apk/app-release.apk`.

## Companion Integration

Configure features (weather, cameras, climate, Immich, Music Assistant, etc.) via the [HA Smart Display integration](https://github.com/alec-pinson/ha-smart-display-integration).
