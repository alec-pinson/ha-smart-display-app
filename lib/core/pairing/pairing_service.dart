import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

final _log = Logger();
const _kPaired = 'paired';
const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// How long a pairing code is valid before rotating
const _codeLifetime = Duration(minutes: 5);

class PairingState {
  final bool isPaired;
  final String pairingCode;
  final DateTime codeExpiry;

  const PairingState({
    required this.isPaired,
    required this.pairingCode,
    required this.codeExpiry,
  });

  bool get codeValid => DateTime.now().isBefore(codeExpiry);
}

class PairingNotifier extends StateNotifier<PairingState> {
  Timer? _rotateTimer;

  PairingNotifier(bool alreadyPaired)
      : super(PairingState(
          isPaired: alreadyPaired,
          pairingCode: _generateCode(),
          codeExpiry: DateTime.now().add(_codeLifetime),
        )) {
    if (!alreadyPaired) {
      _scheduleRotation();
    }
  }

  static String _generateCode() {
    final rand = Random.secure();
    return (rand.nextInt(900000) + 100000).toString();
  }

  void _scheduleRotation() {
    _rotateTimer?.cancel();
    _rotateTimer = Timer(_codeLifetime, _rotateCode);
  }

  void _rotateCode() {
    if (state.isPaired) return;
    _log.d('PairingService: rotating pairing code');
    state = PairingState(
      isPaired: false,
      pairingCode: _generateCode(),
      codeExpiry: DateTime.now().add(_codeLifetime),
    );
    _scheduleRotation();
  }

  bool validateCode(String code) => code == state.pairingCode && state.codeValid;

  Future<void> markPaired() async {
    _rotateTimer?.cancel();
    await _storage.write(key: _kPaired, value: 'true');
    state = PairingState(
      isPaired: true,
      pairingCode: '',
      codeExpiry: DateTime.now(),
    );
    _log.i('PairingService: device paired successfully');
  }

  /// For development/reset purposes
  Future<void> unpair() async {
    await _storage.delete(key: _kPaired);
    state = PairingState(
      isPaired: false,
      pairingCode: _generateCode(),
      codeExpiry: DateTime.now().add(_codeLifetime),
    );
    _scheduleRotation();
  }

  @override
  void dispose() {
    _rotateTimer?.cancel();
    super.dispose();
  }
}

final pairingProvider =
    StateNotifierProvider<PairingNotifier, PairingState>((ref) {
  // Synchronous initial state — async load handled in main()
  return PairingNotifier(false);
});

/// Call this at startup to restore persisted pairing state
Future<bool> loadPairingState() async {
  final val = await _storage.read(key: _kPaired);
  return val == 'true';
}
