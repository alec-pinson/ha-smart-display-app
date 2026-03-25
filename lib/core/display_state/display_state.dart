import 'dart:io';
import 'dart:typed_data';

enum MediaPlayerState { idle, buffering, playing, paused }

class ImmichConfig {
  final String url;
  final String apiKey;
  const ImmichConfig({required this.url, required this.apiKey});
}

class PhotoItem {
  final String url;
  final String? album;
  final String? location;
  final String? date;
  const PhotoItem({required this.url, this.album, this.location, this.date});

  factory PhotoItem.fromJson(dynamic json) {
    if (json is String) return PhotoItem(url: json);
    final map = json as Map<String, dynamic>;
    return PhotoItem(
      url: map['url'] as String,
      album: map['album'] as String?,
      location: map['location'] as String?,
      date: map['date'] as String?,
    );
  }
}

class MediaTrack {
  final String title;
  final String? artist;
  final String? album;
  final String? artUrl;
  final int durationMs;
  final int positionMs;

  const MediaTrack({
    required this.title,
    this.artist,
    this.album,
    this.artUrl,
    this.durationMs = 0,
    this.positionMs = 0,
  });

  MediaTrack withPosition(int ms) => MediaTrack(
    title: title,
    artist: artist,
    album: album,
    artUrl: artUrl,
    durationMs: durationMs,
    positionMs: ms,
  );

  factory MediaTrack.fromJson(Map<String, dynamic> json) => MediaTrack(
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String?,
    album: json['album'] as String?,
    artUrl: json['art_url'] as String?,
    durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    if (artist != null) 'artist': artist,
    if (album != null) 'album': album,
    if (artUrl != null) 'art_url': artUrl,
    'duration_ms': durationMs,
    'position_ms': positionMs,
  };
}

class ForecastPeriod {
  final String datetime;
  final double? temperature;
  final String condition;
  final int? precipitationProbability;

  const ForecastPeriod({
    required this.datetime,
    this.temperature,
    required this.condition,
    this.precipitationProbability,
  });

  factory ForecastPeriod.fromJson(Map<String, dynamic> json) => ForecastPeriod(
        datetime: json['datetime'] as String? ?? '',
        temperature: (json['temperature'] as num?)?.toDouble(),
        condition: json['condition'] as String? ?? 'unknown',
        precipitationProbability: (json['precipitation_probability'] as num?)?.toInt(),
      );
}

enum CameraStreamType { snapshot, video, videoAudio }

class CameraData {
  final String id;
  final String name;
  final Uint8List imageBytes;
  final CameraStreamType streamType;
  final String? frigateUrl;
  final String? go2rtcUrl;

  const CameraData({
    required this.id,
    required this.name,
    required this.imageBytes,
    this.streamType = CameraStreamType.snapshot,
    this.frigateUrl,
    this.go2rtcUrl,
  });

  String get _cameraName => id.replaceFirst('camera.', '');

  /// Snapshot poll URL — fetches the latest frame as a static JPEG from Frigate.
  /// Preferred over MJPEG streaming because each request returns the current frame
  /// with no TCP buffering lag.
  String? get snapshotPollUrl {
    if (streamType == CameraStreamType.snapshot) return null;
    if (frigateUrl != null) return '$frigateUrl/api/$_cameraName/latest.jpg?h=480';
    return null;
  }

  /// MJPEG fallback URL — only used when frigateUrl is not set (e.g. go2rtc-only setup).
  String? get streamUrl {
    if (streamType == CameraStreamType.snapshot) return null;
    if (frigateUrl != null) return '$frigateUrl/api/$_cameraName?h=480&fps=5';
    if (go2rtcUrl != null) return '$go2rtcUrl/api/stream.mjpeg?src=$_cameraName';
    return null;
  }

  /// AAC audio stream URL — only available when using go2rtc and videoAudio mode.
  String? get audioUrl {
    if (streamType != CameraStreamType.videoAudio || go2rtcUrl == null) return null;
    return '$go2rtcUrl/api/stream.aac?src=$_cameraName';
  }
}

class ClimateData {
  final String name;
  final double? currentTemperature;
  final int? humidity;
  final double? targetTemperature;
  final String hvacMode;
  final List<String> hvacModes;
  final double minTemp;
  final double maxTemp;
  final String unit;

  const ClimateData({
    required this.name,
    this.currentTemperature,
    this.humidity,
    this.targetTemperature,
    required this.hvacMode,
    required this.hvacModes,
    required this.minTemp,
    required this.maxTemp,
    required this.unit,
  });

  factory ClimateData.fromJson(Map<String, dynamic> json) => ClimateData(
        name: json['name'] as String? ?? 'Climate',
        currentTemperature: (json['current_temperature'] as num?)?.toDouble(),
        humidity: json['humidity'] as int?,
        targetTemperature: (json['target_temperature'] as num?)?.toDouble(),
        hvacMode: json['hvac_mode'] as String? ?? 'off',
        hvacModes: (json['hvac_modes'] as List?)?.cast<String>() ?? const ['off'],
        minTemp: (json['min_temp'] as num?)?.toDouble() ?? 7.0,
        maxTemp: (json['max_temp'] as num?)?.toDouble() ?? 35.0,
        unit: json['unit'] as String? ?? '°C',
      );
}

class WeatherData {
  final String condition;
  final double? temperature;
  final String temperatureUnit;
  final int? humidity;
  final double? windSpeed;
  final List<ForecastPeriod> forecast;

  const WeatherData({
    required this.condition,
    this.temperature,
    required this.temperatureUnit,
    this.humidity,
    this.windSpeed,
    this.forecast = const [],
  });

  factory WeatherData.fromJson(Map<String, dynamic> json) => WeatherData(
        condition: json['condition'] as String? ?? 'unknown',
        temperature: (json['temperature'] as num?)?.toDouble(),
        temperatureUnit: json['temperature_unit'] as String? ?? '°C',
        humidity: (json['humidity'] as num?)?.toInt(),
        windSpeed: (json['wind_speed'] as num?)?.toDouble(),
        forecast: (json['forecast'] as List? ?? [])
            .map((f) => ForecastPeriod.fromJson(f as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'condition': condition,
        'temperature': temperature,
        'temperature_unit': temperatureUnit,
        'humidity': humidity,
        'wind_speed': windSpeed,
      };
}

class TimerData {
  final String id;
  final String label;
  final int endsAt; // unix timestamp seconds

  const TimerData({
    required this.id,
    required this.label,
    required this.endsAt,
  });

  factory TimerData.fromJson(Map<String, dynamic> json) {
    // Prefer remaining_seconds (sent by integration to avoid clock drift
    // and correctly handle reconnect). Fall back to ends_at absolute timestamp.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final int endsAt;
    if (json.containsKey('remaining_seconds')) {
      endsAt = now + (json['remaining_seconds'] as int);
    } else {
      endsAt = json['ends_at'] as int;
    }
    return TimerData(
      id: json['id'] as String,
      label: json['label'] as String? ?? 'Timer',
      endsAt: endsAt,
    );
  }

  Duration get remaining {
    final secs = endsAt - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Duration(seconds: secs.clamp(0, 86400));
  }

  bool get isExpired => remaining.inSeconds <= 0;
}

class AlarmData {
  final String id;
  final String label;
  final String time; // "HH:MM"

  const AlarmData({
    required this.id,
    required this.label,
    required this.time,
  });

  factory AlarmData.fromJson(Map<String, dynamic> json) {
    // Strip seconds if time is "HH:MM:SS" (HA time selector sends this format)
    final raw = json['time'] as String;
    final time = raw.length > 5 ? raw.substring(0, 5) : raw;
    return AlarmData(
      id: json['id'] as String,
      label: json['label'] as String? ?? 'Alarm',
      time: time,
    );
  }
}

class BrowseItem {
  final String title;
  final String? subtitle;
  final String? thumbnail;
  final String mediaContentId;
  final String mediaContentType;
  final bool canPlay;
  final bool canExpand;

  const BrowseItem({
    required this.title,
    this.subtitle,
    this.thumbnail,
    required this.mediaContentId,
    required this.mediaContentType,
    this.canPlay = false,
    this.canExpand = false,
  });

  factory BrowseItem.fromJson(Map<String, dynamic> json) => BrowseItem(
    title: json['title'] as String? ?? '',
    subtitle: json['subtitle'] as String?,
    thumbnail: json['thumbnail'] as String?,
    mediaContentId: json['media_content_id'] as String? ?? '',
    mediaContentType: json['media_content_type'] as String? ?? '',
    canPlay: json['can_play'] as bool? ?? false,
    canExpand: json['can_expand'] as bool? ?? false,
  );
}

class PillData {
  final String id;
  final String text;
  final String? icon;
  final String? color;
  final String position;

  const PillData({
    required this.id,
    required this.text,
    this.icon,
    this.color,
    this.position = 'under_clock',
  });

  factory PillData.fromJson(Map<String, dynamic> j) => PillData(
    id: j['id'] as String,
    text: j['text'] as String,
    icon: j['icon'] as String?,
    color: j['color'] as String?,
    position: j['position'] as String? ?? 'under_clock',
  );
}

class BrowseResult {
  final String category;
  final List<BrowseItem> items;

  const BrowseResult({required this.category, required this.items});

  factory BrowseResult.fromJson(Map<String, dynamic> json) => BrowseResult(
    category: json['category'] as String? ?? '',
    items: (json['items'] as List? ?? [])
        .map((i) => BrowseItem.fromJson(i as Map<String, dynamic>))
        .toList(),
  );
}

class DisplayState {
  final String wakeWord;
  final String wakeWordSensitivity; // 'low' | 'medium' | 'high'
  final String vadSensitivity; // 'default' | 'relaxed' | 'aggressive'
  final bool wakeWordSound; // play audio on wake word detection
  final bool microphoneMuted; // disables wake word detection entirely
  final String ambientMode;
  final bool ambientActive;
  final int brightness;
  final bool autoBrightness;
  final int volume; // 0–100
  final bool doNotDisturb;
  final bool screenOn;
  final int uptimeSeconds;
  final int wakeWordCount;
  final double? lux; // null until first light sensor reading
  final WeatherData? weather;
  final ClimateData? climate;
  final List<TimerData> timers;
  final List<AlarmData> alarms;
  final List<PhotoItem> photos;
  final List<CameraData> cameras;
  final MediaPlayerState mediaState;
  final MediaTrack? mediaTrack;
  final bool shuffleEnabled;
  final List<PillData> pills;
  final ImmichConfig? immichConfig;
  final int slideshowInterval; // seconds
  final List<String> availableModes;

  const DisplayState({
    required this.wakeWord,
    this.wakeWordSensitivity = 'medium',
    this.vadSensitivity = 'default',
    this.wakeWordSound = true,
    this.microphoneMuted = false,
    required this.ambientMode,
    required this.ambientActive,
    required this.brightness,
    this.autoBrightness = false,
    this.volume = 50,
    required this.doNotDisturb,
    required this.screenOn,
    required this.uptimeSeconds,
    required this.wakeWordCount,
    this.lux,
    this.weather,
    this.climate,
    this.timers = const [],
    this.alarms = const [],
    this.photos = const <PhotoItem>[],
    this.cameras = const [],
    this.mediaState = MediaPlayerState.idle,
    this.mediaTrack,
    this.shuffleEnabled = false,
    this.pills = const [],
    this.immichConfig,
    this.slideshowInterval = 60,
    this.availableModes = const ['clock', 'weather', 'cameras', 'music'],
  });

  DisplayState copyWith({
    String? wakeWord,
    String? wakeWordSensitivity,
    String? vadSensitivity,
    bool? wakeWordSound,
    bool? microphoneMuted,
    String? ambientMode,
    bool? ambientActive,
    int? brightness,
    bool? autoBrightness,
    int? volume,
    bool? doNotDisturb,
    bool? screenOn,
    int? uptimeSeconds,
    int? wakeWordCount,
    double? lux,
    WeatherData? weather,
    ClimateData? climate,
    List<TimerData>? timers,
    List<AlarmData>? alarms,
    List<PhotoItem>? photos,
    List<CameraData>? cameras,
    MediaPlayerState? mediaState,
    MediaTrack? mediaTrack,
    bool clearMediaTrack = false,
    bool? shuffleEnabled,
    List<PillData>? pills,
    ImmichConfig? immichConfig,
    int? slideshowInterval,
    List<String>? availableModes,
  }) {
    return DisplayState(
      wakeWord: wakeWord ?? this.wakeWord,
      wakeWordSensitivity: wakeWordSensitivity ?? this.wakeWordSensitivity,
      vadSensitivity: vadSensitivity ?? this.vadSensitivity,
      wakeWordSound: wakeWordSound ?? this.wakeWordSound,
      microphoneMuted: microphoneMuted ?? this.microphoneMuted,
      ambientMode: ambientMode ?? this.ambientMode,
      ambientActive: ambientActive ?? this.ambientActive,
      brightness: brightness ?? this.brightness,
      autoBrightness: autoBrightness ?? this.autoBrightness,
      volume: volume ?? this.volume,
      doNotDisturb: doNotDisturb ?? this.doNotDisturb,
      screenOn: screenOn ?? this.screenOn,
      uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
      wakeWordCount: wakeWordCount ?? this.wakeWordCount,
      lux: lux ?? this.lux,
      weather: weather ?? this.weather,
      climate: climate ?? this.climate,
      timers: timers ?? this.timers,
      alarms: alarms ?? this.alarms,
      photos: photos ?? this.photos,
      cameras: cameras ?? this.cameras,
      mediaState: mediaState ?? this.mediaState,
      mediaTrack: clearMediaTrack ? null : (mediaTrack ?? this.mediaTrack),
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      pills: pills ?? this.pills,
      immichConfig: immichConfig ?? this.immichConfig,
      slideshowInterval: slideshowInterval ?? this.slideshowInterval,
      availableModes: availableModes ?? this.availableModes,
    );
  }

  Map<String, dynamic> toJson() => {
        'wake_word': wakeWord,
        'wake_word_sensitivity': wakeWordSensitivity,
        'vad_sensitivity': vadSensitivity,
        'wake_word_sound': wakeWordSound,
        'microphone_muted': microphoneMuted,
        'ambient_mode': ambientMode,
        'ambient_active': ambientActive,
        'brightness': brightness,
        'auto_brightness': autoBrightness,
        'volume': volume,
        'do_not_disturb': doNotDisturb,
        'screen_on': screenOn,
        'uptime_seconds': uptimeSeconds,
        'wake_word_count': wakeWordCount,
        if (lux != null) 'lux': double.parse(lux!.toStringAsFixed(1)),
        'media_state': mediaState.name,
        if (mediaTrack != null) 'media_track': mediaTrack!.toJson(),
        'memory_mb': (ProcessInfo.currentRss / (1024 * 1024)).round(),
        'thread_count': _readThreadCount(),
      };
}

int _readThreadCount() {
  try {
    final status = File('/proc/self/status').readAsStringSync();
    for (final line in status.split('\n')) {
      if (line.startsWith('Threads:')) {
        return int.tryParse(line.split(':').last.trim()) ?? 0;
      }
    }
  } catch (_) {}
  return 0;
}
