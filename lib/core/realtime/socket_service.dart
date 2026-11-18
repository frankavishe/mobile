import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../api/api_client.dart';
import '../api/models/models.dart';
import '../auth/session.dart';
import '../config.dart';

/// Socket.IO connection to the `/rt` namespace (`api/contracts/ws-events.schema.json`).
///
/// The server sends `auth:expired` and disconnects when the access token expires, and rejects
/// the handshake with `connect_error` (`data.code` UNAUTHORIZED | SESSION_REVOKED). Socket.IO
/// does not reconnect by itself after either, so this refreshes the token and reconnects.
class SocketService {
  SocketService({
    required this._accessToken,
    required this._deviceId,
    required this._refresh,
    String? url,
  }) : _url = url ?? AppConfig.realtimeUrl;

  final String? Function() _accessToken;
  final String? Function() _deviceId;
  final Future<String?> Function() _refresh;
  final String _url;

  io.Socket? _socket;
  bool _closed = false;

  final _deviceRevoked = StreamController<DeviceRevokedEvent>.broadcast();
  final _profileUpdated = StreamController<ProfileUpdatedEvent>.broadcast();

  /// This device was signed out: wipe local data and go to sign-in.
  Stream<DeviceRevokedEvent> get deviceRevoked => _deviceRevoked.stream;

  /// The user's own profile, or a contact's, changed.
  Stream<ProfileUpdatedEvent> get profileUpdated => _profileUpdated.stream;

  bool get isConnected => _socket?.connected ?? false;

  void connect() {
    if (_socket != null) return;
    _closed = false;
    final socket = io.io(
      _url,
      io.OptionBuilder()
          .setTransports(['websocket'])
          // Evaluated on every (re)connect, so a refreshed token is picked up.
          .setAuthFn((cb) => cb({'token': _accessToken()}))
          .enableForceNew()
          .disableAutoConnect()
          .build(),
    );
    _socket = socket;

    socket.on('device:revoked', (data) {
      _deviceRevoked.add(DeviceRevokedEvent.fromJson(_map(data)));
    });
    socket.on('profile:updated', (data) {
      _profileUpdated.add(ProfileUpdatedEvent.fromJson(_map(data)));
    });
    socket.on('auth:expired', (_) => _refreshAndReconnect());
    socket.on('connect_error', (data) {
      if (_closed) return;
      final code = data is Map ? data['code'] : null;
      if (code == 'SESSION_REVOKED') {
        _deviceRevoked.add(DeviceRevokedEvent(
          deviceId: _deviceId() ?? '',
          reason: DeviceRevokedReason.signedOut,
        ));
      } else if (code == 'UNAUTHORIZED') {
        _refreshAndReconnect();
      }
      // Other errors (network) are retried by Socket.IO's own reconnection.
    });

    socket.connect();
  }

  Future<void> _refreshAndReconnect() async {
    String? token;
    try {
      token = await _refresh();
    } catch (_) {
      token = null; // Offline: Socket.IO keeps retrying on its own.
    }
    if (_closed || token == null) return;
    _socket?.connect();
  }

  /// Closes the connection. [connect] may be called again afterwards.
  void disconnect() {
    _closed = true;
    _socket
      ?..clearListeners()
      ..dispose();
    _socket = null;
  }

  void dispose() {
    disconnect();
    _deviceRevoked.close();
    _profileUpdated.close();
  }

  static Map<String, dynamic> _map(dynamic data) =>
      Map<String, dynamic>.from(data as Map);
}

/// Connected while signed in by `sessionLifecycleProvider` (features/auth/auth_controller.dart).
final socketServiceProvider = Provider<SocketService>((ref) {
  final service = SocketService(
    accessToken: () => ref.read(sessionProvider).accessToken,
    deviceId: () => ref.read(sessionProvider).deviceId,
    refresh: () => ref.read(apiClientProvider).refresh(),
  );
  ref.onDispose(service.dispose);
  return service;
});
