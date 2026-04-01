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
  final _statusController = StreamController<MediaStatus>.broadcast();
  StreamSubscription? _playerStateSub;
  MediaPlayerState _currentState = MediaPlayerState.idle;
  AudioPlayer? _player;
  bool _wasPlayingBeforeDuck = false;

  Stream<MediaStatus> get statusStream => _statusController.stream;

  bool get _isPlaying => _currentState == MediaPlayerState.playing;

  AudioPlayer _ensurePlayer() {
    if (_player != null) return _player!;
    _player = AudioPlayer();
    _playerStateSub = _player!.playerStateStream.listen(_onPlayerState);
    return _player!;
  }

  void _onPlayerState(PlayerState ps) {
    final prev = _currentState;
    _currentState = _mapState(ps);
    if (_currentState != prev) {
      _emit();
    }
    // Release when transitioning TO completed/idle FROM a non-idle state.
    // The guard on `prev` prevents releasing the player immediately after creation,
    // since a new AudioPlayer emits an initial idle event before setUrl is called.
    // _emit() must be called before _releasePlayer() so the final status
    // event reports the correct position before _player is nulled.
    if (prev != MediaPlayerState.idle &&
        (ps.processingState == ProcessingState.completed ||
         ps.processingState == ProcessingState.idle)) {
      _releasePlayer();
    }
  }

  void _releasePlayer() {
    _playerStateSub?.cancel();
    _playerStateSub = null;
    _player?.dispose();
    _player = null;
    _wasPlayingBeforeDuck = false;
  }

  void _emit() {
    if (_statusController.isClosed) return;
    _statusController.add(MediaStatus(
      state: _currentState,
      positionMs: _player?.position.inMilliseconds ?? 0,
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
      final player = _ensurePlayer();
      await player.setUrl(url);
      await player.play();
    } catch (e) {
      _log.w('MediaPlayerService: play failed: $e');
    }
  }

  Future<void> pause() async {
    await _player?.pause();
  }

  Future<void> resume() async {
    if (_currentState == MediaPlayerState.paused) {
      await _player?.play();
    }
  }

  Future<void> stop() async {
    await _player?.stop();
    // stop() triggers processingState == idle → _onPlayerState → _releasePlayer
  }

  Future<void> seek(int ms) async {
    await _player?.seek(Duration(milliseconds: ms));
  }

  /// Pauses media for a transient sound. Records whether it was playing so
  /// [resumeAfterDucking] can conditionally resume.
  Future<void> pauseForDucking() async {
    _wasPlayingBeforeDuck = _isPlaying;
    if (_isPlaying) await _player?.pause();
  }

  /// Resumes media after a transient sound, but only if it was playing before
  /// [pauseForDucking] was called.
  Future<void> resumeAfterDucking() async {
    if (_wasPlayingBeforeDuck) await _player?.play();
    _wasPlayingBeforeDuck = false;
  }

  void dispose() {
    _playerStateSub?.cancel();
    _statusController.close();
    _player?.dispose();
    _player = null;
  }
}

final mediaPlayerServiceProvider = Provider<MediaPlayerService>((ref) {
  final service = MediaPlayerService();
  ref.onDispose(service.dispose);
  return service;
});
