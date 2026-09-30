import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_sangfor_method_channel.dart';
import 'src/models.dart';

abstract class FlutterSangforPlatform extends PlatformInterface {
  /// Constructs a FlutterSangforPlatform.
  FlutterSangforPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterSangforPlatform _instance = MethodChannelFlutterSangfor();

  /// The default instance of [FlutterSangforPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterSangfor].
  static FlutterSangforPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterSangforPlatform] when
  /// they register themselves.
  static set instance(FlutterSangforPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<SangforSession> connect({
    required Uri server,
    required String username,
    required String password,
    String? loginDomain,
    SangforAuthType authType = SangforAuthType.password,
  }) =>
      throw UnimplementedError('connect() has not been implemented.');

  Future<void> disconnect() =>
      throw UnimplementedError('disconnect() has not been implemented.');

  Future<SangforConnectionState> getState() =>
      throw UnimplementedError('getState() has not been implemented.');

  Future<SangforPlatformCapabilities> getCapabilities() =>
      throw UnimplementedError('getCapabilities() has not been implemented.');
}
