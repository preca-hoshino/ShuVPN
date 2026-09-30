import 'dart:async';

import 'models.dart';
import 'errors.dart';
import 'events.dart';
import '../flutter_sangfor_platform_interface.dart';

/// Product families supported by the flutter_sangfor package family.
enum SangforProduct { atrust, easyConnect }

/// Product-neutral connection input.
class SangforConnectOptions {
  const SangforConnectOptions({
    required this.server,
    required this.username,
    required this.password,
    this.loginDomain,
    this.deviceId,
    this.authType = SangforAuthType.password,
    this.timeout = const Duration(seconds: 30),
    this.cancellationToken,
    this.dryRun = false,
  });

  final Uri server;
  final String username;
  final String password;
  final String? loginDomain;
  final String? deviceId;
  final SangforAuthType authType;
  final Duration timeout;
  final SangforCancellationToken? cancellationToken;
  final bool dryRun;

  void validate() {
    if (server.scheme != 'https' || server.host.isEmpty) {
      throw const SangforException(
        SangforErrorCode.invalidOptions,
        'server must be a valid HTTPS URL',
      );
    }
    if (username.trim().isEmpty) {
      throw const SangforException(
        SangforErrorCode.invalidOptions,
        'username must not be empty',
      );
    }
    if (timeout <= Duration.zero) {
      throw const SangforException(
        SangforErrorCode.invalidOptions,
        'timeout must be greater than zero',
      );
    }
  }
}

/// Common connector contract implemented by each product package.
abstract interface class SangforConnector {
  SangforProduct get product;

  Future<SangforSession> connect(SangforConnectOptions options);

  Future<void> disconnect();

  Future<SangforConnectionState> getState();

  Future<SangforPlatformCapabilities> getCapabilities();
}

/// Adapter for the native connector exposed by the root Flutter plugin.
class SangforPlatformConnector implements SangforConnector {
  SangforPlatformConnector({
    this.product = SangforProduct.atrust,
    FlutterSangforPlatform? platform,
  }) : _platform = platform ?? FlutterSangforPlatform.instance;

  final FlutterSangforPlatform _platform;

  @override
  final SangforProduct product;

  @override
  Future<SangforSession> connect(SangforConnectOptions options) =>
      _platform.connect(
        server: options.server,
        username: options.username,
        password: options.password,
        loginDomain: options.loginDomain,
        authType: options.authType,
      );

  @override
  Future<void> disconnect() => _platform.disconnect();

  @override
  Future<SangforConnectionState> getState() => _platform.getState();

  @override
  Future<SangforPlatformCapabilities> getCapabilities() =>
      _platform.getCapabilities();
}

/// Product-neutral session manager.
class SangforClient {
  SangforClient({required SangforConnector connector}) : _connector = connector;

  final SangforConnector _connector;
  final StreamController<SangforConnectionEvent> _events =
      StreamController<SangforConnectionEvent>.broadcast();

  SangforProduct get product => _connector.product;

  Stream<SangforConnectionEvent> get events => _events.stream;

  Future<SangforSession> connect(SangforConnectOptions options) async {
    options.validate();
    _emit(
      SangforConnectionEventType.stateChanged,
      SangforConnectionState.connecting,
    );
    try {
      final session = await _connector.connect(options);
      _emit(SangforConnectionEventType.stateChanged, session.state);
      return session;
    } on Object catch (error) {
      _emit(
        SangforConnectionEventType.error,
        SangforConnectionState.error,
        message: error.toString(),
      );
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _emit(
      SangforConnectionEventType.stateChanged,
      SangforConnectionState.disconnecting,
    );
    await _connector.disconnect();
    _emit(
      SangforConnectionEventType.stateChanged,
      SangforConnectionState.disconnected,
    );
  }

  Future<SangforConnectionState> getState() => _connector.getState();

  Future<SangforPlatformCapabilities> getCapabilities() =>
      _connector.getCapabilities();

  Future<void> dispose() => _events.close();

  void _emit(
    SangforConnectionEventType type,
    SangforConnectionState state, {
    String? message,
  }) {
    if (_events.isClosed) return;
    _events.add(
      SangforConnectionEvent(
        type: type,
        state: state,
        timestamp: DateTime.now().toUtc(),
        message: message,
      ),
    );
  }
}
