class WeatherData {
  final String condition;
  final double? temperature;
  final String temperatureUnit;
  final int? humidity;
  final double? windSpeed;

  const WeatherData({
    required this.condition,
    this.temperature,
    required this.temperatureUnit,
    this.humidity,
    this.windSpeed,
  });

  factory WeatherData.fromJson(Map<String, dynamic> json) => WeatherData(
        condition: json['condition'] as String? ?? 'unknown',
        temperature: (json['temperature'] as num?)?.toDouble(),
        temperatureUnit: json['temperature_unit'] as String? ?? '°C',
        humidity: json['humidity'] as int?,
        windSpeed: (json['wind_speed'] as num?)?.toDouble(),
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

  factory TimerData.fromJson(Map<String, dynamic> json) => TimerData(
        id: json['id'] as String,
        label: json['label'] as String? ?? 'Timer',
        endsAt: json['ends_at'] as int,
      );

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

  factory AlarmData.fromJson(Map<String, dynamic> json) => AlarmData(
        id: json['id'] as String,
        label: json['label'] as String? ?? 'Alarm',
        time: json['time'] as String,
      );
}

class DisplayState {
  final String wakeWord;
  final String ambientMode;
  final bool ambientActive;
  final int brightness;
  final bool doNotDisturb;
  final bool screenOn;
  final int uptimeSeconds;
  final int wakeWordCount;
  final WeatherData? weather;
  final List<TimerData> timers;
  final List<AlarmData> alarms;

  const DisplayState({
    required this.wakeWord,
    required this.ambientMode,
    required this.ambientActive,
    required this.brightness,
    required this.doNotDisturb,
    required this.screenOn,
    required this.uptimeSeconds,
    required this.wakeWordCount,
    this.weather,
    this.timers = const [],
    this.alarms = const [],
  });

  DisplayState copyWith({
    String? wakeWord,
    String? ambientMode,
    bool? ambientActive,
    int? brightness,
    bool? doNotDisturb,
    bool? screenOn,
    int? uptimeSeconds,
    int? wakeWordCount,
    WeatherData? weather,
    List<TimerData>? timers,
    List<AlarmData>? alarms,
  }) {
    return DisplayState(
      wakeWord: wakeWord ?? this.wakeWord,
      ambientMode: ambientMode ?? this.ambientMode,
      ambientActive: ambientActive ?? this.ambientActive,
      brightness: brightness ?? this.brightness,
      doNotDisturb: doNotDisturb ?? this.doNotDisturb,
      screenOn: screenOn ?? this.screenOn,
      uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
      wakeWordCount: wakeWordCount ?? this.wakeWordCount,
      weather: weather ?? this.weather,
      timers: timers ?? this.timers,
      alarms: alarms ?? this.alarms,
    );
  }

  Map<String, dynamic> toJson() => {
        'wake_word': wakeWord,
        'ambient_mode': ambientMode,
        'ambient_active': ambientActive,
        'brightness': brightness,
        'do_not_disturb': doNotDisturb,
        'screen_on': screenOn,
        'uptime_seconds': uptimeSeconds,
        'wake_word_count': wakeWordCount,
      };
}
