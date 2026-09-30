import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'fd_packet_device.dart';
import 'tunnel_io.dart';

const int _afSysControl = 39;
const int _sysProtoControl = 2;
const int _ctlIoCgId = 0xC0646300;

/// A macOS layer-3 TUN device backed by the utun interface. A utun socket is
/// created via `socket(AF_SYS_CONTROL, SOCK_DGRAM, SYSPROTO_CONTROL)` + an
/// `ioctl(CTLIOCGID)` to obtain the control ID, followed by `connect()` to
/// a `sockaddr_ctl` which assigns the adapter a `utunN` name. The socket fd
/// is handed to [FdPacketDevice] with utun's 4-byte protocol-family header
/// strip/prepend enabled.
class UtunDevice implements SangforPacketDevice {
  UtunDevice._(this.name, this._device);

  final String name;
  final FdPacketDevice _device;

  @override
  Stream<Uint8List> get incoming => _device.incoming;

  @override
  bool get isClosed => _device.isClosed;

  /// Opens a utun adapter. The [requestedUnit] (0 = auto) lets the kernel
  /// pick the next free `utunN` index.
  static Future<UtunDevice> open({int requestedUnit = 0}) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('UtunDevice requires macOS');
    }
    final libc = DynamicLibrary.process();
    final socketFn = libc.lookupFunction<Int32 Function(Int32, Int32, Int32),
        int Function(int, int, int)>('socket');
    final fd = socketFn(_afSysControl, 2 /* SOCK_DGRAM */, _sysProtoControl);
    if (fd < 0) {
      throw StateError(
        'socket(AF_SYS_CONTROL) failed with errno ${_macOSErrno(libc)}; '
        'CAP_NET_ADMIN is required',
      );
    }
    // CTLIOCGID fills in ctl_id (first 4 bytes of the 100-byte struct).
    final ctlInfo = calloc<Uint8>(100);
    try {
      final name = 'com.apple.net.utun'.codeUnits;
      for (var index = 0; index < name.length; index++) {
        ctlInfo[4 + index] = name[index];
      }
      final ioctlFn = libc.lookupFunction<
          Int32 Function(Int32, Uint64, Pointer<Void>),
          int Function(int, int, Pointer<Void>)>('ioctl');
      final result = ioctlFn(fd, _ctlIoCgId, ctlInfo.cast());
      if (result < 0) {
        final error = _macOSErrno(libc);
        _closeFd(libc, fd);
        throw StateError('CTLIOCGID failed with errno $error');
      }
      final ctlId = ctlInfo.cast<Int32>().value;
      if (ctlId == 0) {
        _closeFd(libc, fd);
        throw StateError('CTLIOCGID returned a zero ctl_id');
      }
      final sockaddrCtl = calloc<Uint8>(28);
      try {
        // struct sockaddr_ctl { u_int8_t len; u_int8_t family; u_int16_t unit;
        // u_int32_t sc_id; u_int32_t sc_reserved1; u_int32_t sc_reserved2; }
        sockaddrCtl[0] = 28; // sc_len
        sockaddrCtl[1] = _afSysControl; // family (AF_SYS_CONTROL)
        sockaddrCtl.cast<Int16>()[1] = requestedUnit; // sc_unit
        sockaddrCtl.cast<Int32>()[1] = ctlId; // sc_id
        final connectFn = libc.lookupFunction<
            Int32 Function(Int32, Pointer<Uint8>, Uint32),
            int Function(int, Pointer<Uint8>, int)>('connect');
        final connectResult = connectFn(fd, sockaddrCtl, 28);
        if (connectResult < 0) {
          final error = _macOSErrno(libc);
          _closeFd(libc, fd);
          throw StateError('utun connect failed with errno $error');
        }
      } finally {
        calloc.free(sockaddrCtl);
      }
      // Discover the assigned utunN name via getsockname().
      final assignedName = _getsockname(libc, fd);
      // The utun interface prepends a 4-byte protocol family header to each
      // packet. _prependHeaderOnSend is a placeholder; the actual family
      // is determined per-packet by FdPacketDevice.send() based on the IP
      // version nibble.
      final device = await FdPacketDevice.fromFd(
        fd,
        stripHeaderOnReceive: 4,
        prependHeaderOnSend: Uint8List.fromList(<int>[2, 0, 0, 0]),
      );
      return UtunDevice._(assignedName, device);
    } finally {
      calloc.free(ctlInfo);
    }
  }

  static String _getsockname(DynamicLibrary libc, int fd) {
    final sockaddr = calloc<Uint8>(64);
    try {
      final lenPtr = calloc<Int32>();
      lenPtr.value = 64;
      try {
        final getsocknameFn = libc.lookupFunction<
            Int32 Function(Int32, Pointer<Uint8>, Pointer<Int32>),
            int Function(int, Pointer<Uint8>, Pointer<Int32>)>('getsockname');
        final result = getsocknameFn(fd, sockaddr, lenPtr);
        if (result < 0) {
          return 'utun?';
        }
        final scId = sockaddr.cast<Int32>()[1];
        final scUnit = sockaddr.cast<Int16>()[1];
        if (scId == 0 || scUnit == 0) {
          return 'utun?';
        }
        return 'utun${scUnit - 1}';
      } finally {
        calloc.free(lenPtr);
      }
    } finally {
      calloc.free(sockaddr);
    }
  }

  /// Writes one IP packet to the utun socket (with the 4-byte family header
  /// prepended by [FdPacketDevice]).
  @override
  Future<void> send(Uint8List packet) => _device.send(packet);

  @override
  Future<void> close() => _device.close();

  static void _closeFd(DynamicLibrary libc, int fd) {
    final closeFn =
        libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
    closeFn(fd);
  }
}

int _macOSErrno(DynamicLibrary libc) {
  final errorFn =
      libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          '__error');
  return errorFn().value;
}
