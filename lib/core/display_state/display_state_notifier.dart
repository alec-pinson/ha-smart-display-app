import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

import 'display_state.dart';
import '../server/display_server.dart';
import '../timer/timer_service.dart';
import '../voice/voice_assistant_service.dart';

const _androidOptions = AndroidOptions(encryptedSharedPreferences: true);
const _storage = FlutterSecureStorage(aOptions: _androidOptions);
const _wakeWordKey = 'wake_word';
const _wakeWordSensitivityKey = 'wake_word_sensitivity';

Future<String> loadPersistedWakeWord() async {
  return await _storage.read(key: _wakeWordKey) ?? 'alexa';
}

Future<String> loadPersistedWakeWordSensitivity() async {
  return await _storage.read(key: _wakeWordSensitivityKey) ?? 'medium';
}

Future<int> loadInitialVolume() async {
  try {
    final vol = await const MethodChannel('ha_smart_display/system')
        .invokeMethod<int>('getVolume');
    return vol ?? 50;
  } catch (_) {
    return 50;
  }
}

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

  DisplayStateNotifier(this._ref, {String initialWakeWord = 'alexa', String initialWakeWordSensitivity = 'medium', int initialVolume = 50})
      : super(DisplayState(
          wakeWord: initialWakeWord,
          wakeWordSensitivity: initialWakeWordSensitivity,
          ambientMode: 'clock',
          ambientActive: false,
          brightness: 128,
          volume: initialVolume,
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
      final word = payload['wake_word'] as String;
      newState = newState.copyWith(wakeWord: word);
      _storage.write(key: _wakeWordKey, value: word);
    }
    if (payload.containsKey('wake_word_sensitivity')) {
      final sensitivity = payload['wake_word_sensitivity'] as String;
      newState = newState.copyWith(wakeWordSensitivity: sensitivity);
      _storage.write(key: _wakeWordSensitivityKey, value: sensitivity);
    }
    if (payload.containsKey('ambient_mode')) {
      newState = newState.copyWith(ambientMode: payload['ambient_mode'] as String);
    }
    if (payload.containsKey('ambient_active')) {
      newState = newState.copyWith(ambientActive: payload['ambient_active'] as bool);
    }
    if (payload.containsKey('auto_brightness')) {
      final auto = payload['auto_brightness'] as bool;
      newState = newState.copyWith(autoBrightness: auto);
      if (auto) {
        _applyBrightness(-1); // -1 signals auto to native layer
      } else {
        _applyBrightness(newState.brightness);
      }
    }
    if (payload.containsKey('brightness')) {
      final b = payload['brightness'] as int;
      newState = newState.copyWith(brightness: b);
      if (!newState.autoBrightness) _applyBrightness(b);
    }
    if (payload.containsKey('volume')) {
      final v = payload['volume'] as int;
      newState = newState.copyWith(volume: v.clamp(0, 100));
      _applyVolume(v.clamp(0, 100));
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
    if (payload.containsKey('climate')) {
      newState = newState.copyWith(
        climate: ClimateData.fromJson(payload['climate'] as Map<String, dynamic>),
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
    if (payload.containsKey('voice_response')) {
      final vr = payload['voice_response'] as Map<String, dynamic>;
      final text = vr['text'] as String? ?? '';
      final ttsUrl = vr['tts_url'] as String?;
      if (text.isNotEmpty) {
        _notificationController.add(NotificationData(
          title: 'Assistant',
          message: text,
          duration: 8,
          style: 'banner',
        ));
      }
      unawaited(_ref.read(voiceAssistantServiceProvider).onResponseReceived(ttsUrl: ttsUrl));
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

  void setClimateTemperature(double temperature) {
    _ref.read(displayServerProvider).sendEvent({
      'event': 'climate_set_temperature',
      'temperature': temperature,
    });
  }

  void setClimateHvacMode(String hvacMode) {
    _ref.read(displayServerProvider).sendEvent({
      'event': 'climate_set_hvac_mode',
      'hvac_mode': hvacMode,
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
      // value < 0 is the sentinel for auto brightness (maps to -1f in native layer)
      final brightness = value < 0 ? -1.0 : value.clamp(0, 255) / 255.0;
      await _platform.invokeMethod('setBrightness', {'brightness': brightness});
    } catch (e) {
      _log.w('Brightness: could not set: $e');
    }
  }

  Future<void> _applyVolume(int value) async {
    try {
      await _platform.invokeMethod('setVolume', {'volume': value});
    } catch (e) {
      _log.w('Volume: could not set: $e');
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
