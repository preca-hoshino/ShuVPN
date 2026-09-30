import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';
import 'tunnel_io.dart';

/// Dials one TCP connection through a VPN tunnel. [host] may be a domain;
/// resolvers that need the VPN DNS must handle that themselves.
typedef SangforTcpDialer = Future<SangforTcpStream> Function(
  String host,
  int port,
);

/// Minimal RFC 1928 SOCKS5 server: no-auth + CONNECT. Binds loopback by
/// default so the proxy only serves the local machine.
class SangforSocks5Server {
  SangforSocks5Server({
    required this.dialer,
    this.listenAddress,
    this.port = 0,
    this.dialTimeout = const Duration(seconds: 30),
    this.onDialError,
    this.cancellationToken,
  }) : assert(port >= 0 && port <= 65535);

  final SangforTcpDialer dialer;
  final InternetAddress? listenAddress;
  final int port;
  final Duration dialTimeout;
  final void Function(String host, int port, Object error)? onDialError;

  /// When cancelled, the server stops accepting connections and all live
  /// sessions (including in-flight dials) are torn down.
  final SangforCancellationToken? cancellationToken;

  ServerSocket? _server;
  final Set<SangforSocks5ClientSession> _sessions =
      <SangforSocks5ClientSession>{};

  bool get isRunning => _server != null;

  int? get boundPort => _server?.port;

  Future<int> start() async {
    if (_server != null) throw StateError('SOCKS5 server is already running');
    final address = listenAddress ?? InternetAddress.loopbackIPv4;
    final server = await ServerSocket.bind(address, port);
    server.listen(
      _accept,
      onError: (Object error) {
        // Listening socket errors surface via closed sessions.
      },
    );
    _server = server;
    final token = cancellationToken;
    if (token != null) {
      unawaited(token.whenCancelled.then((_) => close()));
    }
    return server.port;
  }

  void _accept(Socket socket) {
    final session = SangforSocks5ClientSession(
      socket: socket,
      dialer: dialer,
      dialTimeout: dialTimeout,
      onDialError: onDialError,
      onFinished: _sessions.remove,
      cancellationToken: cancellationToken,
    );
    _sessions.add(session);
    session.start();
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close();
    final sessions = List<SangforSocks5ClientSession>.of(_sessions);
    _sessions.clear();
    for (final session in sessions) {
      await session.close();
    }
  }
}

const int _socksVersion = 0x05;

enum _SocksPhase { greeting, request, pumping }

/// One accepted SOCKS5 client connection.
class SangforSocks5ClientSession {
  SangforSocks5ClientSession({
    required Socket socket,
    required SangforTcpDialer dialer,
    required this.dialTimeout,
    required this.onDialError,
    required this.onFinished,
    this.cancellationToken,
  })  : _socket = socket,
        _dialer = dialer;

  static const int _bufferLimit = 512;

  final Socket _socket;
  final SangforTcpDialer _dialer;
  final Duration dialTimeout;
  final void Function(String host, int port, Object error)? onDialError;
  final void Function(SangforSocks5ClientSession session) onFinished;
  final SangforCancellationToken? cancellationToken;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  _SocksPhase _phase = _SocksPhase.greeting;
  SangforTcpStream? _tunnelStream;
  Future<void> _sendChain = Future<void>.value();
  StreamSubscription<Uint8List>? _tunnelSubscription;
  StreamSubscription<List<int>>? _socketSubscription;
  bool _closed = false;

  void start() {
    _socketSubscription = _socket.listen(
      (chunk) => _onClientData(Uint8List.fromList(chunk)),
      onDone: _onClientDone,
      onError: (Object _) => close(),
    );
  }

  void _onClientData(Uint8List chunk) {
    if (_closed) return;
    if (_phase == _SocksPhase.pumping) {
      // While the dial is in flight, keep buffering so pipelined client
      // bytes (common with HTTP) are not lost.
      if (_tunnelStream == null) {
        if (_buffer.length + chunk.length > _bufferLimit) {
          close();
          return;
        }
        _buffer.add(chunk);
      } else {
        _enqueueSend(chunk);
      }
      return;
    }
    _buffer.add(chunk);
    if (_buffer.length > _bufferLimit) {
      close();
      return;
    }
    _pump();
  }

  void _pump() {
    switch (_phase) {
      case _SocksPhase.greeting:
        _parseGreeting();
      case _SocksPhase.request:
        _parseRequest();
      case _SocksPhase.pumping:
        break;
    }
  }

  void _parseGreeting() {
    final bytes = _buffer.toBytes();
    if (bytes.length < 2) return;
    if (bytes[0] != _socksVersion) {
      close();
      return;
    }
    final methodCount = bytes[1];
    if (bytes.length < 2 + methodCount) return;
    var noAuth = false;
    for (var i = 0; i < methodCount; i++) {
      if (bytes[2 + i] == 0x00) noAuth = true;
    }
    if (!noAuth) {
      _socket.add(Uint8List.fromList([_socksVersion, 0xff]));
      close();
      return;
    }
    _socket.add(Uint8List.fromList([_socksVersion, 0x00]));
    _buffer.clear();
    _buffer.add(Uint8List.sublistView(bytes, 2 + methodCount));
    _phase = _SocksPhase.request;
    if (_buffer.isNotEmpty) {
      _parseRequest();
    }
  }

  void _parseRequest() {
    final bytes = _buffer.toBytes();
    if (bytes.length < 4) return;
    if (bytes[0] != _socksVersion) {
      close();
      return;
    }
    final command = bytes[1];
    final addressType = bytes[3];
    int consumed;
    String host;
    var port = 0;
    switch (addressType) {
      case 0x01:
        if (bytes.length < 10) return;
        host = '${bytes[4]}.${bytes[5]}.${bytes[6]}.${bytes[7]}';
        port = (bytes[8] << 8) | bytes[9];
        consumed = 10;
      case 0x03:
        if (bytes.length < 5) return;
        final length = bytes[4];
        if (bytes.length < 5 + length + 2) return;
        host = String.fromCharCodes(bytes.sublist(5, 5 + length));
        port = (bytes[5 + length] << 8) | bytes[6 + length];
        consumed = 5 + length + 2;
      case 0x04:
        if (bytes.length < 22) return;
        final groups = <String>[];
        for (var i = 0; i < 16; i += 2) {
          groups.add(((bytes[4 + i] << 8) | bytes[5 + i]).toRadixString(16));
        }
        host = groups.join(':');
        port = (bytes[20] << 8) | bytes[21];
        consumed = 22;
      default:
        _reply(0x08);
        close();
        return;
    }
    _buffer.clear();
    _buffer.add(Uint8List.sublistView(bytes, consumed));
    _phase = _SocksPhase.pumping;
    _handleConnect(command, host, port);
  }

  Future<void> _handleConnect(int command, String host, int port) async {
    if (command != 0x01) {
      _reply(0x07);
      close();
      return;
    }
    if (port <= 0 || port > 65535) {
      _reply(0x01);
      close();
      return;
    }
    SangforTcpStream stream;
    try {
      final token = cancellationToken;
      final dial =
          token == null ? _dialer(host, port) : token.race(_dialer(host, port));
      stream = await dial.timeout(dialTimeout);
    } on Object catch (error) {
      onDialError?.call(host, port, error);
      _reply(0x01);
      close();
      return;
    }
    if (_closed) {
      await stream.close();
      return;
    }
    _tunnelStream = stream;
    _reply(0x00);
    _pipeTunnelToClient(stream);
    final leftover = _buffer.toBytes();
    _buffer.clear();
    if (leftover.isNotEmpty) {
      _enqueueSend(Uint8List.fromList(leftover));
    }
  }

  void _pipeTunnelToClient(SangforTcpStream stream) {
    _tunnelSubscription = stream.incoming.listen(
      _socket.add,
      onDone: () async {
        try {
          await _socket.flush();
          await _socket.close();
        } on Object {
          // The client may already be gone.
        }
      },
      onError: (Object _) => close(),
    );
  }

  /// Serializes tunnel sends so chunks stay ordered and each write
  /// completes before the next starts.
  void _enqueueSend(Uint8List chunk) {
    final stream = _tunnelStream;
    if (stream == null) return;
    _sendChain = _sendChain.then((_) async {
      if (_closed || stream.isClosed) return;
      await stream.send(chunk);
    }).catchError((Object _) {
      // Send failures tear the session down via the stream error path.
    });
  }

  Future<void> _onClientDone() async {
    final stream = _tunnelStream;
    if (stream == null) {
      close();
      return;
    }
    try {
      await _sendChain;
      await stream.closeWrite();
    } on Object {
      close();
    }
  }

  void _reply(int code) {
    if (_closed) return;
    _socket.add(
      Uint8List.fromList([_socksVersion, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _socketSubscription?.cancel();
    await _tunnelSubscription?.cancel();
    _socket.destroy();
    await _tunnelStream?.close();
    onFinished(this);
  }
}
