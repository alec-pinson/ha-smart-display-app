import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/display_state/display_state.dart';
import '../../core/display_state/display_state_notifier.dart';
import '../../core/timer/timer_service.dart';
import '../../ui/widgets/connection_indicator.dart';
import '../../ui/widgets/weather_icon.dart';

class AmbientScreen extends ConsumerStatefulWidget {
  const AmbientScreen({super.key});

  @override
  ConsumerState<AmbientScreen> createState() => _AmbientScreenState();
}

class _AmbientScreenState extends ConsumerState<AmbientScreen>
    with TickerProviderStateMixin {
  late AnimationController _auroraController;
  StreamSubscription? _alertSub;

  @override
  void initState() {
    super.initState();

    _auroraController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(displayStateProvider.notifier).pushInitialState();

      // Initialise timer service
      final timerService = ref.read(timerServiceProvider);
      _alertSub = timerService.firingStream.listen((alert) {
        if (alert != null && mounted) {
          _showFiringAlert(alert);
        }
      });
    });
  }

  void _showFiringAlert(FiringAlert alert) {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => _AlertDialog(alert: alert),
    );
  }

  @override
  void dispose() {
    _auroraController.dispose();
    _alertSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayState = ref.watch(displayStateProvider);
    final isAmbient = displayState.ambientActive;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Aurora background — always present, dims in ambient mode
          AnimatedOpacity(
            duration: const Duration(seconds: 2),
            opacity: isAmbient ? 0.3 : 1.0,
            child: _AuroraBackground(controller: _auroraController),
          ),

          // Main content
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 800),
            child: isAmbient
                ? _AmbientOverlay(key: const ValueKey('ambient'), state: displayState)
                : _NormalOverlay(key: const ValueKey('normal'), state: displayState),
          ),

          // Connection indicator — top right always
          const Positioned(
            top: 20,
            right: 24,
            child: ConnectionIndicator(),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Aurora animated background
// ---------------------------------------------------------------------------

class _AuroraBackground extends StatelessWidget {
  final AnimationController controller;
  const _AuroraBackground({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = controller.value;
        return CustomPaint(
          painter: _AuroraPainter(t),
          child: Container(),
        );
      },
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  _AuroraPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    // Deep space base
    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: const [
          Color(0xFF060B14),
          Color(0xFF0A1628),
          Color(0xFF060B14),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // Slow-moving aurora blobs
    _drawAuroraBlob(
      canvas, size,
      center: Offset(
        size.width * (0.2 + 0.15 * math.sin(t * math.pi * 2)),
        size.height * (0.3 + 0.1 * math.cos(t * math.pi * 2)),
      ),
      radiusX: size.width * 0.45,
      radiusY: size.height * 0.3,
      color: const Color(0xFF0D3B6E).withOpacity(0.5),
    );

    _drawAuroraBlob(
      canvas, size,
      center: Offset(
        size.width * (0.7 + 0.1 * math.cos(t * math.pi * 2 + 1)),
        size.height * (0.4 + 0.15 * math.sin(t * math.pi * 2 + 1)),
      ),
      radiusX: size.width * 0.4,
      radiusY: size.height * 0.35,
      color: const Color(0xFF0A4A3C).withOpacity(0.4),
    );

    _drawAuroraBlob(
      canvas, size,
      center: Offset(
        size.width * (0.45 + 0.08 * math.sin(t * math.pi * 2 + 2)),
        size.height * (0.65 + 0.08 * math.cos(t * math.pi * 2 + 2)),
      ),
      radiusX: size.width * 0.5,
      radiusY: size.height * 0.25,
      color: const Color(0xFF1A1A5E).withOpacity(0.3),
    );
  }

  void _drawAuroraBlob(
    Canvas canvas,
    Size size, {
    required Offset center,
    required double radiusX,
    required double radiusY,
    required Color color,
  }) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withOpacity(0)],
        stops: const [0, 1],
      ).createShader(Rect.fromCenter(
        center: center,
        width: radiusX * 2,
        height: radiusY * 2,
      ))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60);

    canvas.drawOval(
      Rect.fromCenter(center: center, width: radiusX * 2, height: radiusY * 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t;
}

// ---------------------------------------------------------------------------
// Normal mode overlay — clock top-left, weather, timers centre
// ---------------------------------------------------------------------------

class _NormalOverlay extends ConsumerWidget {
  final DisplayState state;
  const _NormalOverlay({super.key, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        // Clock + weather — top left
        const Positioned(
          top: 36,
          left: 40,
          child: _ClockWeatherPanel(),
        ),

        // Active timers — centre screen
        if (state.timers.isNotEmpty || state.alarms.isNotEmpty)
          Center(
            child: _TimerPanel(
              timers: state.timers,
              alarms: state.alarms,
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Ambient mode overlay — minimal, centred
// ---------------------------------------------------------------------------

class _AmbientOverlay extends StatelessWidget {
  final DisplayState state;
  const _AmbientOverlay({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AmbientClock(),
          if (state.weather != null) ...[
            const SizedBox(height: 12),
            _AmbientWeather(weather: state.weather!),
          ],
        ],
      ),
    );
  }
}

class _AmbientClock extends StatefulWidget {
  @override
  State<_AmbientClock> createState() => _AmbientClockState();
}

class _AmbientClockState extends State<_AmbientClock> {
  late Timer _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      DateFormat('HH:mm').format(_now),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 80,
        fontWeight: FontWeight.w200,
        letterSpacing: -1,
        height: 1,
      ),
    );
  }
}

class _AmbientWeather extends StatelessWidget {
  final WeatherData weather;
  const _AmbientWeather({required this.weather});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        WeatherIcon(condition: weather.condition, size: 18, color: Colors.white38),
        const SizedBox(width: 6),
        Text(
          weather.temperature != null
              ? '${weather.temperature!.round()}${weather.temperatureUnit}'
              : weather.condition,
          style: const TextStyle(color: Colors.white38, fontSize: 18),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Clock + weather panel (normal mode, top-left)
// ---------------------------------------------------------------------------

class _ClockWeatherPanel extends StatefulWidget {
  const _ClockWeatherPanel();

  @override
  State<_ClockWeatherPanel> createState() => _ClockWeatherPanelState();
}

class _ClockWeatherPanelState extends State<_ClockWeatherPanel> {
  late Timer _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final weather = ref.watch(displayStateProvider).weather;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Time
            Text(
              DateFormat('HH:mm').format(_now),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 96,
                fontWeight: FontWeight.w200,
                letterSpacing: -2,
                height: 1,
              ),
            ),
            const SizedBox(height: 4),

            // Date + weather on same line
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  DateFormat('EEEE, d MMMM').format(_now),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 20,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 0.5,
                  ),
                ),
                if (weather != null) ...[
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    width: 1,
                    height: 16,
                    color: Colors.white24,
                  ),
                  WeatherIcon(
                    condition: weather.condition,
                    size: 20,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    weather.temperature != null
                        ? '${weather.temperature!.round()}${weather.temperatureUnit}'
                        : _capitalize(weather.condition),
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 20,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

// ---------------------------------------------------------------------------
// Timer / alarm panel — centre screen
// ---------------------------------------------------------------------------

class _TimerPanel extends ConsumerWidget {
  final List<TimerData> timers;
  final List<AlarmData> alarms;

  const _TimerPanel({required this.timers, required this.alarms});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...timers.map((t) => _TimerCard(timer: t)),
        ...alarms.map((a) => _AlarmCard(alarm: a)),
      ],
    );
  }
}

class _TimerCard extends ConsumerStatefulWidget {
  final TimerData timer;
  const _TimerCard({required this.timer});

  @override
  ConsumerState<_TimerCard> createState() => _TimerCardState();
}

class _TimerCardState extends ConsumerState<_TimerCard> {
  late Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.timer.remaining;
    final h = remaining.inHours;
    final m = remaining.inMinutes % 60;
    final s = remaining.inSeconds % 60;
    final timeStr = h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';

    final isUrgent = remaining.inSeconds <= 60;

    return GestureDetector(
      onTap: () => ref.read(displayStateProvider.notifier).dismissTimer(widget.timer.id),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isUrgent
                ? const Color(0xFFFF6B6B).withOpacity(0.6)
                : Colors.white.withOpacity(0.12),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: isUrgent
                  ? const Color(0xFFFF6B6B).withOpacity(0.15)
                  : Colors.black.withOpacity(0.3),
              blurRadius: 24,
            ),
          ],
        ),
        child: Column(
          children: [
            Text(
              widget.timer.label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 16,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              timeStr,
              style: TextStyle(
                color: isUrgent
                    ? const Color(0xFFFF6B6B)
                    : Colors.white,
                fontSize: 72,
                fontWeight: FontWeight.w200,
                letterSpacing: -1,
                height: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap to dismiss',
              style: TextStyle(
                color: Colors.white.withOpacity(0.25),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlarmCard extends ConsumerWidget {
  final AlarmData alarm;
  const _AlarmCard({required this.alarm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => ref.read(displayStateProvider.notifier).dismissAlarm(alarm.id),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.alarm_rounded,
                color: Colors.white.withOpacity(0.6), size: 24),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alarm.label,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.6), fontSize: 14),
                ),
                Text(
                  alarm.time,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w200,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Firing alert dialog (timer/alarm expired)
// ---------------------------------------------------------------------------

class _AlertDialog extends ConsumerWidget {
  final FiringAlert alert;
  const _AlertDialog({required this.alert});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.6),
              blurRadius: 40,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              alert.type == AlertType.timer
                  ? Icons.timer_rounded
                  : Icons.alarm_rounded,
              size: 48,
              color: const Color(0xFF58A6FF),
            ),
            const SizedBox(height: 16),
            Text(
              alert.type == AlertType.timer ? 'Timer Complete' : 'Alarm',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              alert.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.w300,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            GestureDetector(
              onTap: () {
                ref.read(timerServiceProvider).dismiss(alert);
                Navigator.of(context).pop();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF58A6FF),
                  borderRadius: BorderRadius.circular(50),
                ),
                child: const Text(
                  'Dismiss',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
