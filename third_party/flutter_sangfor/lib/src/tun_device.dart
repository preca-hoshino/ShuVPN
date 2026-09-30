import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'fd_packet_device.dart';
import 'tunnel_io.dart';

const int _tunsetiffRequest = 0x400454ca;
const int _iffTun = 0x0001;
const int _iffNoPi = 0x1000;
const int _oRdwr = 0x0002;

/// A Linux layer-3 TUN device (`/dev/net/tun`) implemented with direct libc
/// FFI. The descriptor is handed to an [FdPacketDevice] which reads on a
/// dedicated isolate.
class TunDevice implements SangforPacketDevice {
  TunDevice._(this.name, this._device);

  final String name;
  final FdPacketDevice _device;

  @override
  Stream<Uint8List> get incoming => _device.incoming;

  @override
  bool get isClosed => _device.isClosed;

  /// Opens `/dev/net/tun` and binds the [name] interface as a TUN device
  /// without packet information. Requires the interface to be configured
  /// (address, routes) by the caller, for example with `ip`.
  static Future<TunDevice> open({required String name}) async {
    if (!Platform.isLinux) {
      throw UnsupportedError('TunDevice requires Linux');
    }
    if (name.isEmpty || name.length > 15) {
      throw ArgumentError.value(name, 'name', 'must be 1-15 characters');
    }
    final libc = DynamicLibrary.process();
    final openFn = libc.lookupFunction<Int32 Function(Pointer<Int8>, Int32),
        int Function(Pointer<Int8>, int)>('open');
    final pathPtr = '/dev/net/tun'.toNativeUtf8().cast<Int8>();
    final fd = openFn(pathPtr, _oRdwr);
    calloc.free(pathPtr);
    if (fd < 0) {
      throw StateError(
        'open("/dev/net/tun") failed with errno ${fdErrno(libc)}; '
        'CAP_NET_ADMIN or an existing /dev/net/tun is required',
      );
    }
    final request = calloc.allocate<Uint8>(32);
    try {
      for (var index = 0; index < name.length; index++) {
        request[index] = name.codeUnitAt(index);
      }
      // ifr_flags lives 16 bytes into struct ifreq, after ifr_name.
      final flagsView = (request + 16).cast<Int16>();
      final ioctlFn = libc.lookupFunction<
          Int32 Function(Int32, Uint64, Pointer<Void>),
          int Function(int, int, Pointer<Void>)>('ioctl');
      flagsView.value = _iffTun | _iffNoPi;
      final result = ioctlFn(fd, _tunsetiffRequest, request.cast());
      if (result < 0) {
        final errno = fdErrno(libc);
        _closeFd(libc, fd);
        throw StateError('TUNSETIFF for "$name" failed with errno $errno');
      }
    } finally {
      calloc.free(request);
    }
    final device = await FdPacketDevice.fromFd(fd);
    return TunDevice._(name, device);
  }

  /// Writes one IP packet to the TUN file descriptor.
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
