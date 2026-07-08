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
