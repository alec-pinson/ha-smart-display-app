import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import 'display_state.dart';
import '../server/display_server.dart';
import '../timer/timer_service.dart';

class NotificationData {
  final String title;
  final String message;
  final String? imageUrl;
  final int duration;
  final List<String> buttons;
  final String style; // 'dialog' | 'toast' | 'banner'
  final String? tapAction;
  final String position; // 'center' | 'top_left' | 'top_center' | 'top_right' | 'bottom_left' | 'bottom_center' | 'bottom_right'

  const NotificationData({
    required this.title,
    required this.message,
    this.imageUrl,
    this.duration = 10,
    this.buttons = const [],
    this.style = 'dialog',
    this.tapAction,
    this.position = 'center',
  });
}

final _log = Logger();
const _platform = MethodChannel('ha_smart_display/system');

class DisplayStateNotifier extends StateNotifier<DisplayState> {
  final Ref _ref;
  Timer? _heartbeatTimer;
  final DateTime _startTime = DateTime.now();

  String? _focusedCamera;

  final _notificationController = StreamController<NotificationData>.broadcast();
  Stream<NotificationData> get notificationStream => _notificationController.stream;

  final _focusedCameraController = StreamController<CameraData>.broadcast();
  Stream<CameraData> get focusedCameraStream => _focusedCameraController.stream;

  final _openCameraController = StreamController<CameraData>.broadcast();
  Stream<CameraData> get openCameraStream => _openCameraController.stream;

  void setFocusedCamera(String? id) {
    _focusedCamera = id;
    _pushState();
  }

  DisplayStateNotifier(this._ref)
      : super(const DisplayState(
          wakeWord: 'hey_jarvis',
          ambientMode: 'clock',
          ambientActive: false,
          brightness: 128,
          doNotDisturb: false,
          screenOn: true,
          uptimeSeconds: 0,
          wakeWordCount: 0,
        )) {
    _startHeartbeat();
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      state = state.copyWith(
        uptimeSeconds: DateTime.now().difference(_startTime).inSeconds,
      );
      _pushState();
      _ref.read(displayServerProvider).sendPing();
    });
  }

  void applyCommand(Map<String, dynamic> payload) {
    _log.d('DisplayState: applying command: ${payload.keys}');

    if (payload['action'] == 'restart') {
      Future.delayed(const Duration(milliseconds: 500), () => SystemNavigator.pop());
      return;
    }

    var newState = state;

    if (payload.containsKey('wake_word')) {
      newState = newState.copyWith(wakeWord: payload['wake_word'] as String);
    }
    if (payload.containsKey('ambient_mode')) {
      newState = newState.copyWith(ambientMode: payload['ambient_mode'] as String);
    }
    if (payload.containsKey('ambient_active')) {
      newState = newState.copyWith(ambientActive: payload['ambient_active'] as bool);
    }
    if (payload.containsKey('brightness')) {
      final b = payload['brightness'] as int;
      newState = newState.copyWith(brightness: b);
      _applyBrightness(b);
    }
    if (payload.containsKey('do_not_disturb')) {
      newState = newState.copyWith(doNotDisturb: payload['do_not_disturb'] as bool);
    }
    if (payload.containsKey('screen_on')) {
      newState = newState.copyWith(screenOn: payload['screen_on'] as bool);
    }
    if (payload.containsKey('weather')) {
      newState = newState.copyWith(
        weather: WeatherData.fromJson(payload['weather'] as Map<String, dynamic>),
      );
    }
    if (payload.containsKey('photos')) {
      final photos = (payload['photos'] as List).cast<String>();
      newState = newState.copyWith(photos: photos);
    }
    if (payload.containsKey('cameras')) {
      final cameras = (payload['cameras'] as List).map((c) {
        final bytes = base64Decode(c['data'] as String);
        return CameraData(
          id: c['id'] as String,
          name: c['name'] as String,
          imageBytes: Uint8List.fromList(bytes),
        );
      }).toList();
      newState = newState.copyWith(cameras: cameras);
    }
    if (payload.containsKey('open_camera')) {
      final c = payload['open_camera'] as Map<String, dynamic>;
      final id = c['id'] as String;
      final name = c['name'] as String;
      setFocusedCamera(id);
      _openCameraController.add(CameraData(
        id: id,
        name: name,
        imageBytes: Uint8List(0),
      ));
    }
    if (payload.containsKey('focused_camera_data')) {
      final c = payload['focused_camera_data'] as Map<String, dynamic>;
      final bytes = base64Decode(c['data'] as String);
      _focusedCameraController.add(CameraData(
        id: c['id'] as String,
        name: c['name'] as String,
        imageBytes: Uint8List.fromList(bytes),
      ));
    }
    if (payload.containsKey('notification')) {
      final n = payload['notification'] as Map<String, dynamic>;
      _notificationController.add(NotificationData(
        title: n['title'] as String? ?? '',
        message: n['message'] as String? ?? '',
        imageUrl: n['image_url'] as String?,
        duration: (n['duration'] as num?)?.toInt() ?? 10,
        buttons: (n['buttons'] as List?)?.cast<String>() ?? const [],
        style: n['style'] as String? ?? 'dialog',
        tapAction: n['tap_action'] as String?,
        position: n['position'] as String? ?? 'center',
      ));
    }
    if (payload.containsKey('timers')) {
      final timers = (payload['timers'] as List)
          .map((t) => TimerData.fromJson(t as Map<String, dynamic>))
          .toList();
      newState = newState.copyWith(timers: timers);
    }
    if (payload.containsKey('alarms')) {
      final alarms = (payload['alarms'] as List)
          .map((a) => AlarmData.fromJson(a as Map<String, dynamic>))
          .toList();
      newState = newState.copyWith(alarms: alarms);
    }
    if (payload.containsKey('alarm_sounding')) {
      final sounding = payload['alarm_sounding'] as bool;
      final timerService = _ref.read(timerServiceProvider);
      if (sounding) {
        timerService.startHaAlarm();
      } else {
        timerService.stopHaAlarm();
      }
    }

    state = newState;
    _pushState();
  }

  /// Called when user dismisses a timer on the device
  void dismissTimer(String timerId) {
    final newTimers = state.timers.where((t) => t.id != timerId).toList();
    state = state.copyWith(timers: newTimers);
    // Report back to HA
    _ref.read(displayServerProvider).broadcastState(state, dismissedTimer: timerId, focusedCamera: _focusedCamera);
  }

  /// Called when user dismisses an alarm on the device
  void dismissAlarm(String alarmId) {
    final newAlarms = state.alarms.where((a) => a.id != alarmId).toList();
    state = state.copyWith(alarms: newAlarms);
    _ref.read(displayServerProvider).broadcastState(state, dismissedAlarm: alarmId, focusedCamera: _focusedCamera);
  }

  void sendNotificationAction(String button, int index) {
    _ref.read(displayServerProvider).sendEvent({
      'event': 'notification_action',
      'button': button,
      'index': index,
    });
  }

  void recordWakeWordDetection() {
    state = state.copyWith(wakeWordCount: state.wakeWordCount + 1);
    _pushState();
  }

  void pushInitialState() => _pushState();

  void _pushState() {
    _ref.read(displayServerProvider).broadcastState(state, focusedCamera: _focusedCamera);
  }

  Future<void> _applyBrightness(int value) async {
    try {
      await _platform.invokeMethod(
        'setBrightness',
        {'brightness': value.clamp(0, 255) / 255.0},
      );
    } catch (e) {
      _log.w('Brightness: could not set: $e');
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _notificationController.close();
    _focusedCameraController.close();
    _openCameraController.close();
    super.dispose();
  }
}

final displayStateProvider =
    StateNotifierProvider<DisplayStateNotifier, DisplayState>((ref) {
  return DisplayStateNotifier(ref);
});
