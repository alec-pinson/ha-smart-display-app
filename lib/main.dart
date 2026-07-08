import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'core/device/app_version.dart';
import 'core/pairing/pairing_service.dart';
import 'core/server/display_server.dart';
import 'core/display_state/display_state_notifier.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final packageInfo = await PackageInfo.fromPlatform();
  appVersion = packageInfo.version;

  // Clear just_audio's on-disk asset cache so updated audio files in a
  // reinstalled APK are always picked up (cache persists across adb install -r).
  // Ignore errors on fresh install where the cache directory doesn't exist yet.
  try {
    await AudioPlayer.clearAssetCache();
  } catch (_) {}

  // Cap image cache — device only has 1GB RAM and runs 24/7.
  // Photos bypass imageCache entirely (loaded via _PhotoImageLoader + RawImage,
  // disposed explicitly on widget disposal). maximumSize = 10 covers album art,
  // weather icons, notification thumbnails, and browse items with comfortable margin.
  PaintingBinding.instance.imageCache.maximumSize = 10;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 10 * 1024 * 1024;

  // Landscape kiosk
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await WakelockPlus.enable();

  // Load persisted state before first frame
  final profileStore = await loadProfileState();
  final initialWakeWord = await loadPersistedWakeWord();
  final initialWakeWordSensitivity = await loadPersistedWakeWordSensitivity();
  final initialVadSensitivity = await loadPersistedVadSensitivity();
  final initialWakeWordSound = await loadPersistedWakeWordSound();
  final initialMicrophoneMuted = await loadPersistedMicrophoneMuted();
  final initialVolume = await loadInitialVolume();
  final initialBrightness = await loadPersistedBrightness();
  final initialAutoBrightness = await loadPersistedAutoBrightness();

  final container = ProviderContainer(
    overrides: [
      pairingProvider.overrideWith(
        (ref) => PairingNotifier(profileStore),
      ),
      displayStateProvider.overrideWith(
        (ref) => DisplayStateNotifier(ref, initialWakeWord: initialWakeWord, initialWakeWordSensitivity: initialWakeWordSensitivity, initialVadSensitivity: initialVadSensitivity, initialWakeWordSound: initialWakeWordSound, initialMicrophoneMuted: initialMicrophoneMuted, initialVolume: initialVolume, initialBrightness: initialBrightness, initialAutoBrightness: initialAutoBrightness),
      ),
    ],
  );

  // Start the WebSocket server immediately (before UI)
  await container.read(displayServerProvider).start();

  // Watch display state so it's initialized and ready to push to HA
  container.read(displayStateProvider);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const HaSmartDisplayApp(),
    ),
  );
}
