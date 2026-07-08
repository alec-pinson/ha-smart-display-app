import 'package:flutter_test/flutter_test.dart';
import 'package:ha_smart_display/core/pairing/instance_profile.dart';

void main() {
  group('InstanceProfile', () {
    test('toJson/fromJson round-trips all fields', () {
      final p = InstanceProfile(
        instanceId: 'abc',
        label: 'Home',
        host: '192.168.1.10',
        lastSeen: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final restored = InstanceProfile.fromJson(p.toJson());
      expect(restored.instanceId, 'abc');
      expect(restored.label, 'Home');
      expect(restored.host, '192.168.1.10');
      expect(restored.lastSeen, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    });

    test('fromJson tolerates missing host/lastSeen and missing label', () {
      final restored = InstanceProfile.fromJson({'instanceId': 'xyz'});
      expect(restored.instanceId, 'xyz');
      expect(restored.label, 'xyz'); // falls back to id
      expect(restored.host, isNull);
      expect(restored.lastSeen, isNull);
    });

    test('copyWith replaces only supplied fields', () {
      const p = InstanceProfile(instanceId: 'abc', label: 'Home');
      final updated = p.copyWith(label: 'Home-Test');
      expect(updated.instanceId, 'abc');
      expect(updated.label, 'Home-Test');
    });
  });
}
