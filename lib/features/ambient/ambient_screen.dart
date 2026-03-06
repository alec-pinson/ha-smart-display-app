import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/device/device_id_service.dart';
import '../../core/display_state/display_state.dart';
import '../../core/display_state/display_state_notifier.dart';
import '../../core/server/display_server.dart';
import '../../core/timer/timer_service.dart';
import '../../core/voice/voice_assistant_service.dart';
import '../../core/wake_word/wake_word_service.dart';
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
  late AnimationController _glowController;
  StreamSubscription? _alertSub;
  StreamSubscription? _notificationSub;
  StreamSubscription? _openCameraSub;
  StreamSubscription? _voiceStateSub;
  StreamSubscription? _wakeWordDetectionSub;
  VoiceAssistantState _voiceState = VoiceAssistantState.idle;
  // Tracks the currently-showing modal notification so we can dismiss it
  // before showing the next one (prevents scrim stacking).
  Route<void>? _currentNotificationRoute;

  @override
  void initState() {
    super.initState();

    _auroraController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Request microphone permission for wake-word detection.
      // Done here (post-frame) so the Activity is fully ready to show the dialog.
      _requestPermissions();

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

      // Initialise wake word service (starts listening immediately)
      final wakeWordSvc = ref.read(wakeWordServiceProvider);
      final vaService = ref.read(voiceAssistantServiceProvider);

      // Wake word detected → hand off to voice assistant service
      _wakeWordDetectionSub = wakeWordSvc.detectionStream.listen((_) {
        if (mounted) vaService.onWakeWordDetected();
      });

      // Voice assistant state stream — drives animation + resumes wake word on idle
      _voiceStateSub = vaService.stateStream.listen((s) {
        if (!mounted) return;
        setState(() => _voiceState = s);
        if (s == VoiceAssistantState.listening || s == VoiceAssistantState.detected) {
          _glowController.repeat(reverse: true);
        } else if (s == VoiceAssistantState.processing) {
          _glowController.repeat();
        } else {
          _glowController.stop();
          _glowController.reset();
          // Resume wake word detection now that voice recording is done
          wakeWordSvc.resume();
        }
      });

      // Open camera stream (triggered by HA service call)
      _openCameraSub = notifier.openCameraStream.listen((camera) {
        if (mounted) {
          showDialog(
            context: context,
            barrierColor: Colors.black,
            builder: (_) => _CameraFullScreen(initialCamera: camera, notifier: notifier),
          ).then((_) => notifier.setFocusedCamera(null));
        }
      });
    });
  }

  Future<void> _requestPermissions() async {
    // Microphone — needed for wake-word detection ("Hey Jarvis" etc.)
    if (await Permission.microphone.isDenied) {
      await Permission.microphone.request();
    }
  }

  void _showStatusDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => const _StatusDialog(),
    );
  }

  void _showFiringAlert(FiringAlert alert) {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => _AlertDialog(alert: alert),
    );
  }

  Alignment _notificationAlignment(String position) => switch (position) {
    'top_left'      => Alignment.topLeft,
    'top_center'    => Alignment.topCenter,
    'top_right'     => Alignment.topRight,
    'bottom_left'   => Alignment.bottomLeft,
    'bottom_center' => Alignment.bottomCenter,
    'bottom_right'  => Alignment.bottomRight,
    _               => Alignment.center,
  };

  void _showNotification(NotificationData notification) {
    final notifier = ref.read(displayStateProvider.notifier);
    switch (notification.style) {
      case 'toast':
        _showOverlay((onDone) => _ToastOverlay(notification: notification, onDone: onDone));
      case 'banner':
        _showOverlay((onDone) => _BannerOverlay(notification: notification, notifier: notifier, onDone: onDone));
      default:
        // Pop any existing notification dialog before showing the new one
        // so scrims don't stack and darken the screen.
        if (_currentNotificationRoute != null) {
          Navigator.of(context).removeRoute(_currentNotificationRoute!);
          _currentNotificationRoute = null;
        }
        final route = DialogRoute<void>(
          context: context,
          barrierDismissible: true,
          barrierColor: Colors.black38,
          builder: (_) => _NotificationDialog(
            notification: notification,
            notifier: notifier,
            alignment: _notificationAlignment(notification.position),
          ),
        );
        _currentNotificationRoute = route;
        Navigator.of(context).push(route).then((_) {
          if (_currentNotificationRoute == route) {
            _currentNotificationRoute = null;
          }
        });
    }
  }

  void _showOverlay(Widget Function(VoidCallback onDone) builder) {
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (_) => builder(() {
        entry?.remove();
        entry = null;
      }),
    );
    Overlay.of(context).insert(entry!);
  }

  @override
  void dispose() {
    _auroraController.dispose();
    _glowController.dispose();
    _alertSub?.cancel();
    _notificationSub?.cancel();
    _openCameraSub?.cancel();
    _voiceStateSub?.cancel();
    _wakeWordDetectionSub?.cancel();
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
          if (displayState.ambientMode == 'clock' && displayState.photos.isNotEmpty) ...[
            AnimatedOpacity(
              duration: const Duration(milliseconds: 800),
              opacity: isAmbient ? 0.0 : 1.0,
              child: _AmbientPhotoSlideshow(photos: displayState.photos),
            ),
            // Dark scrim so clock/text stays readable over photos
            AnimatedOpacity(
              duration: const Duration(milliseconds: 800),
              opacity: isAmbient ? 0.0 : 1.0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xAA000000), Color(0x66000000)],
                  ),
                ),
              ),
            ),
          ],

          // Main content — crossfade between normal and ambient
          Positioned.fill(
            child: IgnorePointer(
              ignoring: isAmbient,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 800),
                opacity: isAmbient ? 0.0 : 1.0,
                child: _NormalOverlay(state: displayState),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !isAmbient,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 800),
                opacity: isAmbient ? 1.0 : 0.0,
                child: _AmbientOverlay(state: displayState),
              ),
            ),
          ),

          // Connection indicator — top right, hidden in ambient mode
          if (!isAmbient)
            Positioned(
              top: 20,
              right: 24,
              child: GestureDetector(
                onTap: () => _showStatusDialog(),
                child: const ConnectionIndicator(),
              ),
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

          // Voice assistant overlay — glow border + listening animation
          if (_voiceState != VoiceAssistantState.idle)
            IgnorePointer(
              child: _VoiceOverlay(
                state: _voiceState,
                controller: _glowController,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Voice assistant overlay — glow border + animated indicator
// ---------------------------------------------------------------------------

class _VoiceOverlay extends StatelessWidget {
  final VoiceAssistantState state;
  final AnimationController controller;
  const _VoiceOverlay({required this.state, required this.controller});

  @override
  Widget build(BuildContext context) {
    final isListening = state == VoiceAssistantState.listening ||
        state == VoiceAssistantState.detected;
    final glowColor = isListening
        ? const Color(0xFF4FC3F7) // light blue
        : const Color(0xFF81C784); // light green (processing)

    return Stack(
      fit: StackFit.expand,
      children: [
        // Animated glow border
        AnimatedBuilder(
          animation: controller,
          builder: (_, __) {
            final t = isListening
                ? Curves.easeInOut.transform(controller.value)
                : controller.value;
            final spread = 8.0 + t * 24.0;
            final blur = 20.0 + t * 30.0;
            final opacity = 0.5 + t * 0.5;
            return Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: glowColor.withValues(alpha: opacity),
                  width: 3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: glowColor.withValues(alpha: opacity * 0.6),
                    blurRadius: blur,
                    spreadRadius: spread,
                  ),
                ],
              ),
            );
          },
        ),

        // Centre indicator
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: isListening
                ? _ListeningWaveform(controller: controller, color: glowColor)
                : _ProcessingSpinner(color: glowColor),
          ),
        ),
      ],
    );
  }
}

class _ListeningWaveform extends StatelessWidget {
  final AnimationController controller;
  final Color color;
  const _ListeningWaveform({required this.controller, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(5, (i) {
            final phase = (controller.value + i * 0.18) % 1.0;
            final h = 8.0 + Curves.easeInOut.transform(
              (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
            ) * 28.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Container(
                width: 5,
                height: h,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _ProcessingSpinner extends StatelessWidget {
  final Color color;
  const _ProcessingSpinner({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: CircularProgressIndicator(
        color: color,
        strokeWidth: 3,
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

        // Clock + weather + alarms — only in clock mode
        if (isClockMode)
          Positioned(
            top: 36,
            left: 40,
            child: _ClockWeatherPanel(alarms: state.alarms),
          ),

        // Climate chip — bottom-right in clock mode
        if (isClockMode && state.climate != null)
          Positioned(
            bottom: 32,
            right: 32,
            child: GestureDetector(
              onTap: () => showDialog(
                context: context,
                builder: (_) => _ClimateControlDialog(
                  climate: state.climate!,
                  notifier: ref.read(displayStateProvider.notifier),
                ),
              ),
              child: _ClimateChip(climate: state.climate!),
            ),
          ),

        // Active timers — centre screen
        if (state.timers.isNotEmpty)
          Center(
            child: _TimerPanel(timers: state.timers),
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
            const SizedBox(height: 20),
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
            fontSize: 140,
            fontWeight: FontWeight.w200,
            letterSpacing: -2,
            height: 1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          DateFormat('EEEE, d MMMM').format(_now),
          style: TextStyle(
            color: Colors.white.withOpacity(0.4),
            fontSize: 34,
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
        WeatherIcon(condition: weather.condition, size: 34, color: Colors.white38),
        const SizedBox(width: 10),
        Text(
          weather.temperature != null
              ? '${weather.temperature!.round()}${weather.temperatureUnit}'
              : weather.condition,
          style: const TextStyle(color: Colors.white38, fontSize: 34),
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
// Climate chip — bottom-right of clock screen
// ---------------------------------------------------------------------------

class _ClimateChip extends StatelessWidget {
  final ClimateData climate;
  const _ClimateChip({required this.climate});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(50),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            climate.hvacModes.isEmpty ? Icons.thermostat : _hvacIcon(climate.hvacMode),
            size: 18,
            color: Colors.white54,
          ),
          if (climate.currentTemperature != null || climate.humidity != null)
            const SizedBox(width: 8),
          if (climate.currentTemperature != null) ...[
            Text(
              '${climate.currentTemperature!.toStringAsFixed(1)}${climate.unit}',
              style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w300),
            ),
          ],
          if (climate.humidity != null) ...[
            const SizedBox(width: 12),
            Icon(Icons.water_drop_outlined, size: 16, color: Colors.white38),
            const SizedBox(width: 4),
            Text(
              '${climate.humidity}%',
              style: const TextStyle(color: Colors.white54, fontSize: 16, fontWeight: FontWeight.w300),
            ),
          ],
        ],
      ),
    );
  }
}

IconData _hvacIcon(String mode) {
  switch (mode) {
    case 'heat': return Icons.local_fire_department_outlined;
    case 'cool': return Icons.ac_unit;
    case 'heat_cool': return Icons.device_thermostat;
    case 'fan_only': return Icons.air;
    case 'dry': return Icons.water_drop_outlined;
    case 'auto': return Icons.autorenew;
    case 'off': return Icons.power_settings_new;
    default: return Icons.thermostat;
  }
}

String _hvacLabel(String mode) {
  switch (mode) {
    case 'heat': return 'Heat';
    case 'cool': return 'Cool';
    case 'heat_cool': return 'Heat/Cool';
    case 'fan_only': return 'Fan';
    case 'dry': return 'Dry';
    case 'auto': return 'Auto';
    case 'off': return 'Off';
    default: return mode;
  }
}

// ---------------------------------------------------------------------------
// Climate control dialog
// ---------------------------------------------------------------------------

class _ClimateControlDialog extends StatefulWidget {
  final ClimateData climate;
  final DisplayStateNotifier notifier;
  const _ClimateControlDialog({required this.climate, required this.notifier});

  @override
  State<_ClimateControlDialog> createState() => _ClimateControlDialogState();
}

class _ClimateControlDialogState extends State<_ClimateControlDialog> {
  late double _targetTemp;
  late String _hvacMode;
  Timer? _debounce;

  double get _step => widget.climate.unit == '°F' ? 1.0 : 0.5;

  @override
  void initState() {
    super.initState();
    _targetTemp = widget.climate.targetTemperature ?? 20.0;
    _hvacMode = widget.climate.hvacMode;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _adjustTemp(double delta) {
    setState(() {
      _targetTemp = (_targetTemp + delta)
          .clamp(widget.climate.minTemp, widget.climate.maxTemp);
      // Round to nearest step
      _targetTemp = (_targetTemp / _step).round() * _step;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      widget.notifier.setClimateTemperature(_targetTemp);
    });
  }

  void _setHvacMode(String mode) {
    setState(() => _hvacMode = mode);
    widget.notifier.setClimateHvacMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    final climate = widget.climate;
    return Dialog(
      backgroundColor: const Color(0xFF111827),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  climate.hvacModes.isEmpty ? Icons.thermostat : _hvacIcon(_hvacMode),
                  color: Colors.white54,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    climate.name,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 18,
                      fontWeight: FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white38, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Current temp + humidity
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (climate.currentTemperature != null)
                  Column(
                    children: [
                      Text(
                        '${climate.currentTemperature!.toStringAsFixed(1)}${climate.unit}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 52,
                          fontWeight: FontWeight.w200,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Current',
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    ],
                  ),
                if (climate.currentTemperature != null && climate.humidity != null)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 28),
                    width: 1,
                    height: 48,
                    color: Colors.white12,
                  ),
                if (climate.humidity != null)
                  Column(
                    children: [
                      Text(
                        '${climate.humidity}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 52,
                          fontWeight: FontWeight.w200,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Humidity',
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    ],
                  ),
              ],
            ),
            // Target temperature + HVAC controls — only if controllable
            if (climate.hvacModes.isNotEmpty) ...[
              const SizedBox(height: 32),
              Text(
                'Target Temperature',
                style: TextStyle(color: Colors.white38, fontSize: 13, letterSpacing: 0.5),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _TempButton(
                    icon: Icons.remove,
                    onPressed: _hvacMode == 'off' ? null : () => _adjustTemp(-_step),
                  ),
                  const SizedBox(width: 20),
                  Text(
                    '${_targetTemp.round() == _targetTemp ? _targetTemp.round() : _targetTemp.toStringAsFixed(1)}${climate.unit}',
                    style: TextStyle(
                      color: _hvacMode == 'off' ? Colors.white24 : Colors.white,
                      fontSize: 42,
                      fontWeight: FontWeight.w200,
                    ),
                  ),
                  const SizedBox(width: 20),
                  _TempButton(
                    icon: Icons.add,
                    onPressed: _hvacMode == 'off' ? null : () => _adjustTemp(_step),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: climate.hvacModes.map((mode) {
                  final selected = _hvacMode == mode;
                  return GestureDetector(
                    onTap: () => _setHvacMode(mode),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? Colors.white.withOpacity(0.15) : Colors.transparent,
                        borderRadius: BorderRadius.circular(50),
                        border: Border.all(
                          color: selected ? Colors.white38 : Colors.white12,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _hvacIcon(mode),
                            size: 16,
                            color: selected ? Colors.white70 : Colors.white30,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _hvacLabel(mode),
                            style: TextStyle(
                              color: selected ? Colors.white70 : Colors.white30,
                              fontSize: 14,
                              fontWeight: selected ? FontWeight.w400 : FontWeight.w300,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TempButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  const _TempButton({required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onPressed != null ? Colors.white.withOpacity(0.1) : Colors.transparent,
          border: Border.all(color: onPressed != null ? Colors.white24 : Colors.white12),
        ),
        child: Icon(icon, color: onPressed != null ? Colors.white60 : Colors.white24, size: 22),
      ),
    );
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
            if (_current.imageBytes.isNotEmpty)
              Image.memory(
                _current.imageBytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 1.5),
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
            // Close button top-right
            Positioned(
              top: 20,
              right: 20,
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
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
// Toast notification — small pill at bottom, fades in/out
// ---------------------------------------------------------------------------

class _ToastOverlay extends StatefulWidget {
  final NotificationData notification;
  final VoidCallback onDone;
  const _ToastOverlay({required this.notification, required this.onDone});

  @override
  State<_ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<_ToastOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
    Future.delayed(Duration(seconds: widget.notification.duration), () {
      if (mounted) _controller.reverse().then((_) => widget.onDone());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    return Positioned(
      bottom: 48,
      left: 0,
      right: 0,
      child: FadeTransition(
        opacity: _opacity,
        child: GestureDetector(
          onTap: () => _controller.reverse().then((_) => widget.onDone()),
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                constraints: const BoxConstraints(maxWidth: 560),
                decoration: BoxDecoration(
                  color: const Color(0xEE1E2530),
                  borderRadius: BorderRadius.circular(50),
                  border: Border.all(color: Colors.white12),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24)],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (n.title.isNotEmpty) ...[
                      Text(
                        n.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (n.message.isNotEmpty)
                        const Text(
                          '  ·  ',
                          style: TextStyle(color: Colors.white38, fontSize: 16),
                        ),
                    ],
                    if (n.message.isNotEmpty)
                      Flexible(
                        child: Text(
                          n.message,
                          style: const TextStyle(color: Colors.white70, fontSize: 16),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Banner notification — slides in from top
// ---------------------------------------------------------------------------

class _BannerOverlay extends StatefulWidget {
  final NotificationData notification;
  final DisplayStateNotifier notifier;
  final VoidCallback onDone;
  const _BannerOverlay({
    required this.notification,
    required this.notifier,
    required this.onDone,
  });

  @override
  State<_BannerOverlay> createState() => _BannerOverlayState();
}

class _BannerOverlayState extends State<_BannerOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    Future.delayed(Duration(seconds: widget.notification.duration), _dismiss);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (mounted) _controller.reverse().then((_) => widget.onDone());
  }

  void _onButton(String label, int index) {
    widget.notifier.sendNotificationAction(label, index);
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slide,
        child: GestureDetector(
          onTap: n.buttons.isEmpty ? _dismiss : null,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.fromLTRB(40, 20, 40, 20),
              decoration: const BoxDecoration(
                color: Color(0xEE161B22),
                border: Border(bottom: BorderSide(color: Colors.white12)),
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 24)],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (n.title.isNotEmpty)
                          Text(
                            n.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        if (n.title.isNotEmpty && n.message.isNotEmpty)
                          const SizedBox(height: 2),
                        if (n.message.isNotEmpty)
                          Text(
                            n.message,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.65),
                              fontSize: 15,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (n.buttons.isNotEmpty) ...[
                    const SizedBox(width: 24),
                    Wrap(
                      spacing: 10,
                      children: [
                        for (int i = 0; i < n.buttons.length; i++)
                          GestureDetector(
                            onTap: () => _onButton(n.buttons[i], i),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(50),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Text(
                                n.buttons[i],
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
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
  final DisplayStateNotifier notifier;
  final Alignment alignment;
  const _NotificationDialog({required this.notification, required this.notifier, this.alignment = Alignment.center});

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

  void _dismiss() => Navigator.of(context).pop();

  void _onTap() {
    final tapAction = widget.notification.tapAction;
    if (tapAction != null && tapAction.isNotEmpty) {
      widget.notifier.sendNotificationAction(tapAction, -1);
    }
    _dismiss();
  }

  void _onButton(String label, int index) {
    widget.notifier.sendNotificationAction(label, index);
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    final hasButtons = n.buttons.isNotEmpty;
    final hasTapAction = n.tapAction != null && n.tapAction!.isNotEmpty;

    return Dialog(
      backgroundColor: Colors.transparent,
      alignment: widget.alignment,
      child: Dismissible(
        key: const ValueKey('notification'),
        direction: DismissDirection.horizontal,
        onDismissed: (_) => _dismiss(),
        child: GestureDetector(
          onTap: hasTapAction ? _onTap : null,
          child: Container(
          padding: EdgeInsets.all(n.imageUrl != null ? 0 : 32),
          constraints: BoxConstraints(maxWidth: n.imageUrl != null ? 680 : 480),
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: hasTapAction ? Colors.white38 : Colors.white24,
            ),
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
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  child: Image.network(
                    n.imageUrl!,
                    height: 300,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(height: 24),
              ],
              Padding(
                padding: n.imageUrl != null
                    ? const EdgeInsets.fromLTRB(32, 0, 32, 32)
                    : EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    if (hasButtons) ...[
                      const SizedBox(height: 24),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.center,
                        children: [
                          for (int i = 0; i < n.buttons.length; i++)
                            GestureDetector(
                              onTap: () => _onButton(n.buttons[i], i),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white12,
                                  borderRadius: BorderRadius.circular(50),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Text(
                                  n.buttons[i],
                                  style: const TextStyle(color: Colors.white, fontSize: 15),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Clock + weather panel (normal mode, top-left)
// ---------------------------------------------------------------------------

class _ClockWeatherPanel extends StatefulWidget {
  final List<AlarmData> alarms;
  const _ClockWeatherPanel({this.alarms = const []});

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
        final alarms = widget.alarms;
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

            // Alarms — inline below date, no card
            if (alarms.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...alarms.map((a) => _InlineAlarm(alarm: a)),
            ],
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

  const _TimerPanel({required this.timers});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: timers.map((t) => _TimerCard(timer: t)).toList(),
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
          color: Colors.white.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isUrgent
                ? const Color(0xFFFF6B6B).withOpacity(0.8)
                : Colors.white.withOpacity(0.2),
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
                fontSize: 20,
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
                fontSize: 120,
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
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineAlarm extends ConsumerWidget {
  final AlarmData alarm;
  const _InlineAlarm({required this.alarm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => ref.read(displayStateProvider.notifier).dismissAlarm(alarm.id),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.alarm_rounded, color: Colors.white.withOpacity(0.45), size: 18),
            const SizedBox(width: 8),
            Text(
              alarm.time,
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 20,
                fontWeight: FontWeight.w300,
              ),
            ),
            if (alarm.label.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                alarm.label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 16,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ],
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

// ---------------------------------------------------------------------------
// Status dialog — tapping the connection dot opens this
// ---------------------------------------------------------------------------

class _StatusDialog extends ConsumerStatefulWidget {
  const _StatusDialog();

  @override
  ConsumerState<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends ConsumerState<_StatusDialog> {
  String? _ipAddress;
  String? _deviceId;

  @override
  void initState() {
    super.initState();
    _loadAsync();
  }

  Future<void> _loadAsync() async {
    final ip = await _getLocalIp();
    final id = await ref.read(deviceIdProvider.future);
    if (mounted) setState(() { _ipAddress = ip; _deviceId = id; });
  }

  Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      // Prefer wlan/en (WiFi) interfaces
      for (final iface in interfaces) {
        if (iface.name.startsWith('wlan') || iface.name.startsWith('en')) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback) return addr.address;
          }
        }
      }
      // Fallback: any non-loopback IPv4
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return 'Unknown';
  }

  String _formatUptime(int seconds) {
    final d = seconds ~/ 86400;
    final h = (seconds % 86400) ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (d > 0) return '${d}d ${h}h ${m}m';
    if (h > 0) return '${h}h ${m}m ${s}s';
    return '${m}m ${s}s';
  }

  String _formatLastSeen(DateTime? lastSeen) {
    if (lastSeen == null) return 'Never';
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inSeconds < 5) return 'Just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(displayStateProvider);
    final server = ref.read(displayServerProvider);
    final clientCount = server.clientCount;
    final lastSeen = server.lastStateReceived;

    final connState = clientCount == 0
        ? _ConnStatus.disconnected
        : (lastSeen == null || DateTime.now().difference(lastSeen).inSeconds > 90)
            ? _ConnStatus.stale
            : _ConnStatus.connected;

    return Dialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 400,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  const Icon(Icons.monitor_heart_outlined, color: Color(0xFF58A6FF), size: 20),
                  const SizedBox(width: 10),
                  const Text(
                    'Device Status',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: const Icon(Icons.close, color: Color(0xFF8B949E), size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const _SectionLabel('Home Assistant'),
              _StatusRow(
                icon: Icons.circle,
                iconColor: switch (connState) {
                  _ConnStatus.connected => const Color(0xFF3FB950),
                  _ConnStatus.stale => const Color(0xFFD29922),
                  _ConnStatus.disconnected => const Color(0xFF484F58),
                },
                label: 'Connection',
                value: switch (connState) {
                  _ConnStatus.connected => 'Connected',
                  _ConnStatus.stale => 'Degraded',
                  _ConnStatus.disconnected => 'Disconnected',
                },
              ),
              _StatusRow(
                icon: Icons.access_time,
                label: 'Last message',
                value: _formatLastSeen(lastSeen),
              ),
              _StatusRow(
                icon: Icons.devices,
                label: 'HA clients',
                value: '$clientCount',
              ),
              const SizedBox(height: 16),
              const _SectionLabel('Network'),
              _StatusRow(
                icon: Icons.wifi,
                label: 'IP address',
                value: _ipAddress ?? '…',
              ),
              _StatusRow(
                icon: Icons.lan_outlined,
                label: 'WS port',
                value: '8472',
              ),
              const SizedBox(height: 16),
              const _SectionLabel('Device'),
              _StatusRow(
                icon: Icons.fingerprint,
                label: 'Device ID',
                value: _deviceId ?? '…',
              ),
              _StatusRow(
                icon: Icons.timer_outlined,
                label: 'Uptime',
                value: _formatUptime(state.uptimeSeconds),
              ),
              _StatusRow(
                icon: Icons.mic_outlined,
                label: 'Wake words detected',
                value: '${state.wakeWordCount}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ConnStatus { connected, stale, disconnected }

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: Color(0xFF8B949E),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final String value;

  const _StatusRow({
    required this.icon,
    this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, color: iconColor ?? const Color(0xFF8B949E), size: 14),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: Color(0xFF8B949E), fontSize: 13)),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
