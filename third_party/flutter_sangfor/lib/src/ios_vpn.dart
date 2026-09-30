import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'tunnel_io.dart';

/// Mirrors `NEVPNStatus` on the native side.
enum IosVpnStatus {
  invalid,
  disconnected,
  connecting,
  connected,
  reasserting,
  disconnecting;

  static IosVpnStatus fromValue(String value) =>
      IosVpnStatus.values.where((status) => status.name == value).firstOrNull ??
      IosVpnStatus.invalid;
}

/// Incremental decoder for the 4-byte big-endian length-framed IPC stream
/// shared with the packet tunnel extension. Accepts arbitrary TCP chunk
/// boundaries; malformed frames (zero or oversized length) are skipped.
class IpcFrameDecoder {
  final BytesBuilder _buffer = BytesBuilder(copy: true);

  /// Appends a received chunk.
  void add(List<int> chunk) => _buffer.add(chunk);

  /// Decodes every complete frame currently buffered.
  List<Uint8List> drain() {
    final frames = <Uint8List>[];
    final bytes = _buffer.toBytes();
    var offset = 0;
    while (offset + 4 <= bytes.length) {
      final length = ByteData.sublistView(bytes, offset, offset + 4)
          .getUint32(0, Endian.big);
      if (length == 0 || length > IosVpnDevice.maxFrameLength) {
        // Malformed frame: skip the header and resynchronize.
        offset += 4;
        continue;
      }
      if (offset + 4 + length > bytes.length) break;
      frames.add(
          Uint8List.fromList(bytes.sublist(offset + 4, offset + 4 + length)));
      offset += 4 + length;
    }
    _buffer.clear();
    if (offset < bytes.length) {
      _buffer.add(bytes.sublist(offset));
    }
    return frames;
  }
}

/// A [SangforPacketDevice] backed by a local TCP connection to the
/// Network Extension process. The NEPacketTunnelProvider writes packets
/// from `packetFlow` into the socket, and reads packets from the socket
/// to inject into `packetFlow`.
///
/// EXPERIMENTAL / FOREGROUND BRIDGE: the loopback design requires the
/// containing Flutter app to stay alive.
class IosVpnDevice implements SangforPacketDevice {
  IosVpnDevice._(this._socket);

  static const MethodChannel _channel = MethodChannel('flutter_sangfor');
  static const EventChannel _statusChannel =
      EventChannel('flutter_sangfor/vpn_status');
  static const int _defaultIpcPort = 6400;

  /// Maximum accepted IPC frame payload, mirroring the native decoder.
  static const int maxFrameLength = 0xffff;

  final Socket _socket;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _subscription;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isClosed => _closed;

  /// Live `NEVPNStatus` updates from the NetworkExtension manager.
  static Stream<IosVpnStatus> get statusStream =>
      _statusChannel.receiveBroadcastStream().map(
            (event) => IosVpnStatus.fromValue(event as String? ?? ''),
          );

  /// Starts the iOS VPN tunnel via the NetworkExtension framework and
  /// returns a packet device connected to the NE via local TCP.
  ///
  /// [address], [prefixLength], [routes], [dnsServers], [searchDomains],
  /// and [mtu] configure the tunnel network settings.
  ///
  /// [providerBundleIdentifier] identifies the consumer's packet tunnel
  /// `.appex` target; resolution order is this argument, then the Runner
  /// Info.plist key `SangforPacketTunnelBundleIdentifier`, then the legacy
  /// default `<bundle-id>.SangforPacketTunnelProvider`.
  ///
  /// [appGroupIdentifier] names the App Group shared with the extension
  /// (Info.plist key `SangforAppGroupIdentifier` as fallback).
  static Future<IosVpnDevice> start({
    required String address,
    required int prefixLength,
    List<String> routes = const <String>[],
    List<String> dnsServers = const <String>[],
    List<String> searchDomains = const <String>[],
    int mtu = 0,
    String? providerBundleIdentifier,
    String? appGroupIdentifier,
    String localizedDescription = 'flutter_sangfor',
  }) async {
    if (!Platform.isIOS) {
      throw UnsupportedError('IosVpnDevice requires iOS');
    }
    final started =
        await _channel.invokeMethod<bool>('vpnStart', <String, Object?>{
      'address': address,
      'prefixLength': prefixLength,
      'routes': routes,
      'dnsServers': dnsServers,
      'searchDomains': searchDomains,
      'mtu': mtu,
      'providerBundleIdentifier': providerBundleIdentifier,
      'appGroupIdentifier': appGroupIdentifier,
      'localizedDescription': localizedDescription,
    });
    if (started != true) {
      throw StateError('Failed to start the iOS VPN tunnel');
    }
    // The NE listens on loopback for the Dart-side connection. Wait briefly
    // for the socket to become available.
    Object? lastError;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          _defaultIpcPort,
          timeout: const Duration(milliseconds: 500),
        );
        return IosVpnDevice._create(socket);
      } on Object catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw StateError('Failed to connect to the NE IPC socket: $lastError');
  }

  static IosVpnDevice _create(Socket socket) {
    final device = IosVpnDevice._(socket);
    device._startListening();
    return device;
  }

  /// Installs (or loads) the VPN configuration. The first save triggers
  /// the system VPN permission prompt.
  static Future<void> installConfiguration({
    String? providerBundleIdentifier,
    String? appGroupIdentifier,
    String localizedDescription = 'flutter_sangfor',
  }) async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod<void>('vpnInstall', <String, Object?>{
      'providerBundleIdentifier': providerBundleIdentifier,
      'appGroupIdentifier': appGroupIdentifier,
      'localizedDescription': localizedDescription,
    });
  }

  /// Whether a VPN configuration created by this package exists and is
  /// enabled (not a global Android-style permission).
  static Future<bool> get isPrepared async {
    if (!Platform.isIOS) return false;
    final prepared = await _channel.invokeMethod<bool>('vpnPrepare');
    return prepared ?? false;
  }

  /// Runtime counters reported by the packet tunnel extension via the
  /// NETunnelProviderSession control channel. Returns `null` when the
  /// tunnel is not running.
  static Future<Map<String, Object?>?> stats() async {
    if (!Platform.isIOS) return null;
    return _channel.invokeMapMethod<String, Object?>('vpnStats');
  }

  @override
  Future<void> send(Uint8List packet) async {
    if (_closed) return;
    // 4-byte length prefix + packet.
    final header = ByteData(4)..setUint32(0, packet.length, Endian.big);
    _socket.add(header.buffer.asUint8List());
    _socket.add(packet);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    if (!_incoming.isClosed) {
      unawaited(_incoming.close());
    }
    _socket.destroy();
    await _channel.invokeMethod<void>('vpnStop');
  }

  void _startListening() {
    final decoder = IpcFrameDecoder();
    _subscription = _socket.listen(
      (chunk) {
        decoder.add(chunk);
        for (final packet in decoder.drain()) {
          if (!_incoming.isClosed) {
            _incoming.add(packet);
          }
        }
      },
      onDone: () {
        if (!_incoming.isClosed) {
          unawaited(_incoming.close());
        }
      },
      onError: (Object _) {
        if (!_incoming.isClosed) {
          unawaited(_incoming.close());
        }
      },
    );
  }
}
