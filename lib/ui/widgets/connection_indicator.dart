import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/server/display_server.dart';

enum ConnectionState { connected, stale, disconnected }

class ConnectionIndicator extends ConsumerStatefulWidget {
  const ConnectionIndicator({super.key});

  @override
  ConsumerState<ConnectionIndicator> createState() => _ConnectionIndicatorState();
}

class _ConnectionIndicatorState extends ConsumerState<ConnectionIndicator>
    with SingleTickerProviderStateMixin {
  ConnectionState _state = ConnectionState.disconnected;
  StreamSubscription? _sub;
  Timer? _pollTimer;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    final server = ref.read(displayServerProvider);
    _updateState(server.clientCount, server.lastStateReceived);

    _sub = server.clientCountStream.listen((_) {
      if (mounted) {
        _updateState(server.clientCount, server.lastStateReceived);
      }
    });

    // Poll for stale detection every 15s
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        _updateState(
          ref.read(displayServerProvider).clientCount,
          ref.read(displayServerProvider).lastStateReceived,
        );
      }
    });
  }

  void _updateState(int clientCount, DateTime? lastSeen) {
    ConnectionState next;
    if (clientCount == 0) {
      next = ConnectionState.disconnected;
    } else if (lastSeen == null ||
        DateTime.now().difference(lastSeen).inSeconds > 90) {
      next = ConnectionState.stale;
    } else {
      next = ConnectionState.connected;
    }
    if (next != _state) setState(() => _state = next);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pollTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (color, tooltip) = switch (_state) {
      ConnectionState.connected => (const Color(0xFF3FB950), 'Home Assistant connected'),
      ConnectionState.stale => (const Color(0xFFD29922), 'Connection degraded'),
      ConnectionState.disconnected => (const Color(0xFF484F58), 'Home Assistant disconnected'),
    };

    return Tooltip(
      message: tooltip,
      child: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, __) => Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withOpacity(
              _state == ConnectionState.stale ? _pulseAnim.value : 1.0,
            ),
            shape: BoxShape.circle,
            boxShadow: _state == ConnectionState.connected
                ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6, spreadRadius: 1)]
                : null,
          ),
        ),
      ),
    );
  }
}
