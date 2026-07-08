/// A Home Assistant instance the display can be paired with.
class InstanceProfile {
  final String instanceId;
  final String label;
  final String? host;
  final DateTime? lastSeen;

  const InstanceProfile({
    required this.instanceId,
    required this.label,
    this.host,
    this.lastSeen,
  });

  InstanceProfile copyWith({String? label, String? host, DateTime? lastSeen}) {
    return InstanceProfile(
      instanceId: instanceId,
      label: label ?? this.label,
      host: host ?? this.host,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => {
        'instanceId': instanceId,
        'label': label,
        if (host != null) 'host': host,
        if (lastSeen != null) 'lastSeen': lastSeen!.millisecondsSinceEpoch,
      };

  factory InstanceProfile.fromJson(Map<String, dynamic> j) => InstanceProfile(
        instanceId: j['instanceId'] as String,
        label: (j['label'] as String?) ?? j['instanceId'] as String,
        host: j['host'] as String?,
        lastSeen: j['lastSeen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(j['lastSeen'] as int)
            : null,
      );
}

/// How an incoming HA connection should be treated once it identifies itself.
enum ConnectionRole { serve, park, adopt, reject }

/// Immutable set of known instances plus which one is active.
///
/// [legacyPaired] is true only when migrating from the old single-boolean
/// pairing: it lets the first connecting instance be adopted without a code.
class ProfileStore {
  final List<InstanceProfile> profiles;
  final String? activeInstanceId;
  final bool legacyPaired;

  const ProfileStore({
    required this.profiles,
    required this.activeInstanceId,
    this.legacyPaired = false,
  });

  const ProfileStore.empty({this.legacyPaired = false})
      : profiles = const [],
        activeInstanceId = null;

  bool get isPaired => profiles.isNotEmpty || legacyPaired;

  bool hasProfile(String instanceId) =>
      profiles.any((p) => p.instanceId == instanceId);

  InstanceProfile? get activeProfile {
    for (final p in profiles) {
      if (p.instanceId == activeInstanceId) return p;
    }
    return null;
  }

  ConnectionRole roleFor(String instanceId) {
    if (hasProfile(instanceId)) {
      return instanceId == activeInstanceId
          ? ConnectionRole.serve
          : ConnectionRole.park;
    }
    if (legacyPaired && profiles.isEmpty) return ConnectionRole.adopt;
    return ConnectionRole.reject;
  }

  /// Add or replace a profile. The first profile ever added becomes active.
  /// Any upsert clears the legacy flag (we now have explicit profiles).
  ProfileStore upsert(InstanceProfile profile) {
    final list = [...profiles];
    final idx = list.indexWhere((p) => p.instanceId == profile.instanceId);
    if (idx >= 0) {
      list[idx] = profile;
    } else {
      list.add(profile);
    }
    return ProfileStore(
      profiles: list,
      activeInstanceId: activeInstanceId ?? profile.instanceId,
      legacyPaired: false,
    );
  }

  ProfileStore withActive(String instanceId) {
    if (!hasProfile(instanceId)) return this;
    return ProfileStore(
      profiles: profiles,
      activeInstanceId: instanceId,
      legacyPaired: false,
    );
  }

  ProfileStore remove(String instanceId) {
    final list = profiles.where((p) => p.instanceId != instanceId).toList();
    return ProfileStore(
      profiles: list,
      activeInstanceId: activeInstanceId == instanceId ? null : activeInstanceId,
      legacyPaired: legacyPaired,
    );
  }

  Map<String, dynamic> toJson() => {
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'activeInstanceId': activeInstanceId,
      };

  factory ProfileStore.fromJson(Map<String, dynamic> j) => ProfileStore(
        profiles: ((j['profiles'] as List?) ?? const [])
            .map((e) => InstanceProfile.fromJson(e as Map<String, dynamic>))
            .toList(),
        activeInstanceId: j['activeInstanceId'] as String?,
      );
}
