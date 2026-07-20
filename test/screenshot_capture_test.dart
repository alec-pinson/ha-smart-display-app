import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ha_smart_display/core/screenshot/screenshot_capture.dart';

void main() {
  testWidgets('captures the full root view as a PNG', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: ColoredBox(
          color: Color(0xFF123456),
          child: Center(child: Text('hello', textDirection: TextDirection.ltr)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    late final Uint8List? bytes;
    await tester.runAsync(() async {
      bytes = await captureRootAsPng();
    });

    expect(bytes, isNotNull);

    // PNG magic number: 89 50 4E 47 0D 0A 1A 0A
    expect(
      bytes!.sublist(0, 8),
      equals([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    );

    // Decode and confirm we captured the whole surface, not a cropped corner.
    late final ui.Image decoded;
    await tester.runAsync(() async {
      decoded = await decodeImageFromList(bytes!);
    });
    expect(decoded.width, 1280);
    expect(decoded.height, 800);
    decoded.dispose();
  });

  testWidgets('captures full physical pixels when devicePixelRatio > 1', (
    tester,
  ) async {
    // The test above cannot detect a device-pixel-ratio mistake: at DPR 1.0 the
    // logical and physical sizes are identical, so a bounds expression using
    // logical size passes anyway. The real device does not run at DPR 1.0, and
    // the failure mode is a silently cropped image rather than an error — so
    // pin the behaviour where the two sizes actually differ.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: ColoredBox(
          color: Color(0xFF123456),
          child: Center(child: Text('hello', textDirection: TextDirection.ltr)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    late final Uint8List? bytes;
    await tester.runAsync(() async {
      bytes = await captureRootAsPng();
    });
    expect(bytes, isNotNull);

    late final ui.Image decoded;
    await tester.runAsync(() async {
      decoded = await decodeImageFromList(bytes!);
    });

    // Logical size here is 640x400. Capturing that instead of the physical size
    // yields a quarter-size, top-left-cropped image.
    expect(decoded.width, 1280);
    expect(decoded.height, 800);
    decoded.dispose();
  });
}
