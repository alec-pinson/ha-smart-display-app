import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../device/device_id_service.dart';
import '../display_state/display_state.dart';
import '../display_state/display_state_notifier.dart';
import '../pairing/pairing_service.dart';

final _log = Logger();
const _port = 8472;
const _platform = MethodChannel('ha_smart_display/mdns');

class DisplayServer {
  final Ref _ref;
  HttpServer? _server;

  final _clients = <WebSocketChannel>{};
  DateTime? _lastStateReceived;

  final _clientCountController = StreamController<int>.broadcast();
  Stream<int> get clientCountStream => _clientCountController.stream;
  int get clientCount => _clients.length;
  DateTime? get lastStateReceived => _lastStateReceived;

  DisplayServer(this._ref);

  Future<void> start() async {
    final handler = webSocketHandler(_onConnection);
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, _port);
    _log.i('DisplayServer: listening on port $_port');

    final deviceId = await _ref.read(deviceIdProvider.future);
    await _advertiseMdns(deviceId);
  }

  void _onConnection(WebSocketChannel ws) {
    _log.d('DisplayServer: new connection');

    // If already paired, register this connection immediately as an active
    // HA client — no pair handshake needed (this is HA's persistent connection)
    if (_ref.read(pairingProvider).isPaired) {
      _clients.add(ws);
      _clientCountController.add(_clients.length);
      _lastStateReceived = DateTime.now();

      // Push current state right away so HA entities go available
      final state = _ref.read(displayStateProvider);
      _send(ws, {'type': 'state', 'state': state.toJson()});
      _log.d('DisplayServer: paired client registered, state pushed');
    }

    ws.stream.listen(
      (raw) => _handleMessage(ws, raw as String),
      onDone: () {
        _clients.remove(ws);
        _clientCountController.add(_clients.length);
        _log.d('DisplayServer: client disconnected');
      },
      onError: (e) {
        _clients.remove(ws);
        _clientCountController.add(_clients.length);
        _log.w('DisplayServer: client error: $e');
      },
    );
  }

  Future<void> _handleMessage(WebSocketChannel ws, String raw) async {
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final type = msg['type'] as String?;

      switch (type) {
        case 'pair':
          await _handlePair(ws, msg);
        case 'command':
          _handleCommand(msg['payload'] as Map<String, dynamic>? ?? {});
        case 'pong':
          _lastStateReceived = DateTime.now();
        default:
          _log.w('DisplayServer: unknown message type: $type');
      }
    } catch (e) {
      _log.w('DisplayServer: failed to parse message: $e');
    }
  }

  Future<void> _handlePair(WebSocketChannel ws, Map<String, dynamic> msg) async {
    final code = msg['code'] as String? ?? '';
    final pairing = _ref.read(pairingProvider.notifier);
    final deviceId = await _ref.read(deviceIdProvider.future);

    if (_ref.read(pairingProvider).isPaired) {
      // Already paired — just confirm and ensure registered
      if (!_clients.contains(ws)) {
        _clients.add(ws);
        _clientCountController.add(_clients.length);
      }
      _send(ws, {'type': 'pair_ok', 'device_id': deviceId});
      final state = _ref.read(displayStateProvider);
      _send(ws, {'type': 'state', 'state': state.toJson()});
      return;
    }

    if (pairing.validateCode(code)) {
      await pairing.markPaired();
      if (!_clients.contains(ws)) {
        _clients.add(ws);
        _clientCountController.add(_clients.length);
      }
      _send(ws, {
        'type': 'pair_ok',
        'device_id': deviceId,
        'device_name': 'HA Smart Display',
      });
      final state = _ref.read(displayStateProvider);
      _send(ws, {'type': 'state', 'state': state.toJson()});
      _lastStateReceived = DateTime.now();
      _log.i('DisplayServer: pairing successful');
    } else {
      _send(ws, {'type': 'pair_error', 'reason': 'invalid_code'});
      _log.w('DisplayServer: invalid pairing code attempt');
    }
  }

  void _handleCommand(Map<String, dynamic> payload) {
    _log.d('DisplayServer: received command');
    _lastStateReceived = DateTime.now();
    _ref.read(displayStateProvider.notifier).applyCommand(payload);
  }

  void broadcastState(DisplayState state, {String? dismissedTimer, String? dismissedAlarm, String? focusedCamera}) {
    if (_clients.isEmpty) return;
    final json = state.toJson();
    if (dismissedTimer != null) json['dismissed_timer'] = dismissedTimer;
    if (dismissedAlarm != null) json['dismissed_alarm'] = dismissedAlarm;
    json['focused_camera'] = focusedCamera; // always sent; null = none
    final msg = jsonEncode({'type': 'state', 'state': json});
    for (final client in List.of(_clients)) {
      try {
        client.sink.add(msg);
      } catch (e) {
        _log.w('DisplayServer: broadcast failed: $e');
      }
    }
  }

  void sendPing() {
    _lastStateReceived ??= DateTime.now();
    final msg = jsonEncode({'type': 'ping'});
    for (final client in List.of(_clients)) {
      try {
        client.sink.add(msg);
      } catch (_) {}
    }
  }

  void sendEvent(Map<String, dynamic> event) {
    if (_clients.isEmpty) return;
    final msg = jsonEncode({'type': 'event', ...event});
    for (final client in List.of(_clients)) {
      try {
        client.sink.add(msg);
      } catch (_) {}
    }
  }

  void _send(WebSocketChannel ws, Map<String, dynamic> msg) {
    ws.sink.add(jsonEncode(msg));
  }

  Future<void> _advertiseMdns(String deviceId) async {
    try {
      await _platform.invokeMethod('advertise', {
        'serviceType': '_ha_smart_display._tcp',
        'serviceName': deviceId,
        'port': _port,
        'txtRecords': {'device_id': deviceId},
      });
      _log.i('DisplayServer: mDNS advertised');
    } catch (e) {
      _log.w('DisplayServer: mDNS advertisement failed: $e');
    }
  }

  Future<void> stop() async {
    await _clientCountController.close();
    await _server?.close(force: true);
    for (final c in _clients) {
      await c.sink.close();
    }
    _clients.clear();
  }
}

final displayServerProvider = Provider<DisplayServer>((ref) {
  final server = DisplayServer(ref);
  ref.onDispose(server.stop);
  return server;
});
