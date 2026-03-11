import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logger/logger.dart';

import '../display_state/display_state.dart';

final _log = Logger();

class MediaStatus {
  final MediaPlayerState state;
  final int positionMs;
  const MediaStatus({required this.state, required this.positionMs});
}

class MediaPlayerService {
  final _player = AudioPlayer();
  final _statusController = StreamController<MediaStatus>.broadcast();
  StreamSubscription? _playerStateSub;
  MediaPlayerState _currentState = MediaPlayerState.idle;

  Stream<MediaStatus> get statusStream => _statusController.stream;

  MediaPlayerService() {
    _playerStateSub = _player.playerStateStream.listen(_onPlayerState);
  }

  void _onPlayerState(PlayerState ps) {
    final prev = _currentState;
    _currentState = _mapState(ps);
    if (_currentState != prev) {
      _emit();
    }
  }

  void _emit() {
    if (_statusController.isClosed) return;
    _statusController.add(MediaStatus(
      state: _currentState,
      positionMs: _player.position.inMilliseconds,
    ));
  }

  MediaPlayerState _mapState(PlayerState ps) {
    if (ps.processingState == ProcessingState.loading ||
        ps.processingState == ProcessingState.buffering) {
      return MediaPlayerState.buffering;
    }
    if (ps.processingState == ProcessingState.completed ||
        ps.processingState == ProcessingState.idle) {
      return MediaPlayerState.idle;
    }
    return ps.playing ? MediaPlayerState.playing : MediaPlayerState.paused;
  }

  Future<void> play(String url) async {
    try {
      await _player.setUrl(url);
      await _player.play();
    } catch (e) {
      _log.w('MediaPlayerService: play failed: $e');
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> resume() async {
    if (_currentState == MediaPlayerState.paused) {
      await _player.play();
    }
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> seek(int ms) async {
    await _player.seek(Duration(milliseconds: ms));
  }

  void dispose() {
    _playerStateSub?.cancel();
    _statusController.close();
    _player.dispose();
  }
}

final mediaPlayerServiceProvider = Provider<MediaPlayerService>((ref) {
  final service = MediaPlayerService();
  ref.onDispose(service.dispose);
  return service;
});
