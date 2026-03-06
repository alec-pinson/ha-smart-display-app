import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../display_state/display_state_notifier.dart';

const _methodChannel = MethodChannel('ha_smart_display/camera_analysis');
const _eventChannel = EventChannel('ha_smart_display/camera_analysis_events');

final _log = Logger();

class CameraAnalysisService {
  final Ref _ref;
  StreamSubscription? _sub;

  CameraAnalysisService(this._ref);

  Future<void> start() async {
    try {
      await _methodChannel.invokeMethod('start');
    } catch (e) {
      _log.w('CameraAnalysis: could not start: $e');
      return;
    }

    _sub = _eventChannel
        .receiveBroadcastStream()
        .listen((event) {
      try {
        final data = json.decode(event as String) as Map<String, dynamic>;
        final lux = (data['lux'] as num?)?.toDouble();
        _ref.read(displayStateProvider.notifier).updateLux(lux);
      } catch (e) {
        _log.w('CameraAnalysis: could not parse event: $e');
      }
    }, onError: (Object e) {
      _log.w('CameraAnalysis: event channel error: $e');
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _methodChannel.invokeMethod('stop');
    } catch (_) {}
  }
}

final cameraAnalysisServiceProvider = Provider<CameraAnalysisService>((ref) {
  final service = CameraAnalysisService(ref);
  ref.onDispose(service.stop);
  return service;
});
