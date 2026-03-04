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
  final _player = AudioPlayer();
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
    await _playSound();
  }

  Future<void> _playSound() async {
    try {
      await _player.setAsset('assets/audio/timer_chime.mp3');
      await _player.play();
    } catch (e) {
      _log.w('TimerService: could not play sound: $e');
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
    _player.stop();
  }

  void dispose() {
    _checkTimer?.cancel();
    _firingController.close();
    _player.dispose();
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
