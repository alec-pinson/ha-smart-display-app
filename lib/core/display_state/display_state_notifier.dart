import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

import 'display_state.dart';
import '../camera_analysis/camera_analysis_service.dart';
import '../media/media_player_service.dart';
import '../server/display_server.dart';
import '../timer/timer_service.dart';
import '../voice/voice_assistant_service.dart';

const _androidOptions = AndroidOptions(encryptedSharedPreferences: true);
const _storage = FlutterSecureStorage(aOptions: _androidOptions);
const _wakeWordKey = 'wake_word';
const _wakeWordSensitivityKey = 'wake_word_sensitivity';
const _brightnessKey = 'brightness';
const _autoBrightnessKey = 'auto_brightness';

Future<String> loadPersistedWakeWord() async {
  return await _storage.read(key: _wakeWordKey) ?? 'alexa';
}

Future<String> loadPersistedWakeWordSensitivity() async {
  return await _storage.read(key: _wakeWordSensitivityKey) ?? 'medium';
}

Future<int> loadPersistedBrightness() async {
  final val = await _storage.read(key: _brightnessKey);
  return val != null ? int.tryParse(val) ?? 128 : 128;
}

Future<bool> loadPersistedAutoBrightness() async {
  final val = await _storage.read(key: _autoBrightnessKey);
  return val == 'true';
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
  StreamSubscription? _mediaStatusSub;
  Timer? _mediaIdleTimer;
  Timer? _musicInactiveTimer;
  static const _musicInactiveTimeout = Duration(minutes: 5);

  final _notificationController = StreamController<NotificationData>.broadcast();
  Stream<NotificationData> get notificationStream => _notificationController.stream;

  final _focusedCameraController = StreamController<CameraData>.broadcast();
  Stream<CameraData> get focusedCameraStream => _focusedCameraController.stream;

  final _openCameraController = StreamController<CameraData>.broadcast();
  Stream<CameraData> get openCameraStream => _openCameraController.stream;

  final _browseResultController = StreamController<BrowseResult>.broadcast();
  Stream<BrowseResult> get browseResultStream => _browseResultController.stream;

  void setFocusedCamera(String? id) {
    _focusedCamera = id;
    _pushState();
  }

  DisplayStateNotifier(this._ref, {String initialWakeWord = 'alexa', String initialWakeWordSensitivity = 'medium', int initialVolume = 50, int initialBrightness = 128, bool initialAutoBrightness = false})
      : super(DisplayState(
          wakeWord: initialWakeWord,
          wakeWordSensitivity: initialWakeWordSensitivity,
          ambientMode: 'clock',
          ambientActive: false,
          brightness: initialBrightness,
          autoBrightness: initialAutoBrightness,
          volume: initialVolume,
          doNotDisturb: false,
          screenOn: true,
          uptimeSeconds: 0,
          wakeWordCount: 0,
        )) {
    _startHeartbeat();
    _mediaStatusSub = _ref.read(mediaPlayerServiceProvider).statusStream.listen(_onMediaStatus);
    // Apply persisted brightness immediately on startup
    if (initialAutoBrightness) {
      _applyBrightness(-1);
    } else {
      _applyBrightness(initialBrightness);
    }
  }

  void _onMediaStatus(MediaStatus status) {
    if (status.state == MediaPlayerState.idle) {
      // Debounce idle — during track changes just_audio briefly reports idle
      // before the next play_media arrives. Only commit idle after 1.5s.
      _mediaIdleTimer ??= Timer(const Duration(milliseconds: 1500), () {
        _mediaIdleTimer = null;
        state = state.copyWith(mediaState: MediaPlayerState.idle);
        _pushState();
        _startMusicInactiveTimer();
      });
    } else {
      _mediaIdleTimer?.cancel();
      _mediaIdleTimer = null;
      state = state.copyWith(
        mediaState: status.state,
        mediaTrack: state.mediaTrack?.withPosition(status.positionMs),
      );
      _pushState();
      if (status.state == MediaPlayerState.playing || status.state == MediaPlayerState.buffering) {
        _cancelMusicInactiveTimer();
      } else if (status.state == MediaPlayerState.paused) {
        _startMusicInactiveTimer();
      }
    }
  }

  void _startMusicInactiveTimer() {
    _musicInactiveTimer?.cancel();
    _musicInactiveTimer = Timer(_musicInactiveTimeout, _onMusicInactive);
  }

  void _cancelMusicInactiveTimer() {
    _musicInactiveTimer?.cancel();
    _musicInactiveTimer = null;
  }

  void _onMusicInactive() {
    _musicInactiveTimer = null;
    var newState = state;
    if (newState.ambientMode == 'music') {
      newState = newState.copyWith(ambientMode: 'clock');
    }
    newState = newState.copyWith(clearMediaTrack: true, mediaState: MediaPlayerState.idle);
    state = newState;
    _pushState();
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
      _storage.write(key: _autoBrightnessKey, value: auto.toString());
      if (auto) {
        _applyBrightness(-1); // -1 signals auto to native layer
      } else {
        _applyBrightness(newState.brightness);
      }
    }
    if (payload.containsKey('brightness')) {
      final b = payload['brightness'] as int;
      newState = newState.copyWith(brightness: b);
      _storage.write(key: _brightnessKey, value: b.toString());
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
    if (payload.containsKey('shuffle_enabled')) {
      newState = newState.copyWith(shuffleEnabled: payload['shuffle_enabled'] as bool);
    }
    if (payload.containsKey('media_track')) {
      final mt = payload['media_track'] as Map<String, dynamic>;
      newState = newState.copyWith(mediaTrack: MediaTrack.fromJson(mt));
    }
    if (payload.containsKey('play_media')) {
      // Cancel any pending idle/inactive timers — a new track is starting
      _mediaIdleTimer?.cancel();
      _mediaIdleTimer = null;
      _cancelMusicInactiveTimer();
      final pm = payload['play_media'] as Map<String, dynamic>;
      final url = pm['url'] as String;
      final title = pm['title'] as String? ?? '';
      if (title.isNotEmpty) {
        // Real metadata — update the displayed track immediately
        final track = MediaTrack(
          title: title,
          artist: pm['artist'] as String?,
          album: pm['album'] as String?,
          artUrl: pm['art_url'] as String?,
          durationMs: (pm['duration_ms'] as num?)?.toInt() ?? 0,
        );
        newState = newState.copyWith(mediaState: MediaPlayerState.buffering, mediaTrack: track);
      } else {
        // No metadata — keep current track displayed; media_track command will update it
        newState = newState.copyWith(mediaState: MediaPlayerState.buffering);
      }
      unawaited(_ref.read(mediaPlayerServiceProvider).play(url));
    }
    if (payload.containsKey('media_command')) {
      final cmd = payload['media_command'] as String;
      final svc = _ref.read(mediaPlayerServiceProvider);
      switch (cmd) {
        case 'pause':
          unawaited(svc.pause());
        case 'play':
          _mediaIdleTimer?.cancel();
          _mediaIdleTimer = null;
          _cancelMusicInactiveTimer();
          unawaited(svc.resume());
        case 'stop':
          unawaited(svc.stop());
          newState = newState.copyWith(mediaState: MediaPlayerState.idle, clearMediaTrack: true);
        case 'seek':
          final ms = (payload['position_ms'] as num?)?.toInt() ?? 0;
          unawaited(svc.seek(ms));
        case 'next':
        case 'previous':
          // No-op for URL streaming; HA drives queue
          break;
      }
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
    if (payload.containsKey('doors')) {
      final list = (payload['doors'] as List).cast<Map<String, dynamic>>();
      newState = newState.copyWith(doors: list.map(DoorData.fromJson).toList());
    }
    if (payload.containsKey('motions')) {
      final list = (payload['motions'] as List).cast<Map<String, dynamic>>();
      newState = newState.copyWith(motions: list.map(MotionData.fromJson).toList());
    }
    if (payload.containsKey('browse_result')) {
      final br = payload['browse_result'] as Map<String, dynamic>;
      _browseResultController.add(BrowseResult.fromJson(br));
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

  void sendMediaCommand(String command) {
    final svc = _ref.read(mediaPlayerServiceProvider);
    switch (command) {
      case 'pause':
        unawaited(svc.pause());
      case 'play':
        _mediaIdleTimer?.cancel();
        _mediaIdleTimer = null;
        unawaited(svc.resume());
      case 'stop':
        _mediaIdleTimer?.cancel();
        _mediaIdleTimer = null;
        _cancelMusicInactiveTimer();
        unawaited(svc.stop());
        state = state.copyWith(mediaState: MediaPlayerState.idle, clearMediaTrack: true);
        _pushState();
      case 'next':
      case 'previous':
      case 'shuffle':
        _ref.read(displayServerProvider).sendEvent({
          'event': 'media_command',
          'command': command,
        });
    }
  }

  void setAmbientMode(String mode) {
    state = state.copyWith(ambientMode: mode);
    _pushState();
  }

  void sendBrowseRequest(String category) {
    _ref.read(displayServerProvider).sendEvent({
      'event': 'browse_media',
      'category': category,
    });
  }

  void sendPlayMediaItem(String mediaContentId, String mediaContentType) {
    _ref.read(displayServerProvider).sendEvent({
      'event': 'play_media_item',
      'media_content_id': mediaContentId,
      'media_content_type': mediaContentType,
    });
  }

  void recordWakeWordDetection() {
    state = state.copyWith(wakeWordCount: state.wakeWordCount + 1);
    _pushState();
  }

  /// Called by CameraAnalysisService when a new lux reading arrives from the light sensor.
  void updateLux(double? lux) {
    state = state.copyWith(lux: lux);
    // Lux updates are sent on the next 30s heartbeat; no immediate push needed.
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
    _mediaStatusSub?.cancel();
    _mediaIdleTimer?.cancel();
    _musicInactiveTimer?.cancel();
    _notificationController.close();
    _focusedCameraController.close();
    _openCameraController.close();
    _browseResultController.close();
    super.dispose();
  }
}

final displayStateProvider =
    StateNotifierProvider<DisplayStateNotifier, DisplayState>((ref) {
  return DisplayStateNotifier(ref);
});
