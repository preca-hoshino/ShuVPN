import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'tunnel_io.dart';

const int _errorNoMoreItems = 259;
const int _errorBufferOverflow = 111;
const int _waitFailed = 0xffffffff;

/// A Windows layer-3 TUN device backed by the official WireGuard Wintun
/// driver. The signed `wintun.dll` from wintun.net must be shipped beside the
/// application executable (it is the only license-compliant distribution).
class WintunDevice implements SangforPacketDevice {
  WintunDevice._(
    this._lib,
    this._adapter,
    this._session,
    this._readWaitEvent,
    this.name,
    this._dllPath,
    this._receivePort,
  ) {
    _readIsolate = Isolate.spawn(
      _wintunReadLoop,
      _WintunReadParams(
        sendPort: _receivePort.sendPort,
        sessionAddress: _session.address,
        readWaitEventAddress: _readWaitEvent.address,
        dllPath: _dllPath,
      ),
    );
    _incomingSubscription = _receivePort.listen((packet) {
      if (packet is Uint8List && !_incoming.isClosed) {
        _incoming.add(packet);
      }
    });
  }

  final DynamicLibrary _lib;
  final Pointer<Void> _adapter;
  final Pointer<Void> _session;
  final Pointer<Void> _readWaitEvent;
  final String name;
  final String _dllPath;
  final ReceivePort _receivePort;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  late final Future<void> _readIsolate;
  StreamSubscription<Object?>? _incomingSubscription;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isClosed => _closed;

  /// Loads `wintun.dll` and creates (or opens) the adapter named [name].
  ///
  /// [dllPath] defaults to `wintun.dll` beside the executable; ship the
  /// signed DLL downloaded from https://www.wintun.net/.
  static Future<WintunDevice> open({
    required String name,
    String tunnelType = 'Sangfor',
    String? dllPath,
    int ringCapacity = 0x400000,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('WintunDevice requires Windows');
    }
    final path = dllPath ?? 'wintun.dll';
    if (!File(path).existsSync()) {
      throw StateError(
        'wintun.dll not found at "$path"; download the signed DLL from '
        'https://www.wintun.net/ and place it beside the executable',
      );
    }
    final lib = DynamicLibrary.open(path);
    final createAdapter = lib.lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>,
            Pointer<Void>)>('WintunCreateAdapter');
    final namePtr = name.toNativeUtf16();
    final typePtr = tunnelType.toNativeUtf16();
    Pointer<Void> adapter;
    try {
      adapter = createAdapter(namePtr, typePtr, nullptr);
    } finally {
      calloc.free(namePtr);
      calloc.free(typePtr);
    }
    if (adapter == nullptr) {
      throw StateError(
        'WintunCreateAdapter failed (Win32 error ${_lastError()}); '
        'the process likely needs to run elevated',
      );
    }
    final startSession = lib.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32),
        Pointer<Void> Function(Pointer<Void>, int)>('WintunStartSession');
    final session = startSession(adapter, ringCapacity);
    if (session == nullptr) {
      _closeAdapter(lib, adapter);
      throw StateError('WintunStartSession failed (${_lastError()})');
    }
    final readWaitEvent = _getReadWaitEvent(lib, session);
    final receivePort = ReceivePort();
    return WintunDevice._(
      lib,
      adapter,
      session,
      readWaitEvent,
      name,
      path,
      receivePort,
    );
  }

  static Pointer<Void> _getReadWaitEvent(
    DynamicLibrary lib,
    Pointer<Void> session,
  ) {
    final getReadWaitEvent = lib.lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('WintunGetReadWaitEvent');
    final event = getReadWaitEvent(session);
    if (event == nullptr) {
      throw StateError('WintunGetReadWaitEvent failed (${_lastError()})');
    }
    return event;
  }

  /// Writes one IP packet into the ring buffer. A full ring drops the packet
  /// silently, mirroring the upstream guidance.
  @override
  Future<void> send(Uint8List packet) async {
    if (_closed) return;
    final allocate = _lib.lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, Uint32),
        Pointer<Uint8> Function(
            Pointer<Void>, int)>('WintunAllocateSendPacket');
    final sendPacket = _lib.lookupFunction<
        Void Function(Pointer<Void>, Pointer<Uint8>),
        void Function(Pointer<Void>, Pointer<Uint8>)>('WintunSendPacket');
    final buffer = allocate(_session, packet.length);
    if (buffer == nullptr) {
      final error = _lastError();
      if (error == _errorBufferOverflow) return;
      throw StateError('WintunAllocateSendPacket failed ($error)');
    }
    buffer.asTypedList(packet.length).setAll(0, packet);
    sendPacket(_session, buffer);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final endSession = _lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('WintunEndSession');
    endSession(_session);
    await _readIsolate;
    await _incomingSubscription?.cancel();
    _receivePort.close();
    if (!_incoming.isClosed) {
      unawaited(_incoming.close());
    }
    _closeAdapter(_lib, _adapter);
  }

  static void _closeAdapter(DynamicLibrary lib, Pointer<Void> adapter) {
    final closeAdapter = lib.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('WintunCloseAdapter');
    closeAdapter(adapter);
  }

  static int _lastError() => DynamicLibrary.process()
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError')();

  /// Assigns a static address to the adapter with `netsh`. Requires an
  /// elevated process.
  Future<void> configureAddress(
    String address,
    String netmask, {
    String? gateway,
  }) async {
    final arguments = <String>[
      'interface',
      'ip',
      'set',
      'address',
      'name=$name',
      'source=static',
      'address=$address',
      'mask=$netmask',
      if (gateway != null) 'gateway=$gateway',
    ];
    await _runNetsh(arguments);
  }

  /// Adds a static route through the adapter with `netsh`. Requires an
  /// elevated process.
  Future<void> addRoute(String destination, int prefixLength) async {
    await _runNetsh(<String>[
      'interface',
      'ip',
      'add',
      'route',
      '$destination/$prefixLength',
      'interface="$name"',
      'store=active',
    ]);
  }

  /// Sets the adapter DNS servers with `netsh`. Requires an elevated process.
  Future<void> setDnsServers(List<String> servers) async {
    if (servers.isEmpty) return;
    await _runNetsh(<String>[
      'interface',
      'ip',
      'set',
      'dnsservers',
      'name=$name',
      'source=static',
      'address=${servers.first}',
      'validate=no',
    ]);
    for (var index = 1; index < servers.length; index++) {
      await _runNetsh(<String>[
        'interface',
        'ip',
        'add',
        'dnsservers',
        'name=$name',
        'address=${servers[index]}',
        'index=$index',
        'validate=no',
      ]);
    }
  }

  static Future<void> _runNetsh(List<String> arguments) async {
    final result = await Process.run('netsh', arguments);
    if (result.exitCode != 0) {
      throw StateError(
        'netsh ${arguments.join(' ')} failed: '
        '${result.stderr.toString().trim()}',
      );
    }
  }
}

class _WintunReadParams {
  const _WintunReadParams({
    required this.sendPort,
    required this.sessionAddress,
    required this.readWaitEventAddress,
    required this.dllPath,
  });

  final SendPort sendPort;
  final int sessionAddress;
  final int readWaitEventAddress;
  final String dllPath;
}

/// Blocking read loop running on its own isolate: receive packets until the
/// ring is empty, then wait on the read-wait event. [WintunDevice.close]
/// ends the session, which wakes the wait and fails the receive with
/// ERROR_HANDLE_EOF.
void _wintunReadLoop(_WintunReadParams params) {
  final session = Pointer<Void>.fromAddress(params.sessionAddress);
  final readWaitEvent = Pointer<Void>.fromAddress(params.readWaitEventAddress);
  final lib = DynamicLibrary.open(params.dllPath);
  final receivePacket = lib.lookupFunction<
      Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint32>),
      Pointer<Uint8> Function(
          Pointer<Void>, Pointer<Uint32>)>('WintunReceivePacket');
  final releasePacket = lib.lookupFunction<
      Void Function(Pointer<Void>, Pointer<Uint8>),
      void Function(
          Pointer<Void>, Pointer<Uint8>)>('WintunReleaseReceivePacket');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final waitForSingleObject = kernel32.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)>('WaitForSingleObject');
  final lastError = DynamicLibrary.process()
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  final size = calloc<Uint32>();
  try {
    while (true) {
      final packet = receivePacket(session, size);
      if (packet != nullptr) {
        params.sendPort.send(
          Uint8List.fromList(packet.asTypedList(size.value)),
        );
        releasePacket(session, packet);
        continue;
      }
      final error = lastError();
      if (error == _errorNoMoreItems) {
        final waitResult = waitForSingleObject(readWaitEvent, 500);
        if (waitResult == _waitFailed) {
          return;
        }
        continue;
      }
      // ERROR_HANDLE_EOF or a corrupt ring: stop reading.
      return;
    }
  } finally {
    calloc.free(size);
  }
}
