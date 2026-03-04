import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logger/logger.dart';

import '../display_state/display_state.dart';
import '../display_state/display_state_notifier.dart';

final _log = Logger();

class TimerService {
  final Ref _ref;
  final _firedTimers = <String>{};
  final _firedAlarms = <String>{};

  // Player for timer/alarm chime — loops until dismissed
  final _chimePlayer = AudioPlayer();

  // Player for HA-triggered alarm — independent loop
  final _haAlarmPlayer = AudioPlayer();

  Timer? _checkTimer;

  final _firingController = StreamController<FiringAlert?>.broadcast();
  Stream<FiringAlert?> get firingStream => _firingController.stream;

  TimerService(this._ref) {
    _checkTimer = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  void _check() {
    if (_firingController.isClosed) return;
    final state = _ref.read(displayStateProvider);

    for (final timer in state.timers) {
      if (timer.isExpired && !_firedTimers.contains(timer.id)) {
        _firedTimers.add(timer.id);
        _fire(FiringAlert(id: timer.id, label: timer.label, type: AlertType.timer));
      }
    }

    final now = DateTime.now();
    final nowStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    for (final alarm in state.alarms) {
      final key = '${alarm.id}_${now.day}';
      if (alarm.time == nowStr && now.second < 5 && !_firedAlarms.contains(key)) {
        _firedAlarms.add(key);
        _fire(FiringAlert(id: alarm.id, label: alarm.label, type: AlertType.alarm));
      }
    }
  }

  Future<void> _fire(FiringAlert alert) async {
    _log.i('TimerService: firing ${alert.type.name} "${alert.label}"');
    if (!_firingController.isClosed) _firingController.add(alert);
    await _startChimeLoop();
  }

  Future<void> _startChimeLoop() async {
    try {
      await _chimePlayer.setLoopMode(LoopMode.one);
      await _chimePlayer.setAsset('assets/audio/timer_chime.mp3');
      await _chimePlayer.play();
    } catch (e) {
      _log.w('TimerService: could not play chime: $e');
    }
  }

  void dismiss(FiringAlert alert) {
    if (!_firingController.isClosed) _firingController.add(null);
    final notifier = _ref.read(displayStateProvider.notifier);
    if (alert.type == AlertType.timer) {
      notifier.dismissTimer(alert.id);
    } else {
      notifier.dismissAlarm(alert.id);
    }
    _chimePlayer.stop();
  }

  /// Called by HA alarm_sounding switch turning ON
  Future<void> startHaAlarm() async {
    try {
      await _haAlarmPlayer.setLoopMode(LoopMode.one);
      await _haAlarmPlayer.setAsset('assets/audio/timer_chime.mp3');
      await _haAlarmPlayer.play();
      _log.i('TimerService: HA alarm started');
    } catch (e) {
      _log.w('TimerService: could not start HA alarm: $e');
    }
  }

  /// Called by HA alarm_sounding switch turning OFF
  void stopHaAlarm() {
    _haAlarmPlayer.stop();
    _log.i('TimerService: HA alarm stopped');
  }

  void dispose() {
    _checkTimer?.cancel();
    _firingController.close();
    _chimePlayer.dispose();
    _haAlarmPlayer.dispose();
  }
}

enum AlertType { timer, alarm }

class FiringAlert {
  final String id;
  final String label;
  final AlertType type;
  const FiringAlert({required this.id, required this.label, required this.type});
}

final timerServiceProvider = Provider<TimerService>((ref) {
  final service = TimerService(ref);
  ref.onDispose(service.dispose);
  return service;
});
