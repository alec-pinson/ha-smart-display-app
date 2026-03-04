import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import 'display_state.dart';
import '../server/display_server.dart';

final _log = Logger();
const _platform = MethodChannel('ha_smart_display/system');

class DisplayStateNotifier extends StateNotifier<DisplayState> {
  final Ref _ref;
  Timer? _heartbeatTimer;
  final DateTime _startTime = DateTime.now();

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

    state = newState;
    _pushState();
  }

  /// Called when user dismisses a timer on the device
  void dismissTimer(String timerId) {
    final newTimers = state.timers.where((t) => t.id != timerId).toList();
    state = state.copyWith(timers: newTimers);
    // Report back to HA
    _ref.read(displayServerProvider).broadcastState(state, dismissedTimer: timerId);
  }

  /// Called when user dismisses an alarm on the device
  void dismissAlarm(String alarmId) {
    final newAlarms = state.alarms.where((a) => a.id != alarmId).toList();
    state = state.copyWith(alarms: newAlarms);
    _ref.read(displayServerProvider).broadcastState(state, dismissedAlarm: alarmId);
  }

  void recordWakeWordDetection() {
    state = state.copyWith(wakeWordCount: state.wakeWordCount + 1);
    _pushState();
  }

  void pushInitialState() => _pushState();

  void _pushState() {
    _ref.read(displayServerProvider).broadcastState(state);
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
    super.dispose();
  }
}

final displayStateProvider =
    StateNotifierProvider<DisplayStateNotifier, DisplayState>((ref) {
  return DisplayStateNotifier(ref);
});
