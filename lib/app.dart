import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/ota/ota_update_service.dart';
import 'core/pairing/pairing_service.dart';
import 'features/ambient/ambient_screen.dart';
import 'features/pairing/pairing_screen.dart';

class HaSmartDisplayApp extends ConsumerWidget {
  const HaSmartDisplayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'HA Smart Display',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF58A6FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _OtaAwareRoot(),
    );
  }
}

class _OtaAwareRoot extends ConsumerWidget {
  const _OtaAwareRoot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(otaPhaseProvider);
    return Stack(
      children: [
        const _RootRouter(),
        if (phase != OtaPhase.idle) _OtaOverlay(phase: phase),
      ],
    );
  }
}

class _OtaOverlay extends StatelessWidget {
  final OtaPhase phase;
  const _OtaOverlay({required this.phase});

  @override
  Widget build(BuildContext context) {
    final label = phase == OtaPhase.downloading ? 'Downloading update…' : 'Installing…';
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 22),
            ),
          ],
        ),
      ),
    );
  }
}

class _RootRouter extends ConsumerWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairing = ref.watch(pairingProvider);
    return pairing.isPaired ? const AmbientScreen() : const PairingScreen();
  }
}
