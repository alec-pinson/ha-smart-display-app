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
import '../ota/ota_update_service.dart';
import '../pairing/instance_profile.dart';
import '../pairing/pairing_service.dart';

final _log = Logger();
const _port = 8472;
const _platform = MethodChannel('ha_smart_display/mdns');

class DisplayServer {
  final Ref _ref;
  HttpServer? _server;

  final _clients = <WebSocketChannel>{};
  // instanceId -> its current socket (served or parked)
  final _socketsByInstance = <String, WebSocketChannel>{};
  // socket -> the instanceId it identified as
  final _instanceOf = <WebSocketChannel, String>{};
  DateTime? _lastStateReceived;

  final _clientCountController = StreamController<int>.broadcast();
  Stream<int> get clientCountStream => _clientCountController.stream;
  int get clientCount => _clients.length;
  DateTime? get lastStateReceived => _lastStateReceived;

  DisplayServer(this._ref);

  Future<void> start() async {
    final handler = webSocketHandler(_onConnection);
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, _port);
        break;
      } on SocketException {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    _log.i('DisplayServer: listening on port $_port');

    final deviceId = await _ref.read(deviceIdProvider.future);
    await _advertiseMdns(deviceId);
  }

  void _onConnection(WebSocketChannel ws) {
    _log.d('DisplayServer: new connection (awaiting hello/pair)');

    ws.stream.listen(
      (raw) => _handleMessage(ws, raw as String),
      onDone: () => _onSocketClosed(ws),
      onError: (e) {
        _log.w('DisplayServer: client error: $e');
        _onSocketClosed(ws);
      },
    );
  }

  void _onSocketClosed(WebSocketChannel ws) {
    final id = _instanceOf.remove(ws);
    if (id != null && _socketsByInstance[id] == ws) {
      _socketsByInstance.remove(id);
    }
    if (_clients.remove(ws)) {
      if (!_clientCountController.isClosed) {
        _clientCountController.add(_clients.length);
      }
    }
    _log.d('DisplayServer: client disconnected (instance: $id)');
  }

  Future<void> _handleMessage(WebSocketChannel ws, String raw) async {
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final type = msg['type'] as String?;

      switch (type) {
        case 'hello':
          await _handleHello(ws, msg);
        case 'pair':
          await _handlePair(ws, msg);
        case 'command':
          // Ignore commands from parked (non-active) instances.
          if (_clients.contains(ws)) {
            _handleCommand(msg['payload'] as Map<String, dynamic>? ?? {});
          }
        case 'pong':
          if (_clients.contains(ws)) _lastStateReceived = DateTime.now();
        default:
          _log.w('DisplayServer: unknown message type: $type');
      }
    } catch (e) {
      _log.w('DisplayServer: failed to parse message: $e');
    }
  }

  Future<void> _handleHello(WebSocketChannel ws, Map<String, dynamic> msg) async {
    final instanceId = msg['instance_id'] as String?;
    if (instanceId == null) {
      _log.w('DisplayServer: hello missing instance_id');
      return;
    }
    final label = msg['name'] as String? ?? instanceId;
    final host = msg['host'] as String?;
    final notifier = _ref.read(pairingProvider.notifier);
    final role = _ref.read(pairingProvider).store.roleFor(instanceId);
    _log.d('DisplayServer: hello from $instanceId ($label) role=$role');

    // Register the socket synchronously BEFORE any await, so it is in
    // `_clients` before the event loop can deliver the next message. The
    // integration sends its on-connect command burst (weather, immich_config,
    // etc.) immediately after hello; if we awaited the profile persist first,
    // those commands would arrive while the socket is still unserved and be
    // dropped by the `_clients.contains(ws)` guard in _handleMessage.
    switch (role) {
      case ConnectionRole.reject:
        _send(ws, {'type': 'hello_error', 'reason': 'not_paired'});
      case ConnectionRole.adopt:
        // Legacy migration: first instance after upgrade becomes the profile.
        _serve(ws, instanceId);
        await notifier.upsertInstance(InstanceProfile(
          instanceId: instanceId,
          label: label,
          host: host,
          lastSeen: DateTime.now(),
        ));
      case ConnectionRole.serve:
        _serve(ws, instanceId);
        await notifier.touchInstance(instanceId, label, host);
      case ConnectionRole.park:
        _park(ws, instanceId);
        await notifier.touchInstance(instanceId, label, host);
    }
  }

  Future<void> _handlePair(WebSocketChannel ws, Map<String, dynamic> msg) async {
    final code = msg['code'] as String? ?? '';
    final instanceId = msg['instance_id'] as String?;
    final label = msg['name'] as String? ?? instanceId ?? 'Home Assistant';
    final host = msg['host'] as String?;
    final pairing = _ref.read(pairingProvider.notifier);
    final deviceId = await _ref.read(deviceIdProvider.future);

    if (instanceId == null) {
      _send(ws, {'type': 'pair_error', 'reason': 'missing_instance_id'});
      return;
    }

    // Already-known instance re-pairing: accept and (re)activate it.
    final known = _ref.read(pairingProvider).store.hasProfile(instanceId);
    if (known || pairing.validateCode(code)) {
      await pairing.pairInstance(InstanceProfile(
        instanceId: instanceId,
        label: label,
        host: host,
        lastSeen: DateTime.now(),
      ));
      _send(ws, {
        'type': 'pair_ok',
        'device_id': deviceId,
        'device_name': 'HA Smart Display',
      });
      _applyActive(instanceId, ws);
      _log.i('DisplayServer: pairing successful for $instanceId');
    } else {
      _send(ws, {'type': 'pair_error', 'reason': 'invalid_code'});
      _log.w('DisplayServer: invalid pairing code attempt');
    }
  }

  void _handleCommand(Map<String, dynamic> payload) {
    _log.d('DisplayServer: received command');
    _lastStateReceived = DateTime.now();
    if (payload['action'] == 'ota_update') {
      final url = payload['url'] as String?;
      if (url != null) {
        _ref.read(otaUpdateServiceProvider).handleUpdate(url);
      } else {
        _log.w('DisplayServer: ota_update command missing url');
      }
      return;
    }
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
        _removeClient(client);
      }
    }
  }

  void sendPing() {
    _lastStateReceived ??= DateTime.now();
    final msg = jsonEncode({'type': 'ping'});
    for (final client in List.of(_clients)) {
      try {
        client.sink.add(msg);
      } catch (e) {
        _log.d('DisplayServer: ping send failed: $e');
        _removeClient(client);
      }
    }
  }

  void sendEvent(Map<String, dynamic> event) {
    if (_clients.isEmpty) return;
    final msg = jsonEncode({'type': 'event', ...event});
    for (final client in List.of(_clients)) {
      try {
        client.sink.add(msg);
      } catch (e) {
        _log.d('DisplayServer: event send failed: $e');
        _removeClient(client);
      }
    }
  }

  void _dropSocket(WebSocketChannel ws) {
    _instanceOf.remove(ws);
    if (_clients.remove(ws)) {
      if (!_clientCountController.isClosed) {
        _clientCountController.add(_clients.length);
      }
    }
    try {
      ws.sink.close();
    } catch (_) {}
  }

  void _serve(WebSocketChannel ws, String instanceId) {
    final existing = _socketsByInstance[instanceId];
    if (existing != null && existing != ws) {
      _dropSocket(existing);
    }
    _instanceOf[ws] = instanceId;
    _socketsByInstance[instanceId] = ws;
    _clients.add(ws);
    _clientCountController.add(_clients.length);
    _lastStateReceived = DateTime.now();
    final state = _ref.read(displayStateProvider);
    _send(ws, {'type': 'state', 'state': state.toJson()});
    _log.d('DisplayServer: serving instance $instanceId');
  }

  void _park(WebSocketChannel ws, String instanceId) {
    final existing = _socketsByInstance[instanceId];
    if (existing != null && existing != ws) {
      _dropSocket(existing);
    }
    _instanceOf[ws] = instanceId;
    _socketsByInstance[instanceId] = ws;
    // Not added to _clients: receives no state, its commands are ignored.
    if (_clients.remove(ws)) {
      _clientCountController.add(_clients.length);
    }
    _log.d('DisplayServer: parked instance $instanceId');
  }

  /// Promote [instanceId]'s socket to the served client and demote any others.
  void _applyActive(String instanceId, WebSocketChannel? preferred) {
    // Demote every served socket that isn't the new active instance.
    for (final ws in List.of(_clients)) {
      if (_instanceOf[ws] != instanceId) _clients.remove(ws);
    }
    final ws = preferred ?? _socketsByInstance[instanceId];
    if (ws != null) {
      _clients.add(ws);
      final state = _ref.read(displayStateProvider);
      _send(ws, {'type': 'state', 'state': state.toJson()});
      _lastStateReceived = DateTime.now();
    }
    _clientCountController.add(_clients.length);
    _log.i('DisplayServer: active instance applied -> $instanceId');
  }

  /// Switch the active instance from the UI. Persists the choice and, if that
  /// instance is currently connected, promotes it immediately.
  Future<void> setActiveInstance(String instanceId) async {
    if (!_ref.read(pairingProvider).store.hasProfile(instanceId)) return;
    await _ref.read(pairingProvider.notifier).setActive(instanceId);
    _applyActive(instanceId, null);
  }

  /// Forget an instance entirely (removes its profile + drops its socket).
  Future<void> forgetInstance(String instanceId) async {
    await _ref.read(pairingProvider.notifier).removeProfile(instanceId);
    final ws = _socketsByInstance.remove(instanceId);
    if (ws != null) _dropSocket(ws);
  }

  /// Instance ids that currently have an open socket (served or parked).
  Set<String> get connectedInstances => _socketsByInstance.keys.toSet();

  void _removeClient(WebSocketChannel client) {
    if (_clients.remove(client)) {
      if (!_clientCountController.isClosed) _clientCountController.add(_clients.length);
      try { client.sink.close(); } catch (_) {}
      _log.d('DisplayServer: removed dead client');
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
    for (final c in {..._clients, ..._socketsByInstance.values}) {
      await c.sink.close();
    }
    _clients.clear();
    _socketsByInstance.clear();
    _instanceOf.clear();
  }
}

final displayServerProvider = Provider<DisplayServer>((ref) {
  final server = DisplayServer(ref);
  ref.onDispose(server.stop);
  return server;
});
