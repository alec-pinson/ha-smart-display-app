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

  group('ProfileStore', () {
    InstanceProfile prof(String id, [String? label]) =>
        InstanceProfile(instanceId: id, label: label ?? id);

    test('empty store is unpaired and rejects unknown connections', () {
      const store = ProfileStore.empty();
      expect(store.isPaired, isFalse);
      expect(store.roleFor('anything'), ConnectionRole.reject);
    });

    test('legacy-paired empty store adopts the first connection', () {
      const store = ProfileStore.empty(legacyPaired: true);
      expect(store.isPaired, isTrue);
      expect(store.roleFor('prod'), ConnectionRole.adopt);
    });

    test('first upserted profile becomes active and is served', () {
      final store = const ProfileStore.empty(legacyPaired: true).upsert(prof('prod', 'Home'));
      expect(store.activeInstanceId, 'prod');
      expect(store.legacyPaired, isFalse);
      expect(store.isPaired, isTrue);
      expect(store.roleFor('prod'), ConnectionRole.serve);
    });

    test('second profile is parked, active stays on the first', () {
      final store = const ProfileStore.empty()
          .upsert(prof('prod', 'Home'))
          .upsert(prof('test', 'Home-Test'));
      expect(store.activeInstanceId, 'prod');
      expect(store.roleFor('prod'), ConnectionRole.serve);
      expect(store.roleFor('test'), ConnectionRole.park);
    });

    test('withActive switches which instance is served', () {
      final store = const ProfileStore.empty()
          .upsert(prof('prod'))
          .upsert(prof('test'))
          .withActive('test');
      expect(store.roleFor('test'), ConnectionRole.serve);
      expect(store.roleFor('prod'), ConnectionRole.park);
    });

    test('withActive ignores unknown ids', () {
      final store = const ProfileStore.empty().upsert(prof('prod')).withActive('ghost');
      expect(store.activeInstanceId, 'prod');
    });

    test('upsert of existing id updates metadata without duplicating', () {
      final store = const ProfileStore.empty()
          .upsert(prof('prod', 'Home'))
          .upsert(prof('prod', 'Home Renamed'));
      expect(store.profiles.length, 1);
      expect(store.profiles.single.label, 'Home Renamed');
      expect(store.activeInstanceId, 'prod');
    });

    test('removing the active profile clears active; others become park', () {
      final store = const ProfileStore.empty()
          .upsert(prof('prod'))
          .upsert(prof('test'));
      final removed = store.remove('prod');
      expect(removed.activeInstanceId, isNull);
      expect(removed.profiles.length, 1);
      expect(removed.roleFor('test'), ConnectionRole.park);
      expect(removed.roleFor('prod'), ConnectionRole.reject);
    });

    test('removing a non-active profile leaves active untouched', () {
      final store = const ProfileStore.empty()
          .upsert(prof('prod'))
          .upsert(prof('test'))
          .remove('test');
      expect(store.activeInstanceId, 'prod');
    });

    test('toJson/fromJson round-trips profiles and active id', () {
      final store = const ProfileStore.empty()
          .upsert(prof('prod', 'Home'))
          .upsert(prof('test', 'Home-Test'))
          .withActive('test');
      final restored = ProfileStore.fromJson(store.toJson());
      expect(restored.profiles.map((p) => p.instanceId), ['prod', 'test']);
      expect(restored.activeInstanceId, 'test');
      expect(restored.legacyPaired, isFalse); // never persisted
    });
  });
}
