import 'dart:async';
import 'dart:typed_data';

import 'errors.dart';

/// A bidirectional byte stream over a VPN tunnel, shaped like a socket.
///
/// Implementations exist for the aTrust TCP tunnel channels and the
/// EasyConnect TCP-over-L3 proxy. Closes may be full duplex: [closeWrite]
/// half-closes when the transport supports it.
abstract class SangforTcpStream {
  Stream<Uint8List> get incoming;

  bool get isClosed;

  Future<void> send(Uint8List data);

  /// Half-closes the outgoing direction when supported.
  Future<void> closeWrite();

  Future<void> close();
}

/// Product-neutral raw IP packet tunnel (L3 data plane).
abstract class SangforPacketTunnel {
  Stream<Uint8List> get incoming;

  bool get isClosed;

  /// Sends one raw IP packet. Returns whether the packet was routed.
  Future<bool> sendPacket(Uint8List packet);

  Future<void> close();
}

/// A TUN-style packet device: packets read from the operating system arrive
/// on [incoming]; packets destined to the operating system are sent with
/// [send]. Implemented by the desktop TUN adapters and test doubles.
abstract class SangforPacketDevice {
  Stream<Uint8List> get incoming;

  bool get isClosed;

  Future<void> send(Uint8List packet);

  Future<void> close();
}

/// Pumps packets between a [SangforPacketDevice] and a
/// [SangforPacketTunnel] until stopped. Egress and ingress can be filtered;
/// returning false drops the packet silently. A [SangforCancellationToken]
/// stops the router when cancelled.
class SangforTunnelRouter {
  SangforTunnelRouter({
    this.egressFilter,
    this.ingressFilter,
    this.onError,
    this.cancellationToken,
  });

  final bool Function(Uint8List packet)? egressFilter;
  final bool Function(Uint8List packet)? ingressFilter;
  final void Function(Object error)? onError;
  final SangforCancellationToken? cancellationToken;

  StreamSubscription<Uint8List>? _deviceSubscription;
  StreamSubscription<Uint8List>? _tunnelSubscription;
  bool _stopped = false;

  bool get isRunning => !_stopped;

  void start({
    required SangforPacketDevice device,
    required SangforPacketTunnel tunnel,
  }) {
    if (_stopped) throw StateError('router is stopped');
    _deviceSubscription = device.incoming.listen(
      (packet) => _forward(
        () => tunnel.sendPacket(packet),
        egressFilter,
        packet,
      ),
      onError: (Object error) => _report(error),
    );
    _tunnelSubscription = tunnel.incoming.listen(
      (packet) => _forward(() => device.send(packet), ingressFilter, packet),
      onError: (Object error) => _report(error),
    );
    final token = cancellationToken;
    if (token != null) {
      unawaited(token.whenCancelled.then((_) => stop()));
    }
  }

  void _forward(
    Future<void> Function() send,
    bool Function(Uint8List packet)? filter,
    Uint8List packet,
  ) {
    if (filter != null && !filter(packet)) return;
    unawaited(
      send().catchError((Object error) {
        _report(error);
        return null;
      }),
    );
  }

  void _report(Object error) {
    onError?.call(error);
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _deviceSubscription?.cancel();
    await _tunnelSubscription?.cancel();
    _deviceSubscription = null;
    _tunnelSubscription = null;
  }
}
