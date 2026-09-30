import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'tunnel_io.dart';

const int _maxPacketSize = 0xffff;

/// A packet device over an already-established integer file descriptor
/// (a Linux TUN fd, an Android VpnService tunnel fd, a macOS utun socket,
/// ...). The descriptor is switched to non-blocking mode and read from a
/// dedicated polling isolate.
class FdPacketDevice implements SangforPacketDevice {
  FdPacketDevice._(
    this._fd,
    this._ownsFd,
    this._prependHeaderOnSend,
    this._receivePort,
    this._isolateDone,
  ) {
    _incomingSubscription = _receivePort.listen((message) {
      if (message is Uint8List && !_incoming.isClosed) {
        _incoming.add(message);
      } else if (message is SendPort) {
        _controlSendPort = message;
      }
    });
  }

  final int _fd;
  final bool _ownsFd;
  final Uint8List _prependHeaderOnSend;
  final ReceivePort _receivePort;
  final Future<void> _isolateDone;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  StreamSubscription<Object?>? _incomingSubscription;
  SendPort? _controlSendPort;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isClosed => _closed;

  /// Takes ownership of [fd] and starts the read loop. When [ownsFd] is set,
  /// [close] closes the descriptor as well. The macOS utun interface prepends
  /// a 4-byte protocol-family header to each packet; set
  /// [stripHeaderOnReceive] to 4 to strip it on read and
  /// [prependHeaderOnSend] to the 4-byte header to add on write.
  static Future<FdPacketDevice> fromFd(
    int fd, {
    bool ownsFd = true,
    int stripHeaderOnReceive = 0,
    Uint8List? prependHeaderOnSend,
  }) async {
    final libc = DynamicLibrary.process();
    final fcntlFn = libc.lookupFunction<Int32 Function(Int32, Int32, Int64),
        int Function(int, int, int)>('fcntl');
    // F_SETFL (4) with O_NONBLOCK (0o4000 = 0x800).
    fcntlFn(fd, 4, 0x800);
    final header = prependHeaderOnSend ?? Uint8List(0);
    final receivePort = ReceivePort();
    final isolateDone = Isolate.spawn(
      _fdReadLoop,
      _FdReadParams(
        fd: fd,
        sendPort: receivePort.sendPort,
        stripHeader: stripHeaderOnReceive,
      ),
    );
    return FdPacketDevice._(
      fd,
      ownsFd,
      header,
      receivePort,
      isolateDone,
    );
  }

  /// Writes one IP packet to the descriptor. When a prepend header is set
  /// (utun), the 4-byte protocol-family header is prepended automatically
  /// based on the IP version nibble.
  @override
  Future<void> send(Uint8List packet) async {
    if (_closed) return;
    if (packet.isEmpty) return;
    final header = _prependHeaderOnSend.isEmpty
        ? null
        : _familyHeaderForPacket(packet) ?? _prependHeaderOnSend;
    final length = packet.length + (header?.length ?? 0);
    final libc = DynamicLibrary.process();
    final writeFn = libc.lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)>('write');
    final buffer = calloc<Uint8>(length);
    try {
      if (header != null) {
        buffer.asTypedList(header.length).setAll(0, header);
        buffer.asTypedList(length).setRange(header.length, length, packet);
      } else {
        buffer.asTypedList(length).setAll(0, packet);
      }
      final written = writeFn(_fd, buffer, length);
      if (written < 0) {
        throw StateError('fd write failed with errno ${fdErrno(libc)}');
      }
    } finally {
      calloc.free(buffer);
    }
  }

  Uint8List? _familyHeaderOnSendForPlatform(int family) {
    if (_prependHeaderOnSend.isEmpty) return null;
    return Uint8List.fromList(
      <int>[family & 0xff, 0, 0, 0],
    );
  }

  Uint8List? _familyHeaderForPacket(Uint8List packet) {
    if (packet.isEmpty) return null;
    final version = packet[0] >> 4;
    if (version == 4) return _familyHeaderOnSendForPlatform(2);
    if (version == 6) return _familyHeaderOnSendForPlatform(28);
    return null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _controlSendPort?.send('stop');
    await _isolateDone;
    await _incomingSubscription?.cancel();
    _receivePort.close();
    if (!_incoming.isClosed) {
      unawaited(_incoming.close());
    }
    if (_ownsFd) {
      final libc = DynamicLibrary.process();
      final closeFn = libc
          .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
      closeFn(_fd);
    }
  }
}

class _FdReadParams {
  const _FdReadParams({
    required this.fd,
    required this.sendPort,
    required this.stripHeader,
  });

  final int fd;
  final SendPort sendPort;
  final int stripHeader;
}

/// Non-blocking read loop: drains packets while available, then sleeps
/// briefly between polls. The main isolate sends 'stop' to end the loop.
void _fdReadLoop(_FdReadParams params) {
  final libc = DynamicLibrary.process();
  final readFn = libc.lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Int32),
      int Function(int, Pointer<Uint8>, int)>('read');
  final usleepFn =
      libc.lookupFunction<Void Function(Uint32), void Function(int)>('usleep');
  final buffer = calloc<Uint8>(_maxPacketSize);
  final control = ReceivePort();
  var stopped = false;
  control.listen((message) {
    if (message == 'stop') stopped = true;
  });
  params.sendPort.send(control.sendPort);
  try {
    while (!stopped) {
      final length = readFn(params.fd, buffer, _maxPacketSize);
      if (length > params.stripHeader) {
        final payload = params.stripHeader > 0
            ? Uint8List.fromList(
                buffer.asTypedList(length).sublist(params.stripHeader),
              )
            : Uint8List.fromList(buffer.asTypedList(length));
        params.sendPort.send(payload);
      } else {
        usleepFn(2000);
      }
    }
  } finally {
    control.close();
    calloc.free(buffer);
  }
}

int fdErrno(DynamicLibrary libc) {
  final errnoLocation =
      libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          '__errno_location');
  return errnoLocation().value;
}
