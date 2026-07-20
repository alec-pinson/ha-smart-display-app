import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../server/display_server.dart';
import 'screenshot_capture.dart';

typedef CaptureFn = Future<Uint8List?> Function();
typedef SendFn = void Function(Map<String, dynamic> event);

/// Largest PNG we will put on the wire.
///
/// The integration raises the `websockets` receive limit to 16MB, so this sits
/// comfortably below it. Exceeding the receive limit does not merely fail the
/// screenshot — it closes the connection with a 1009, tearing down the
/// display's link to Home Assistant. Refusing to send is the safer failure.
const int kMaxScreenshotBytes = 8 * 1024 * 1024;

final screenshotServiceProvider = Provider<ScreenshotService>((ref) {
  return ScreenshotService(
    send: (event) => ref.read(displayServerProvider).sendEvent(event),
  );
});

class ScreenshotService {
  final SendFn _send;
  final CaptureFn _capture;
  final _log = Logger();
  bool _inFlight = false;

  ScreenshotService({required SendFn send, CaptureFn? capture})
      : _send = send,
        _capture = capture ?? captureRootAsPng;

  /// True while a capture is running. A request arriving now is dropped.
  bool get inFlight => _inFlight;

  /// Captures the screen and pushes it to Home Assistant.
  ///
  /// A request arriving while a capture is already running is ignored rather
  /// than queued — a 1280x800 capture is a 10-15MB transient peak, and
  /// overlapping captures could trip the memory watchdog.
  Future<void> handleRequest() async {
    if (_inFlight) {
      _log.d('ScreenshotService: capture already in flight, ignoring request');
      return;
    }
    _inFlight = true;
    try {
      final bytes = await _capture();
      if (bytes == null) {
        _sendError('Capture failed: no image produced');
        return;
      }
      if (bytes.length > kMaxScreenshotBytes) {
        _sendError(
          'Screenshot too large to send: ${bytes.length} bytes '
          '(limit $kMaxScreenshotBytes)',
        );
        return;
      }
      _send({'event': 'screenshot', 'data': base64Encode(bytes)});
    } catch (e, st) {
      _log.e('ScreenshotService: capture failed', error: e, stackTrace: st);
      _sendError('Capture failed: $e');
    } finally {
      _inFlight = false;
    }
  }

  void _sendError(String message) {
    _log.w('ScreenshotService: $message');
    _send({'event': 'screenshot', 'error': message});
  }
}
