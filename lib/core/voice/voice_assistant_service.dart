import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:record/record.dart';

import '../server/display_server.dart';

final _log = Logger();

enum VoiceAssistantState { idle, detected, listening, processing }

class VoiceAssistantService {
  final Ref _ref;

  final _stateController = StreamController<VoiceAssistantState>.broadcast();
  Stream<VoiceAssistantState> get stateStream => _stateController.stream;

  VoiceAssistantState _state = VoiceAssistantState.idle;
  VoiceAssistantState get state => _state;

  final _recorder = AudioRecorder();
  bool _isRecordingCommand = false;

  // VAD config
  static const _maxDurationMs = 10000;
  static const _silenceThresholdMs = 1500;
  static const _energyThreshold = 300.0; // RMS level below which is "silence"

  VoiceAssistantService(this._ref);

  Future<void> onWakeWordDetected() async {
    if (_state != VoiceAssistantState.idle) return;
    _setState(VoiceAssistantState.detected);

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
    // Add a safety timeout in case HA doesn't reply.
    Future.delayed(const Duration(seconds: 10), () {
      if (_state == VoiceAssistantState.processing) _resetToIdle();
    });
  }

  void onResponseReceived() {
    if (_state == VoiceAssistantState.processing) _resetToIdle();
  }

  void _resetToIdle() {
    _setState(VoiceAssistantState.idle);
    // WakeWordService.resume() is called by AmbientScreen when it observes idle state
  }

  Future<Uint8List?> _recordCommand() async {
    if (!await _recorder.hasPermission()) return null;
    if (_isRecordingCommand) return null;
    _isRecordingCommand = true;

    final collectedChunks = <Uint8List>[];
    int silenceMs = 0;
    int totalMs = 0;
    bool started = false;

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

          // Simple energy-based VAD
          final rms = _computeRms(chunk);
          if (rms > _energyThreshold) {
            started = true;
            silenceMs = 0;
          } else if (started) {
            silenceMs += chunkMs;
          }

          if ((started && silenceMs >= _silenceThresholdMs) ||
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
    _recorder.dispose();
    _stateController.close();
  }
}

final voiceAssistantServiceProvider = Provider<VoiceAssistantService>((ref) {
  final svc = VoiceAssistantService(ref);
  ref.onDispose(svc.dispose);
  return svc;
});
