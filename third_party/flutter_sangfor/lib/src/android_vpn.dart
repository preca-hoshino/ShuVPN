import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'fd_packet_device.dart';
import 'tunnel_io.dart';

/// Android system VPN adapter: starts the `VpnTunnelService` declared by the
/// plugin, receives the established TUN file descriptor, and surfaces it as
/// a [SangforPacketDevice]. The app's own traffic is excluded from the VPN
/// (disallowed application) so tunnel transport cannot loop back.
class AndroidVpnDevice implements SangforPacketDevice {
  AndroidVpnDevice._(this._device);

  static const MethodChannel _channel = MethodChannel('flutter_sangfor');

  final FdPacketDevice _device;

  @override
  Stream<Uint8List> get incoming => _device.incoming;

  @override
  bool get isClosed => _device.isClosed;

  /// Starts the system VPN interface.
  ///
  /// [routes] entries use the `<address>/<prefix>` notation, for example
  /// `10.0.0.0/8`. Returns false when the VPN was not prepared (the user
  /// must grant the VPN permission first; see [isPrepared]).
  ///
  /// [proxyPort] optionally advertises a loopback HTTP proxy as the
  /// VPN's system proxy (Android 13+), so apps that honor the system
  /// proxy send their HTTP(S) traffic through it instead of the TUN.
  ///
  /// [notificationTitle] and [disconnectLabel] localize the persistent
  /// foreground notification and its disconnect action.
  static Future<AndroidVpnDevice?> start({
    required String address,
    required int prefixLength,
    List<String> routes = const <String>[],
    List<String> dnsServers = const <String>[],
    List<String> searchDomains = const <String>[],
    int mtu = 0,
    String proxyHost = '127.0.0.1',
    int proxyPort = 0,
    String notificationTitle = 'VPN',
    String disconnectLabel = 'Disconnect',
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('AndroidVpnDevice requires Android');
    }
    final prepared = await isPrepared;
    if (!prepared) return null;
    final fd = await _channel.invokeMethod<int>('vpnStart', <String, Object?>{
      'address': address,
      'prefixLength': prefixLength,
      'routes': routes,
      'dnsServers': dnsServers,
      'searchDomains': searchDomains,
      'mtu': mtu,
      'proxyHost': proxyHost,
      'proxyPort': proxyPort,
      'notificationTitle': notificationTitle,
      'disconnectLabel': disconnectLabel,
    });
    if (fd == null || fd < 0) {
      throw StateError('VpnService.establish() returned no descriptor');
    }
    final device = await FdPacketDevice.fromFd(fd);
    return AndroidVpnDevice._(device);
  }

  /// Whether the VPN permission has been granted to this app.
  static Future<bool> get isPrepared async {
    if (!Platform.isAndroid) return false;
    final prepared = await _channel.invokeMethod<bool>('vpnPrepare');
    return prepared ?? false;
  }

  /// Pushes cumulative traffic counters (bytes) to the foreground
  /// notification; the native side derives the per-second speed.
  static Future<void> updateStats({
    required int down,
    required int up,
  }) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('vpnStats', <String, Object?>{
      'down': down,
      'up': up,
    });
  }

  static const MethodChannel _eventChannel =
      MethodChannel('flutter_sangfor/service');
  static final StreamController<void> _disconnectRequests =
      StreamController<void>.broadcast();
  static bool _eventHandlerInstalled = false;

  /// Fires when the user taps the notification's disconnect action.
  static Stream<void> get disconnectRequests {
    if (!_eventHandlerInstalled) {
      _eventHandlerInstalled = true;
      _eventChannel.setMethodCallHandler((call) async {
        if (call.method == 'disconnectRequested') {
          _disconnectRequests.add(null);
        }
        return null;
      });
    }
    return _disconnectRequests.stream;
  }

  /// Requests the system VPN permission. Returns true when the permission
  /// flow completed successfully.
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return false;
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
