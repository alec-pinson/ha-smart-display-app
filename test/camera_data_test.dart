import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ha_smart_display/core/display_state/display_state.dart';

void main() {
  group('CameraData', () {
    final bytes = Uint8List.fromList([1, 2, 3]);

    test('imageBytes can be null', () {
      const cam = CameraData(id: 'camera.test', name: 'Test');
      expect(cam.imageBytes, isNull);
    });

    test('imageBytes can be set', () {
      final cam = CameraData(id: 'camera.test', name: 'Test', imageBytes: bytes);
      expect(cam.imageBytes, same(bytes));
    });

    test('copyWith clears imageBytes to null', () {
      final cam = CameraData(id: 'camera.test', name: 'Test', imageBytes: bytes);
      final cleared = cam.copyWith(imageBytes: null, clearImageBytes: true);
      expect(cleared.imageBytes, isNull);
      expect(cleared.id, 'camera.test');
      expect(cleared.name, 'Test');
    });

    test('copyWith preserves imageBytes when not clearing', () {
      final cam = CameraData(id: 'camera.test', name: 'Test', imageBytes: bytes);
      final copied = cam.copyWith(name: 'Other');
      expect(copied.imageBytes, same(bytes));
      expect(copied.name, 'Other');
    });

    test('copyWith replaces imageBytes with new value', () {
      final cam = CameraData(id: 'camera.test', name: 'Test', imageBytes: bytes);
      final newBytes = Uint8List.fromList([4, 5, 6]);
      final updated = cam.copyWith(imageBytes: newBytes);
      expect(updated.imageBytes, same(newBytes));
    });
  });
}
