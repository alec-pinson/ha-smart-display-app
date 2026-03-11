import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logger/logger.dart';
import 'package:record/record.dart';

import '../display_state/display_state.dart';
import '../display_state/display_state_notifier.dart';
import '../media/media_player_service.dart';
import '../server/display_server.dart';

final _log = Logger();

enum VoiceAssistantState { idle, detected, listening, processing, responding }

class VoiceAssistantService {
  final Ref _ref;

  final _stateController = StreamController<VoiceAssistantState>.broadcast();
  Stream<VoiceAssistantState> get stateStream => _stateController.stream;

  VoiceAssistantState _state = VoiceAssistantState.idle;
  VoiceAssistantState get state => _state;

  final _recorder = AudioRecorder();
  final _ttsPlayer = AudioPlayer();
  bool _isRecordingCommand = false;
  Timer? _processingTimeout;
  Timer? _musicResumeTimer;
  bool _musicWasPlaying = false;

  // VAD config
  static const _maxDurationMs = 10000;
  static const _calibrationChunks = 20; // 200ms of noise floor sampling
  static const _minEnergyThreshold = 100.0; // floor so very quiet rooms still work

  // Returns (silenceThresholdMs, noiseMultiplier) for the current vad_sensitivity.
  // The energy threshold is set dynamically as: max(noiseFloor * multiplier, _minEnergyThreshold).
  // Higher multiplier = needs louder signal above ambient noise to register as speech,
  // so noise fluctuations don't reset the silence counter.
  (int, double) get _vadParams {
    final sensitivity = _ref.read(displayStateProvider).vadSensitivity;
    switch (sensitivity) {
      case 'relaxed':
        return (2500, 1.5);
      case 'aggressive':
        return (400, 1.5);
      default: // 'default'
        return (1500, 1.5);
    }
  }

  VoiceAssistantService(this._ref);

  Future<void> onWakeWordDetected() async {
    if (_state != VoiceAssistantState.idle) return;
    _setState(VoiceAssistantState.detected);

    // Pause music if playing — will resume after voice response unless a stop command came through
    final mediaSvc = _ref.read(mediaPlayerServiceProvider);
    final mediaState = _ref.read(displayStateProvider).mediaState;
    _musicWasPlaying = mediaState == MediaPlayerState.playing || mediaState == MediaPlayerState.buffering;
    if (_musicWasPlaying) {
      await mediaSvc.pause();
    }

    // Brief pause so the wake-word utterance finishes before we start recording
    await Future.delayed(const Duration(milliseconds: 400));

    _setState(VoiceAssistantState.listening);
    final pcmData = await _recordCommand();

    if (pcmData == null || pcmData.isEmpty) {
      _log.d('VoiceAssistant: no audio captured, resetting');
      _resetToIdle();
      return;
    }

    _setState(VoiceAssistantState.processing);
    await _sendToHA(pcmData);
    // HA will reply with voice_response — onResponseReceived() called then.
    // Safety timeout in case HA never replies — cancelled on response or dispose.
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
    if (_state == VoiceAssistantState.responding) _resetToIdle();
  }

  Future<void> _playTts(String url) async {
    try {
      await _ttsPlayer.setUrl(url);
      // Subscribe before play() to avoid missing the completed event.
      // play() alone isn't always sufficient — it can return before audio finishes.
      final completedFuture = _ttsPlayer.processingStateStream
          .firstWhere((s) => s == ProcessingState.completed)
          .timeout(const Duration(seconds: 30), onTimeout: () => ProcessingState.idle);
      await _ttsPlayer.play();
      await completedFuture;
      // Small delay after ProcessingState.completed to ensure ExoPlayer has fully
      // handed off audio to AudioTrack. The native WakeWordPlugin.resume() then
      // polls AudioManager.isMusicActive() and waits until hardware output stops
      // before unpausing detection — so we don't need a large fixed delay here.
      await Future.delayed(const Duration(milliseconds: 500));
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
    // MediaPlayerService.resume() is a no-op if state is idle (e.g. "stop music" command).
    if (_musicWasPlaying) {
      _musicWasPlaying = false;
      _musicResumeTimer?.cancel();
      _musicResumeTimer = Timer(const Duration(milliseconds: 1500), () {
        _musicResumeTimer = null;
        _ref.read(mediaPlayerServiceProvider).resume();
      });
    }
  }

  Future<Uint8List?> _recordCommand() async {
    if (!await _recorder.hasPermission()) return null;
    if (_isRecordingCommand) return null;
    _isRecordingCommand = true;

    final (silenceThresholdMs, noiseMultiplier) = _vadParams;
    final collectedChunks = <Uint8List>[];
    int silenceMs = 0;
    int totalMs = 0;
    bool started = false;

    // Calibration: measure noise floor over the first _calibrationChunks chunks,
    // then set threshold dynamically so it adapts to the current room conditions.
    int calibrationCount = 0;
    double calibrationRmsSum = 0;
    bool calibrated = false;
    double energyThreshold = _minEnergyThreshold;

    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));

      // 160 samples × 10ms chunks at 16kHz
      const chunkSamples = 160;
      const chunkMs = 10;
      const bytesPerChunk = chunkSamples * 2; // 16-bit = 2 bytes/sample

      final chunkBuffer = <int>[];

      final completer = Completer<void>();
      late StreamSubscription sub;
      sub = stream.listen((bytes) {
        chunkBuffer.addAll(bytes);

        while (chunkBuffer.length >= bytesPerChunk) {
          final chunk = Uint8List.fromList(chunkBuffer.take(bytesPerChunk).toList());
          chunkBuffer.removeRange(0, bytesPerChunk);

          collectedChunks.add(chunk);
          totalMs += chunkMs;

          final rms = _computeRms(chunk);

          // Calibration phase: sample noise floor before VAD starts
          if (!calibrated) {
            calibrationRmsSum += rms;
            calibrationCount++;
            if (calibrationCount >= _calibrationChunks) {
              final noiseFloor = calibrationRmsSum / calibrationCount;
              energyThreshold = math.max(noiseFloor * noiseMultiplier, _minEnergyThreshold);
              calibrated = true;
              _log.d('VoiceAssistant: noise floor=${noiseFloor.toStringAsFixed(1)}, threshold=${energyThreshold.toStringAsFixed(1)}');
            }
            continue;
          }

          // Energy-based VAD
          if (rms > energyThreshold) {
            started = true;
            silenceMs = 0;
          } else if (started) {
            silenceMs += chunkMs;
          }

          if ((started && silenceMs >= silenceThresholdMs) ||
              totalMs >= _maxDurationMs) {
            sub.cancel();
            if (!completer.isCompleted) completer.complete();
          }
        }
      }, onDone: () {
        if (!completer.isCompleted) completer.complete();
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete();
      });

      await completer.future;
    } catch (e) {
      _log.w('VoiceAssistant: recording error: $e');
    } finally {
      try { await _recorder.stop(); } catch (_) {}
      _isRecordingCommand = false;
    }

    if (collectedChunks.isEmpty) return null;

    final rawPcm = Uint8List.fromList(collectedChunks.expand((c) => c).toList());
    return _addWavHeader(rawPcm, 16000, 1, 16);
  }

  Future<void> _sendToHA(Uint8List wavData) async {
    final b64 = base64Encode(wavData);
    try {
      _ref.read(displayServerProvider).sendEvent({
        'event': 'voice_command_audio',
        'audio': b64,
        'sample_rate': 16000,
        'encoding': 'wav',
      });
      _log.d('VoiceAssistant: sent ${wavData.length} bytes to HA');
    } catch (e) {
      _log.w('VoiceAssistant: failed to send audio: $e');
      _resetToIdle();
    }
  }

  double _computeRms(Uint8List chunk) {
    if (chunk.length < 2) return 0;
    double sum = 0;
    final bd = ByteData.sublistView(chunk);
    final sampleCount = chunk.length ~/ 2;
    for (int i = 0; i < sampleCount; i++) {
      final s = bd.getInt16(i * 2, Endian.little).toDouble();
      sum += s * s;
    }
    return sampleCount == 0 ? 0 : math.sqrt(sum / sampleCount);
  }

  Uint8List _addWavHeader(Uint8List pcm, int sampleRate, int channels, int bitsPerSample) {
    final dataSize = pcm.length;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final header = ByteData(44);
    // RIFF
    header.setUint8(0,  0x52); header.setUint8(1,  0x49);
    header.setUint8(2,  0x46); header.setUint8(3,  0x46);
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint8(8,  0x57); header.setUint8(9,  0x41);
    header.setUint8(10, 0x56); header.setUint8(11, 0x45);
    // fmt
    header.setUint8(12, 0x66); header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74); header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // data
    header.setUint8(36, 0x64); header.setUint8(37, 0x61);
    header.setUint8(38, 0x74); header.setUint8(39, 0x61);
    header.setUint32(40, dataSize, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...pcm]);
  }

  void _setState(VoiceAssistantState s) {
    _state = s;
    _stateController.add(s);
  }

  void dispose() {
    _processingTimeout?.cancel();
    _musicResumeTimer?.cancel();
    _recorder.dispose();
    _ttsPlayer.dispose();
    _stateController.close();
  }
}

final voiceAssistantServiceProvider = Provider<VoiceAssistantService>((ref) {
  final svc = VoiceAssistantService(ref);
  ref.onDispose(svc.dispose);
  return svc;
});
