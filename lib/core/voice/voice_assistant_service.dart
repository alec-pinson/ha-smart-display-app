import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logger/logger.dart';

import '../display_state/display_state_notifier.dart';
import '../media/media_player_service.dart';
import '../server/display_server.dart';
import '../wake_word/wake_word_service.dart';

final _log = Logger();

enum VoiceAssistantState { idle, detected, listening, processing, responding }

class VoiceAssistantService {
  final Ref _ref;

  final _stateController = StreamController<VoiceAssistantState>.broadcast();
  Stream<VoiceAssistantState> get stateStream => _stateController.stream;

  VoiceAssistantState _state = VoiceAssistantState.idle;
  VoiceAssistantState get state => _state;

  AudioPlayer? _ttsPlayer;
  AudioPlayer? _triggerPlayer;
  Timer? _processingTimeout;
  Timer? _musicResumeTimer;
  StreamSubscription? _commandAudioSub;
  StreamSubscription? _commandEmptySub;

  VoiceAssistantService(this._ref);

  Future<void> onWakeWordDetected() async {
    if (_state != VoiceAssistantState.idle) return;
    _setState(VoiceAssistantState.detected);

    final mediaSvc = _ref.read(mediaPlayerServiceProvider);
    await mediaSvc.pauseForDucking();
    final displayState = _ref.read(displayStateProvider);

    if (displayState.wakeWordSound) {
      try {
        _triggerPlayer?.dispose();
        _triggerPlayer = AudioPlayer();
        await _triggerPlayer!.setLoopMode(LoopMode.off);
        await _triggerPlayer!.setAsset('assets/audio/wake_word_triggered.mp3');
        final completedFuture = _triggerPlayer!.processingStateStream
            .firstWhere((s) => s == ProcessingState.completed)
            .timeout(const Duration(seconds: 3), onTimeout: () => ProcessingState.idle);
        await _triggerPlayer!.play();
        await completedFuture;
        _triggerPlayer?.dispose();
        _triggerPlayer = null;
      } catch (e) {
        _log.w('VoiceAssistant: could not play trigger sound: $e');
      }
    }

    _setState(VoiceAssistantState.listening);

    // Subscribe to command audio events before starting recording
    final wakeWordSvc = _ref.read(wakeWordServiceProvider);
    _commandAudioSub?.cancel();
    _commandEmptySub?.cancel();

    _commandAudioSub = wakeWordSvc.commandAudioStream.listen((audioB64) {
      _commandAudioSub?.cancel();
      _commandEmptySub?.cancel();
      _onCommandAudio(audioB64);
    });

    _commandEmptySub = wakeWordSvc.commandEmptyStream.listen((_) {
      _commandAudioSub?.cancel();
      _commandEmptySub?.cancel();
      _log.d('VoiceAssistant: no audio captured, resetting');
      _resetToIdle();
    });

    await wakeWordSvc.startCommandRecording(displayState.vadSensitivity);
  }

  void _onCommandAudio(String audioB64) {
    _log.d('VoiceAssistant: received command audio from native');
    _setState(VoiceAssistantState.processing);
    try {
      _ref.read(displayServerProvider).sendEvent({
        'event': 'voice_command_audio',
        'audio': audioB64,
        'sample_rate': 16000,
        'encoding': 'wav',
      });
    } catch (e) {
      _log.w('VoiceAssistant: failed to send audio: $e');
      _resetToIdle();
      return;
    }
    _processingTimeout?.cancel();
    _processingTimeout = Timer(const Duration(seconds: 10), () {
      if (_state == VoiceAssistantState.processing) _resetToIdle();
    });
  }

  Future<void> onResponseReceived({String? ttsUrl}) async {
    _processingTimeout?.cancel();
    _processingTimeout = null;
    // Transition to responding immediately — hides the processing spinner in the UI
    // while still keeping wake word detection paused until TTS finishes.
    if (_state == VoiceAssistantState.processing) {
      _setState(VoiceAssistantState.responding);
    }
    // Play TTS before resuming wake word — avoids the TTS audio re-triggering detection
    if (ttsUrl != null && ttsUrl.isNotEmpty) {
      await _playTts(ttsUrl);
    }
    // Signal HA satellite entity that TTS playback is done → RESPONDING → IDLE
    try {
      _ref.read(displayServerProvider).sendEvent({'event': 'tts_finished'});
    } catch (e) {
      _log.w('VoiceAssistant: failed to send tts_finished: $e');
    }
    if (_state == VoiceAssistantState.responding) _resetToIdle();
  }

  Future<void> _playTts(String url) async {
    try {
      _ttsPlayer?.dispose();
      _ttsPlayer = AudioPlayer();
      await _ttsPlayer!.setUrl(url);
      // Subscribe before play() to avoid missing the completed event.
      // play() alone isn't always sufficient — it can return before audio finishes.
      final completedFuture = _ttsPlayer!.processingStateStream
          .firstWhere((s) => s == ProcessingState.completed)
          .timeout(const Duration(seconds: 30), onTimeout: () => ProcessingState.idle);
      await _ttsPlayer!.play();
      await completedFuture;
      // Small delay after ProcessingState.completed to ensure ExoPlayer has fully
      // handed off audio to AudioTrack. The native WakeWordPlugin.resume() then
      // polls AudioManager.isMusicActive() and waits until hardware output stops
      // before unpausing detection — so we don't need a large fixed delay here.
      await Future.delayed(const Duration(milliseconds: 500));
      _ttsPlayer?.dispose();
      _ttsPlayer = null;
    } catch (e) {
      _log.w('VoiceAssistant: TTS playback error: $e');
    }
  }

  void _resetToIdle() {
    // Set idle first — AmbientScreen observes this and calls wakeWordSvc.resume(),
    // which sets up cooldown frames before detection restarts.
    _setState(VoiceAssistantState.idle);
    // Resume music after a delay so the native wake word cooldown is established
    // before music audio hits the mic (prevents false re-triggering).
    // MediaPlayerService.resumeAfterDucking() is a no-op if nothing was ducked (e.g. "stop music" command).
    _musicResumeTimer?.cancel();
    _musicResumeTimer = Timer(const Duration(milliseconds: 1500), () {
      _musicResumeTimer = null;
      _ref.read(mediaPlayerServiceProvider).resumeAfterDucking();
    });
  }

  void _setState(VoiceAssistantState s) {
    _state = s;
    _stateController.add(s);
  }

  void dispose() {
    _processingTimeout?.cancel();
    _musicResumeTimer?.cancel();
    _commandAudioSub?.cancel();
    _commandEmptySub?.cancel();
    _ttsPlayer?.dispose();
    _triggerPlayer?.dispose();
    _stateController.close();
  }
}

final voiceAssistantServiceProvider = Provider<VoiceAssistantService>((ref) {
  final svc = VoiceAssistantService(ref);
  ref.onDispose(svc.dispose);
  return svc;
});
