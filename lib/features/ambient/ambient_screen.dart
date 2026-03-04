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
  StreamSubscription? _notificationSub;

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

      // Notification stream
      final notifier = ref.read(displayStateProvider.notifier);
      _notificationSub = notifier.notificationStream.listen((notification) {
        if (mounted) _showNotification(notification);
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

  void _showNotification(NotificationData notification) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black38,
      builder: (_) => _NotificationDialog(notification: notification),
    );
  }

  @override
  void dispose() {
    _auroraController.dispose();
    _alertSub?.cancel();
    _notificationSub?.cancel();
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

          // Photo slideshow — clock mode background when photos are configured
          if (!isAmbient &&
              displayState.ambientMode == 'clock' &&
              displayState.photos.isNotEmpty)
            _AmbientPhotoSlideshow(photos: displayState.photos),

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

          // Screen off overlay — always in tree so AnimatedOpacity can fade
          IgnorePointer(
            ignoring: displayState.screenOn,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 500),
              opacity: displayState.screenOn ? 0.0 : 1.0,
              child: Container(color: Colors.black),
            ),
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
    final isClockMode = state.ambientMode == 'clock';
    return Stack(
      children: [
        // Mode content — always fills the screen so Stack never collapses
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: _buildModeContent(state, context, ref),
          ),
        ),

        // Clock + weather — only in clock mode
        if (isClockMode)
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

  Widget _buildModeContent(DisplayState state, BuildContext context, WidgetRef ref) {
    switch (state.ambientMode) {
      case 'weather':
        return _AmbientWeatherFull(
          key: const ValueKey('weather'),
          weather: state.weather,
        );
      case 'cameras':
        return _AmbientCameraGrid(
          key: const ValueKey('cameras'),
          cameras: state.cameras,
          onCameraTap: (camera) {
            final notifier = ref.read(displayStateProvider.notifier);
            notifier.setFocusedCamera(camera.id);
            showDialog(
              context: context,
              barrierColor: Colors.black,
              builder: (_) => _CameraFullScreen(
                initialCamera: camera,
                notifier: notifier,
              ),
            ).then((_) => notifier.setFocusedCamera(null));
          },
        );
      default:
        return const SizedBox.expand(key: ValueKey('clock'));
    }
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          DateFormat('HH:mm').format(_now),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 80,
            fontWeight: FontWeight.w200,
            letterSpacing: -1,
            height: 1,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          DateFormat('EEEE, d MMMM').format(_now),
          style: TextStyle(
            color: Colors.white.withOpacity(0.4),
            fontSize: 18,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
        ),
      ],
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
// Ambient mode: full-screen weather
// ---------------------------------------------------------------------------

class _AmbientWeatherFull extends StatelessWidget {
  final WeatherData? weather;
  const _AmbientWeatherFull({super.key, required this.weather});

  @override
  Widget build(BuildContext context) {
    if (weather == null) return const SizedBox.shrink();
    final w = weather!;
    final forecast = _filterForecast(w.forecast);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Main weather
        WeatherIcon(condition: w.condition, size: 96),
        const SizedBox(height: 16),
        if (w.temperature != null)
          Text(
            '${w.temperature!.round()}${w.temperatureUnit}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 72,
              fontWeight: FontWeight.w200,
              height: 1,
            ),
          ),
        const SizedBox(height: 8),
        Text(
          _capitalize(w.condition),
          style: TextStyle(
            color: Colors.white.withOpacity(0.55),
            fontSize: 22,
            fontWeight: FontWeight.w300,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (w.humidity != null) ...[
              Icon(Icons.water_drop_outlined, color: Colors.white38, size: 18),
              const SizedBox(width: 4),
              Text('${w.humidity}%',
                  style: const TextStyle(color: Colors.white38, fontSize: 18)),
              const SizedBox(width: 24),
            ],
            if (w.windSpeed != null) ...[
              Icon(Icons.air_rounded, color: Colors.white38, size: 18),
              const SizedBox(width: 4),
              Text('${w.windSpeed!.round()} km/h',
                  style: const TextStyle(color: Colors.white38, fontSize: 18)),
            ],
          ],
        ),

        // Hourly forecast row
        if (forecast.isNotEmpty) ...[
          const SizedBox(height: 32),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 40),
            color: Colors.white12,
          ),
          const SizedBox(height: 20),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Row(
              children: [
                for (int i = 0; i < forecast.length; i++) ...[
                  _ForecastTile(period: forecast[i], unit: w.temperatureUnit),
                  if (i < forecast.length - 1)
                    Container(
                      width: 1,
                      height: 48,
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      color: Colors.white12,
                    ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Show every hour up to 12, then every 3 hours beyond that.
  List<ForecastPeriod> _filterForecast(List<ForecastPeriod> forecast) {
    if (forecast.length <= 12) return forecast;
    final filtered = <ForecastPeriod>[];
    for (final f in forecast) {
      try {
        final dt = DateTime.parse(f.datetime).toLocal();
        if (filtered.length < 12 || dt.hour % 3 == 0) {
          filtered.add(f);
        }
      } catch (_) {
        filtered.add(f);
      }
    }
    return filtered;
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('-', ' ');
}

class _ForecastTile extends StatelessWidget {
  final ForecastPeriod period;
  final String unit;
  const _ForecastTile({required this.period, required this.unit});

  @override
  Widget build(BuildContext context) {
    String timeLabel = '';
    try {
      final dt = DateTime.parse(period.datetime).toLocal();
      timeLabel = DateFormat('HH:mm').format(dt);
    } catch (_) {}

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          timeLabel,
          style: TextStyle(
            color: Colors.white.withOpacity(0.45),
            fontSize: 13,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 8),
        WeatherIcon(condition: period.condition, size: 22),
        const SizedBox(height: 8),
        Text(
          period.temperature != null
              ? '${period.temperature!.round()}$unit'
              : '—',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w300,
          ),
        ),
        if (period.precipitationProbability != null &&
            period.precipitationProbability! > 0) ...[
          const SizedBox(height: 4),
          Text(
            '${period.precipitationProbability}%',
            style: const TextStyle(
              color: Color(0xFF64B5F6),
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Ambient mode: photo slideshow
// ---------------------------------------------------------------------------

class _AmbientPhotoSlideshow extends StatefulWidget {
  final List<String> photos;
  const _AmbientPhotoSlideshow({super.key, required this.photos});

  @override
  State<_AmbientPhotoSlideshow> createState() => _AmbientPhotoSlideshowState();
}

class _AmbientPhotoSlideshowState extends State<_AmbientPhotoSlideshow> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(_AmbientPhotoSlideshow old) {
    super.didUpdateWidget(old);
    if (old.photos != widget.photos) {
      _index = 0;
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (widget.photos.isNotEmpty && mounted) {
        setState(() => _index = (_index + 1) % widget.photos.length);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) return const SizedBox.shrink();
    final url = widget.photos[_index];
    return AnimatedSwitcher(
      duration: const Duration(seconds: 2),
      child: Image.network(
        url,
        key: ValueKey(url),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ambient mode: camera grid
// ---------------------------------------------------------------------------

class _AmbientCameraGrid extends StatelessWidget {
  final List<CameraData> cameras;
  final void Function(CameraData)? onCameraTap;
  const _AmbientCameraGrid({super.key, required this.cameras, this.onCameraTap});

  @override
  Widget build(BuildContext context) {
    if (cameras.isEmpty) return const SizedBox.shrink();
    const gap = 8.0;
    const padding = 16.0;

    // Build rows of up to 2 tiles each, all Expanded so they fill the screen
    final rows = <Widget>[];
    for (int i = 0; i < cameras.length; i += 2) {
      final rowChildren = <Widget>[
        Expanded(child: _tile(cameras[i])),
        if (i + 1 < cameras.length) ...[
          const SizedBox(width: gap),
          Expanded(child: _tile(cameras[i + 1])),
        ] else
          const Expanded(child: SizedBox()),
      ];
      if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
      rows.add(Expanded(child: Row(children: rowChildren)));
    }

    return Padding(
      padding: const EdgeInsets.all(padding),
      child: Column(children: rows),
    );
  }

  Widget _tile(CameraData camera) => _CameraTile(
        camera: camera,
        onTap: onCameraTap != null ? () => onCameraTap!(camera) : null,
      );
}

class _CameraTile extends StatelessWidget {
  final CameraData camera;
  final VoidCallback? onTap;
  const _CameraTile({required this.camera, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(camera.imageBytes, fit: BoxFit.cover),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Text(
                  camera.name,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Fallback shown when a mode has no data yet
class _AmbientClockFallback extends StatelessWidget {
  const _AmbientClockFallback();

  @override
  Widget build(BuildContext context) {
    return Center(child: _AmbientClock());
  }
}

// ---------------------------------------------------------------------------
// Full-screen live camera view
// ---------------------------------------------------------------------------

class _CameraFullScreen extends StatefulWidget {
  final CameraData initialCamera;
  final DisplayStateNotifier notifier;
  const _CameraFullScreen({required this.initialCamera, required this.notifier});

  @override
  State<_CameraFullScreen> createState() => _CameraFullScreenState();
}

class _CameraFullScreenState extends State<_CameraFullScreen> {
  late CameraData _current;
  StreamSubscription<CameraData>? _sub;

  @override
  void initState() {
    super.initState();
    _current = widget.initialCamera;
    _sub = widget.notifier.focusedCameraStream.listen((cam) {
      if (mounted) setState(() => _current = cam);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              _current.imageBytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
            // Camera name bottom-left
            Positioned(
              bottom: 24,
              left: 24,
              child: Text(
                _current.name,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
            // Dismiss hint bottom-centre
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Text(
                'Tap anywhere to close',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.3),
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Notification dialog
// ---------------------------------------------------------------------------

class _NotificationDialog extends StatefulWidget {
  final NotificationData notification;
  const _NotificationDialog({required this.notification});

  @override
  State<_NotificationDialog> createState() => _NotificationDialogState();
}

class _NotificationDialogState extends State<_NotificationDialog> {
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _dismissTimer = Timer(
      Duration(seconds: widget.notification.duration),
      () {
        if (mounted) Navigator.of(context).pop();
      },
    );
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(32),
        constraints: const BoxConstraints(maxWidth: 480),
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
            if (n.imageUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  n.imageUrl!,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (n.title.isNotEmpty)
              Text(
                n.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            if (n.title.isNotEmpty && n.message.isNotEmpty)
              const SizedBox(height: 8),
            if (n.message.isNotEmpty)
              Text(
                n.message,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 16,
                  fontWeight: FontWeight.w300,
                ),
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(50),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Text(
                  'Dismiss',
                  style: TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
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
