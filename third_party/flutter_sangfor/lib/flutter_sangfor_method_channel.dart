import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_sangfor_platform_interface.dart';
import 'src/models.dart';

/// An implementation of [FlutterSangforPlatform] that uses method channels.
class MethodChannelFlutterSangfor extends FlutterSangforPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_sangfor');

  @override
  Future<SangforSession> connect({
    required Uri server,
    required String username,
    required String password,
    String? loginDomain,
    SangforAuthType authType = SangforAuthType.password,
  }) async {
    _validateConnectionArguments(server, username, password, loginDomain);
    final result = await methodChannel.invokeMapMethod<String, Object?>(
      'connect',
      <String, Object?>{
        'server': server.toString(),
        'username': username,
        'password': password,
        'loginDomain': loginDomain,
        'authType': authType.value,
      },
    );
    return SangforSession.fromMap(result ?? const <String, Object?>{});
  }

  @override
  Future<void> disconnect() => methodChannel.invokeMethod<void>('disconnect');

  @override
  Future<SangforConnectionState> getState() async {
    final value = await methodChannel.invokeMethod<String>('getState');
    return SangforConnectionState.fromValue(value);
  }

  @override
  Future<SangforPlatformCapabilities> getCapabilities() async {
    final result = await methodChannel.invokeMapMethod<String, Object?>(
      'getCapabilities',
    );
    return SangforPlatformCapabilities.fromMap(result ?? const {});
  }

  void _validateConnectionArguments(
    Uri server,
    String username,
    String password,
    String? loginDomain,
  ) {
    if ((server.scheme != 'https' && server.scheme != 'http') ||
        server.host.isEmpty) {
      throw ArgumentError.value(
        server,
        'server',
        'must be an HTTP(S) URI with a host',
      );
    }
    if (username.trim().isEmpty) {
      throw ArgumentError.value(username, 'username', 'must not be empty');
    }
    if (password.isEmpty) {
      throw ArgumentError.value(password, 'password', 'must not be empty');
    }
    if (loginDomain != null && loginDomain.trim().isEmpty) {
      throw ArgumentError.value(
        loginDomain,
        'loginDomain',
        'must be null or non-empty',
      );
    }
  }
}
