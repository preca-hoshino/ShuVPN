/// Flutter integration for Sangfor remote-access VPNs: common lifecycle,
/// userspace data plane (SOCKS5 frontend, TUN adapters), and the connector
/// contract implemented by the product packages.
library;

import 'flutter_sangfor_platform_interface.dart';
import 'src/models.dart';

export 'src/models.dart';
export 'src/protocol.dart';
export 'src/client.dart';
export 'src/errors.dart';
export 'src/events.dart';
export 'src/tunnel_io.dart';
export 'src/socket_tcp_stream.dart';
export 'src/socks5.dart';
export 'src/wintun.dart';
export 'src/tun_device.dart';
export 'src/fd_packet_device.dart';
export 'src/utun_device.dart';
export 'src/android_vpn.dart';
export 'src/ohos_vpn.dart';
export 'src/ios_vpn.dart';

/// Controls an aTrust-compatible VPN session.
class FlutterSangfor {
  const FlutterSangfor();

  /// Connects to an aTrust-compatible server.
  Future<SangforSession> connect({
    required Uri server,
    required String username,
    required String password,
    String? loginDomain,
    SangforAuthType authType = SangforAuthType.password,
  }) =>
      FlutterSangforPlatform.instance.connect(
        server: server,
        username: username,
        password: password,
        loginDomain: loginDomain,
        authType: authType,
      );

  /// Disconnects the active session.
  Future<void> disconnect() => FlutterSangforPlatform.instance.disconnect();

  /// Returns the current session state.
  Future<SangforConnectionState> getState() =>
      FlutterSangforPlatform.instance.getState();

  /// Returns capabilities reported by the native platform adapter.
  Future<SangforPlatformCapabilities> getCapabilities() =>
      FlutterSangforPlatform.instance.getCapabilities();
}
