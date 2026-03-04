import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pairing/pairing_service.dart';

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  Timer? _tickTimer;
  int _secondsRemaining = 0;

  @override
  void initState() {
    super.initState();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pairing = ref.watch(pairingProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.display_settings,
              size: 64,
              color: Color(0xFF58A6FF),
            ),
            const SizedBox(height: 24),
            const Text(
              'HA Smart Display',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Open Home Assistant → Settings → Devices & Services\nand enter the code below',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF8B949E),
                fontSize: 15,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 48),
            // Code display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF30363D), width: 1),
              ),
              child: Text(
                // Format as "123 456" for readability
                '${pairing.pairingCode.substring(0, 3)} ${pairing.pairingCode.substring(3)}',
                style: const TextStyle(
                  color: Color(0xFF58A6FF),
                  fontSize: 64,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Code expiry countdown
            _ExpiryCountdown(expiry: pairing.codeExpiry),
            const SizedBox(height: 48),
            // Device info
            Text(
              'Waiting for Home Assistant…',
              style: TextStyle(
                color: Colors.white.withOpacity(0.3),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpiryCountdown extends StatefulWidget {
  final DateTime expiry;
  const _ExpiryCountdown({required this.expiry});

  @override
  State<_ExpiryCountdown> createState() => _ExpiryCountdownState();
}

class _ExpiryCountdownState extends State<_ExpiryCountdown> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.expiry.difference(DateTime.now());
    final secs = remaining.inSeconds.clamp(0, 300);
    final mins = secs ~/ 60;
    final s = (secs % 60).toString().padLeft(2, '0');

    return Text(
      'Code expires in $mins:$s',
      style: const TextStyle(
        color: Color(0xFF8B949E),
        fontSize: 13,
      ),
    );
  }
}
