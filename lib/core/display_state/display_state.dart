import 'dart:typed_data';

enum MediaPlayerState { idle, buffering, playing, paused }

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
        precipitationProbability: json['precipitation_probability'] as int?,
      );
}

class CameraData {
  final String id;
  final String name;
  final Uint8List imageBytes;

  const CameraData({
    required this.id,
    required this.name,
    required this.imageBytes,
  });
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
        humidity: json['humidity'] as int?,
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

class DoorData {
  final String id;
  final String name;
  final bool open;
  const DoorData({required this.id, required this.name, required this.open});
  factory DoorData.fromJson(Map<String, dynamic> j) =>
      DoorData(id: j['id'] as String, name: j['name'] as String, open: j['open'] as bool);
}

class MotionData {
  final String id;
  final String name;
  final bool detected;
  const MotionData({required this.id, required this.name, required this.detected});
  factory MotionData.fromJson(Map<String, dynamic> j) =>
      MotionData(id: j['id'] as String, name: j['name'] as String, detected: j['detected'] as bool);
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
  final List<String> photos;
  final List<CameraData> cameras;
  final MediaPlayerState mediaState;
  final MediaTrack? mediaTrack;
  final bool shuffleEnabled;
  final List<DoorData> doors;
  final List<MotionData> motions;

  const DisplayState({
    required this.wakeWord,
    this.wakeWordSensitivity = 'medium',
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
    this.photos = const [],
    this.cameras = const [],
    this.mediaState = MediaPlayerState.idle,
    this.mediaTrack,
    this.shuffleEnabled = false,
    this.doors = const [],
    this.motions = const [],
  });

  DisplayState copyWith({
    String? wakeWord,
    String? wakeWordSensitivity,
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
    List<String>? photos,
    List<CameraData>? cameras,
    MediaPlayerState? mediaState,
    MediaTrack? mediaTrack,
    bool clearMediaTrack = false,
    bool? shuffleEnabled,
    List<DoorData>? doors,
    List<MotionData>? motions,
  }) {
    return DisplayState(
      wakeWord: wakeWord ?? this.wakeWord,
      wakeWordSensitivity: wakeWordSensitivity ?? this.wakeWordSensitivity,
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
      doors: doors ?? this.doors,
      motions: motions ?? this.motions,
    );
  }

  Map<String, dynamic> toJson() => {
        'wake_word': wakeWord,
        'wake_word_sensitivity': wakeWordSensitivity,
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
        'doors': doors.map((d) => {'id': d.id, 'name': d.name, 'open': d.open}).toList(),
        'motions': motions.map((m) => {'id': m.id, 'name': m.name, 'detected': m.detected}).toList(),
      };
}
