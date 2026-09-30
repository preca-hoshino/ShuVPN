import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'tunnel_io.dart';

/// Adapts a plain [Socket] to the [SangforTcpStream] boundary.
///
/// Useful for feeding ordinary TCP connections (dialed outside the VPN)
/// into components that expect tunnel streams, and in tests.
class SocketTcpStream extends SangforTcpStream {
  SocketTcpStream(this._socket) {
    _subscription = _socket.listen(
      (chunk) {
        if (!_incoming.isClosed) {
          _incoming.add(Uint8List.fromList(chunk));
        }
      },
      onDone: () {
        if (!_incoming.isClosed) unawaited(_incoming.close());
      },
      onError: (Object _) {
        if (!_incoming.isClosed) {
          _incoming.addError(StateError('socket failed'));
          unawaited(_incoming.close());
        }
      },
    );
  }

  final Socket _socket;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  StreamSubscription<List<int>>? _subscription;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) return;
    _socket.add(data);
  }

  @override
  Future<void> closeWrite() async {
    if (_closed) return;
    await _socket.flush();
    _socket.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _socket.destroy();
    if (!_incoming.isClosed) {
      unawaited(_incoming.close());
    }
  }
}
