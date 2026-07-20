import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// Captures the root render tree as PNG bytes.
///
/// The root [RenderView] is already a repaint boundary, so its layer is
/// converted directly rather than wrapping the widget tree in a
/// [RepaintBoundary] — that would add a compositing layer permanently, and
/// this device has very little memory headroom.
///
/// Returns null if the root layer is not yet available (no frame painted).
Future<Uint8List?> captureRootAsPng() async {
  final view = RendererBinding.instance.renderViews.first;
  // `layer` is protected and `RenderView` exposes no public capture API, so
  // reaching for it is unavoidable here. The public `debugLayer` is not an
  // option: it reads the layer inside an `assert`, so it returns null in
  // release builds — screenshots would work in tests and debug, then silently
  // return null on the device.
  // ignore: invalid_use_of_protected_member
  final layer = view.layer;
  if (layer is! OffsetLayer) return null;

  ui.Image? image;
  try {
    // Bounds are in the layer's coordinate space, which is physical pixels —
    // the RenderView's layer already applies the device pixel ratio transform.
    // Using logical size here would crop the capture to the top-left corner.
    final size = view.configuration.toPhysicalSize(view.size);
    image = await layer.toImage(Offset.zero & size);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    // Dispose promptly: a 1280x800 capture is ~4.1MB of raw RGBA, against
    // roughly 50MB of headroom before the memory watchdog force-restarts.
    image?.dispose();
  }
}
