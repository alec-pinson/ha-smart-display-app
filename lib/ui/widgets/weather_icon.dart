import 'package:flutter/material.dart';

/// Maps HA weather condition strings to Material/custom icons + colours
class WeatherIcon extends StatelessWidget {
  final String condition;
  final double size;
  final Color? color;

  const WeatherIcon({
    super.key,
    required this.condition,
    this.size = 24,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, defaultColor) = _resolve(condition);
    return Icon(icon, size: size, color: color ?? defaultColor);
  }

  static (IconData, Color) _resolve(String condition) {
    switch (condition.toLowerCase()) {
      case 'sunny':
      case 'clear-night':
        return (Icons.wb_sunny_rounded, const Color(0xFFFFD54F));
      case 'partlycloudy':
      case 'partly-cloudy':
        return (Icons.wb_cloudy_rounded, const Color(0xFFB0BEC5));
      case 'cloudy':
      case 'overcast':
        return (Icons.cloud_rounded, const Color(0xFF90A4AE));
      case 'fog':
      case 'haze':
        return (Icons.foggy, const Color(0xFFB0BEC5));
      case 'rainy':
      case 'drizzle':
        return (Icons.grain_rounded, const Color(0xFF64B5F6));
      case 'pouring':
        return (Icons.thunderstorm_rounded, const Color(0xFF42A5F5));
      case 'snowy':
      case 'snowy-rainy':
        return (Icons.ac_unit_rounded, const Color(0xFFE3F2FD));
      case 'windy':
      case 'windy-variant':
        return (Icons.air_rounded, const Color(0xFF80CBC4));
      case 'lightning':
      case 'lightning-rainy':
        return (Icons.bolt_rounded, const Color(0xFFFFEE58));
      case 'hail':
        return (Icons.grain_rounded, const Color(0xFFB3E5FC));
      default:
        return (Icons.wb_cloudy_rounded, const Color(0xFF90A4AE));
    }
  }
}
