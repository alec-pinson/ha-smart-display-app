import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'core/pairing/pairing_service.dart';
import 'core/server/display_server.dart';
import 'core/display_state/display_state_notifier.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Landscape kiosk
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await WakelockPlus.enable();

  // Load persisted pairing state before first frame
  final alreadyPaired = await loadPairingState();

  final container = ProviderContainer(
    overrides: [
      // Inject the loaded pairing state so the notifier starts correctly
      pairingProvider.overrideWith(
        (ref) => PairingNotifier(alreadyPaired),
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
