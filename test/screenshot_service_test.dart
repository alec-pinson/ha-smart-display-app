import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ha_smart_display/core/screenshot/screenshot_service.dart';

void main() {
  group('ScreenshotService', () {
    late List<Map<String, dynamic>> sent;

    setUp(() {
      sent = [];
    });

    ScreenshotService build(CaptureFn capture) =>
        ScreenshotService(send: sent.add, capture: capture);

    test('sends the captured PNG as base64', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      await build(() async => bytes).handleRequest();

      expect(sent, hasLength(1));
      expect(sent.single['event'], 'screenshot');
      expect(sent.single['data'], base64Encode(bytes));
      expect(sent.single.containsKey('error'), isFalse);
    });

    test('reports an error when capture returns null', () async {
      await build(() async => null).handleRequest();

      expect(sent, hasLength(1));
      expect(sent.single['event'], 'screenshot');
      expect(sent.single['error'], isNotNull);
      expect(sent.single.containsKey('data'), isFalse);
    });

    test('reports an error when capture throws', () async {
      await build(() async => throw StateError('boom')).handleRequest();

      expect(sent, hasLength(1));
      expect(sent.single['error'], contains('boom'));
      expect(sent.single.containsKey('data'), isFalse);
    });

    test('refuses to send a capture over the size ceiling', () async {
      final huge = Uint8List(kMaxScreenshotBytes + 1);
      await build(() async => huge).handleRequest();

      expect(sent, hasLength(1));
      expect(sent.single['error'], contains('too large'));
      expect(sent.single.containsKey('data'), isFalse);
    });

    test('sends a capture exactly on the size ceiling', () async {
      final atLimit = Uint8List(kMaxScreenshotBytes);
      await build(() async => atLimit).handleRequest();

      expect(sent, hasLength(1));
      expect(sent.single.containsKey('data'), isTrue);
    });

    test('ignores a second request while one is in flight', () async {
      final gate = Completer<void>();
      final service = build(() async {
        await gate.future;
        return Uint8List.fromList([1]);
      });

      final first = service.handleRequest();
      expect(service.inFlight, isTrue);

      await service.handleRequest(); // should be dropped, not queued
      expect(sent, isEmpty);

      gate.complete();
      await first;

      expect(sent, hasLength(1));
    });

    test('accepts a new request once the previous one finished', () async {
      final service = build(() async => Uint8List.fromList([1]));

      await service.handleRequest();
      await service.handleRequest();

      expect(sent, hasLength(2));
      expect(service.inFlight, isFalse);
    });

    test('clears the in-flight flag even when capture throws', () async {
      final service = build(() async => throw StateError('boom'));

      await service.handleRequest();

      expect(service.inFlight, isFalse);
    });
  });
}
