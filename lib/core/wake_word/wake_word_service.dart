import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../display_state/display_state_notifier.dart';

final _log = Logger();

// Per-model base configs from ESPHome micro-wake-word-models JSON files.
const _modelConfigs = {
  'hey_jarvis':  (windowSize: 5, stepMs: 10),
  'alexa':       (windowSize: 5, stepMs: 10),
  'okay_nabu':   (windowSize: 5, stepMs: 10),
  'hey_mycroft': (windowSize: 5, stepMs: 10),
};

// Sensitivity → probability cutoff (sliding window average).
// Higher sensitivity = lower cutoff = easier to trigger.
// Calibrated against Echo Show 8 far-field mics (VOICE_RECOGNITION source, no gain):
//   "alexa" clear speech  → best 5-frame avg ~0.70–0.85, background → 0.000
const _cutoffBySensitivity = {
  'low':    0.65,
  'medium': 0.35,
  'high':   0.18,
};

const _methodChannel = MethodChannel('ha_smart_display/wake_word');
const _eventsChannel  = EventChannel('ha_smart_display/wake_word_events');

class WakeWordService {
  final Ref _ref;

  StreamSubscription? _eventsSub;
  String? _currentWord;
  String? _currentSensitivity;

  WakeWordService(this._ref);

  Future<void> start(String wakeWord, String sensitivity) async {
    if (wakeWord == _currentWord && sensitivity == _currentSensitivity) return;
    await stop();

    final cfg = _modelConfigs[wakeWord];
    if (cfg == null) {
      _log.w('WakeWordService: no model config for $wakeWord');
      return;
    }

    final cutoff = _cutoffBySensitivity[sensitivity] ?? _cutoffBySensitivity['medium']!;
    _log.d('WakeWordService: starting native pipeline for $wakeWord (sensitivity=$sensitivity cutoff=$cutoff)');

    try {
      await _methodChannel.invokeMethod('start', {
        'wake_word':           wakeWord,
        'feature_step_size':   cfg.stepMs,
        'probability_cutoff':  cutoff,
        'sliding_window_size': cfg.windowSize,
      });
    } catch (e) {
      _log.w('WakeWordService: failed to start native pipeline — $e');
      return;
    }

    _currentWord = wakeWord;
    _currentSensitivity = sensitivity;

    // Listen for "detected" events from the native pipeline
    _eventsSub = _eventsChannel.receiveBroadcastStream().listen(
      (event) {
        if (event == 'detected') _onDetected();
      },
      onError: (e) => _log.w('WakeWordService: event stream error: $e'),
    );

    _log.d('WakeWordService: started ($wakeWord, cutoff=$cutoff, window=${cfg.windowSize})');
  }

  Future<void> stop() async {
    _eventsSub?.cancel();
    _eventsSub = null;
    _currentWord = null;
    _currentSensitivity = null;
    try {
      await _methodChannel.invokeMethod('stop');
    } catch (_) {}
  }

  Future<void> pause() async {
    try { await _methodChannel.invokeMethod('pause'); } catch (_) {}
  }

  Future<void> resume() async {
    try { await _methodChannel.invokeMethod('resume'); } catch (_) {}
  }

  void dispose() {
    _detectionController.close();
    unawaited(stop()); // fire-and-forget; native side cleans up when engine detaches
  }

  // Detection stream — AmbientScreen listens and triggers VoiceAssistantService
  final _detectionController = StreamController<void>.broadcast();
  Stream<void> get detectionStream => _detectionController.stream;

  void _onDetected() {
    _ref.read(displayStateProvider.notifier).recordWakeWordDetection();
    pause(); // stop listening until voice recording is done
    _detectionController.add(null);
  }
}

final wakeWordServiceProvider = Provider<WakeWordService>((ref) {
  final svc = WakeWordService(ref);
  // Watch wake word + sensitivity; restart when either changes
  ref.listen(
    displayStateProvider.select((s) => (s.wakeWord, s.wakeWordSensitivity)),
    (prev, next) {
      final (word, sensitivity) = next;
      svc.start(word, sensitivity);
    },
    fireImmediately: true,
  );
  ref.onDispose(svc.dispose);
  return svc;
});
