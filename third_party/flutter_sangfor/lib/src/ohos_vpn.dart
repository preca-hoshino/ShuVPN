import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'fd_packet_device.dart';
import 'tunnel_io.dart';

/// HarmonyOS system VPN adapter: starts the host-declared
/// `SangforVpnExtAbility` (a `VpnExtensionAbility`), receives the
/// established TUN descriptor over the SCM_RIGHTS hand-off socket, and
/// surfaces it as a [SangforPacketDevice]. Mirrors [AndroidVpnDevice].
class OhosVpnDevice implements SangforPacketDevice {
  OhosVpnDevice._(this._device);

  static const MethodChannel _channel = MethodChannel('flutter_sangfor');

  final FdPacketDevice _device;

  @override
  Stream<Uint8List> get incoming => _device.incoming;

  @override
  bool get isClosed => _device.isClosed;

  /// Starts the system VPN interface.
  ///
  /// [routes] entries use the `<address>/<prefix>` notation, for example
  /// `10.0.0.0/8`. Returns null when the user did not authorize the VPN
  /// extension or the descriptor hand-off timed out.
  static Future<OhosVpnDevice?> start({
    required String address,
    required int prefixLength,
    List<String> routes = const <String>[],
    List<String> dnsServers = const <String>[],
    List<String> searchDomains = const <String>[],
    int mtu = 0,
    List<String> blockedApplications = const <String>[],
  }) async {
    if (Platform.operatingSystem != 'ohos') {
      throw UnsupportedError('OhosVpnDevice requires HarmonyOS');
    }
    final int? fd;
    try {
      fd = await _channel.invokeMethod<int>('vpnStart', <String, Object?>{
        'address': address,
        'prefixLength': prefixLength,
        'routes': routes,
        'dnsServers': dnsServers,
        'searchDomains': searchDomains,
        'mtu': mtu,
        'blockedApplications': blockedApplications,
      });
    } on PlatformException {
      // Authorization denied, extension failed, or hand-off timed out.
      return null;
    }
    if (fd == null || fd < 0) {
      return null;
    }
    final device = await FdPacketDevice.fromFd(fd);
    return OhosVpnDevice._(device);
  }

  /// Whether the VPN permission has been granted to this app. On HarmonyOS
  /// the system prompts when the extension starts for the first time, so
  /// there is no separate pre-grant step.
  static Future<bool> get isPrepared async {
    if (Platform.operatingSystem != 'ohos') return false;
    final prepared = await _channel.invokeMethod<bool>('vpnPrepare');
    return prepared ?? false;
  }

  /// Requests the system VPN permission. On HarmonyOS this is a no-op that
  /// always succeeds (see [isPrepared]).
  static Future<bool> requestPermission() async {
    if (Platform.operatingSystem != 'ohos') return false;
    return await _channel.invokeMethod<bool>('vpnRequestPermission') ?? false;
  }

  @override
  Future<void> send(Uint8List packet) => _device.send(packet);

  @override
  Future<void> close() async {
    await _device.close();
    await _channel.invokeMethod<void>('vpnStop');
  }
}
