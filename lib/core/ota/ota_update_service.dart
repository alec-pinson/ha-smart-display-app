import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

import '../server/display_server.dart';

final otaUpdateServiceProvider = Provider<OtaUpdateService>(
  (ref) => OtaUpdateService(ref),
);

class OtaUpdateService {
  static const _channel = MethodChannel('ha_smart_display/ota');
  final Ref _ref;
  final _log = Logger();

  OtaUpdateService(this._ref);

  void handleUpdate(String url) {
    _doUpdate(url).catchError((Object e, StackTrace st) {
      _log.e('OtaUpdateService: update failed', error: e, stackTrace: st);
      _sendError('Update failed: $e');
    });
  }

  Future<void> _doUpdate(String url) async {
    _log.i('OtaUpdateService: downloading APK from $url');
    final apkPath = await _downloadApk(url);
    _log.i('OtaUpdateService: installing APK at $apkPath');
    await _installApk(apkPath);
    _log.i('OtaUpdateService: install triggered successfully');
  }

  Future<String> _downloadApk(String url) async {
    final tmpDir = await getTemporaryDirectory();
    final apkFile = File('${tmpDir.path}/ota_update.apk');
    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }
      sink = apkFile.openWrite();
      await response.stream.pipe(sink);
      await sink.close();
      sink = null;
    } finally {
      await sink?.close();
      client.close();
    }
    return apkFile.path;
  }

  Future<void> _installApk(String filePath) async {
    await _channel.invokeMethod<void>('installApk', {'filePath': filePath});
  }

  void _sendError(String message) {
    _ref.read(displayServerProvider).sendEvent({
      'event': 'ota_error',
      'message': message,
    });
  }
}
