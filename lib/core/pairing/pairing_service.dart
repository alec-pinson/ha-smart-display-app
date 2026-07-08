import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

import 'instance_profile.dart';

final _log = Logger();
const _kProfiles = 'profiles';
const _kLegacyPaired = 'paired';
const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// How long a pairing code is valid before rotating.
const _codeLifetime = Duration(minutes: 5);

class PairingState {
  final ProfileStore store;
  final String pairingCode;
  final DateTime codeExpiry;

  const PairingState({
    required this.store,
    required this.pairingCode,
    required this.codeExpiry,
  });

  bool get isPaired => store.isPaired;
  bool get codeValid => DateTime.now().isBefore(codeExpiry);

  PairingState copyWith({
    ProfileStore? store,
    String? pairingCode,
    DateTime? codeExpiry,
  }) =>
      PairingState(
        store: store ?? this.store,
        pairingCode: pairingCode ?? this.pairingCode,
        codeExpiry: codeExpiry ?? this.codeExpiry,
      );
}

class PairingNotifier extends StateNotifier<PairingState> {
  Timer? _rotateTimer;

  PairingNotifier(ProfileStore initial)
      : super(PairingState(
          store: initial,
          pairingCode: _generateCode(),
          codeExpiry: DateTime.now().add(_codeLifetime),
        )) {
    _scheduleRotation();
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
    state = state.copyWith(
      pairingCode: _generateCode(),
      codeExpiry: DateTime.now().add(_codeLifetime),
    );
    _scheduleRotation();
  }

  /// Generate a fresh code immediately (used when opening the Add-instance UI).
  void refreshCode() => _rotateCode();

  bool validateCode(String code) => code == state.pairingCode && state.codeValid;

  Future<void> _persist() async {
    await _storage.write(key: _kProfiles, value: jsonEncode(state.store.toJson()));
    await _storage.delete(key: _kLegacyPaired);
  }

  /// Adopt a connection as a profile without forcing it active (first-ever
  /// profile becomes active naturally). Used for the legacy-migration `hello`.
  Future<void> upsertInstance(InstanceProfile profile) async {
    state = state.copyWith(store: state.store.upsert(profile));
    await _persist();
    _log.i('PairingService: upserted ${profile.instanceId} (${profile.label})');
  }

  /// Refresh metadata/lastSeen for an already-known instance. Never changes
  /// which instance is active.
  Future<void> touchInstance(String instanceId, String label, String? host) async {
    if (!state.store.hasProfile(instanceId)) return;
    state = state.copyWith(
      store: state.store.upsert(InstanceProfile(
        instanceId: instanceId,
        label: label,
        host: host,
        lastSeen: DateTime.now(),
      )),
    );
    await _persist();
  }

  /// Pair a new instance via a valid code and make it active immediately
  /// (the user intentionally added it, so switch to it).
  Future<void> pairInstance(InstanceProfile profile) async {
    var store = state.store.upsert(profile);
    store = store.withActive(profile.instanceId);
    state = state.copyWith(store: store);
    await _persist();
    _log.i('PairingService: paired + activated ${profile.instanceId}');
  }

  Future<void> setActive(String instanceId) async {
    state = state.copyWith(store: state.store.withActive(instanceId));
    await _persist();
    _log.i('PairingService: active instance -> $instanceId');
  }

  Future<void> removeProfile(String instanceId) async {
    state = state.copyWith(store: state.store.remove(instanceId));
    await _persist();
  }

  @override
  void dispose() {
    _rotateTimer?.cancel();
    super.dispose();
  }
}

final pairingProvider =
    StateNotifierProvider<PairingNotifier, PairingState>((ref) {
  // Synchronous initial state — async load handled in main() via override.
  return PairingNotifier(const ProfileStore.empty());
});

/// Load persisted profile state at startup. Falls back to migrating the legacy
/// `paired` boolean into a `legacyPaired` store when no profiles exist yet.
Future<ProfileStore> loadProfileState() async {
  final raw = await _storage.read(key: _kProfiles);
  if (raw != null) {
    try {
      return ProfileStore.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      _log.w('PairingService: failed to parse profiles: $e');
    }
  }
  final legacy = await _storage.read(key: _kLegacyPaired);
  return ProfileStore.empty(legacyPaired: legacy == 'true');
}
