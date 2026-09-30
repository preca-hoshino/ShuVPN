import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';

import '../logging/shu_log.dart';

/// ShuVPN 自己的 Android 系统 VPN（`VpnService`）。
///
/// ## 为什么不用 `flutter_sangfor` 的 `AndroidVpnDevice`
///
/// 那份实现在原生侧把**唯一的一条路由丢掉了**。它的 `VpnTunnelService`
/// 有一段「别让 DNS 查询绕进隧道」的保护：
///
/// ```kotlin
/// val effectiveDns = dnsServers.ifEmpty { underlyingDnsServers() }
/// for (route in routes) {
///     if (effectiveDns.any { routeCovers(prefix, length, it) }) continue
///     builder.addRoute(prefix, length)
/// }
/// ```
///
/// 而 `routeCovers("0.0.0.0", 0, dns)` 里的掩码是 `0`，所以
/// `(0 and 0) == (dns and 0)` **永远成立** —— `0.0.0.0/0` 被判成「覆盖了
/// DNS 服务器」而被跳过。`effectiveDns` 又由底层网络的 DNS 兜底、几乎不会
/// 为空，于是 `Builder` 一条 `addRoute` 都没加上：接口建好了、通知栏出来了、
/// 系统却一个包都不往 TUN 里送。这正是「VPN 开着但没劫持任何流量」。
///
/// 另外那份实现**没有把自己排除在 VPN 之外**（注释说调用方会通过路由排除
/// 隧道节点，但代码里没有）：就算路由修好，隧道自己连网关的 socket 也会被
/// `0.0.0.0/0` 吸进 TUN，绕回自己。
///
/// 两处都在依赖包的原生代码里，app 侧改不动，所以这一层由 `ShuVpnService`
/// + `ShuVpnPlugin` 自己实现（见 `android/app/src/main/kotlin`）。这里只
/// 复用依赖包公开导出的 [FdPacketDevice]：把原生交过来的 fd 变成包流。
class ShuAndroidVpn {
  const ShuAndroidVpn._();

  static const MethodChannel _channel = MethodChannel('shuvpn/vpn');

  static final StreamController<void> _disconnectRequests =
      StreamController<void>.broadcast();
  static bool _handlerInstalled = false;

  /// 用户在通知栏点了「断开」。
  static Stream<void> get disconnectRequests {
    _installHandler();
    return _disconnectRequests.stream;
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'disconnectRequested') {
        _disconnectRequests.add(null);
      }
      return null;
    });
  }

  /// 系统是否已经授予 VPN 权限。
  static Future<bool> get isPrepared async =>
      await _channel.invokeMethod<bool>('isPrepared') ?? false;

  /// 弹系统授权对话框。**需要一个前台页面**，否则原生侧会回 `no_activity`。
  static Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  /// 起服务、建 TUN，返回包设备；没有授权或建立失败时返回 `null`。
  ///
  /// [routes] 决定**哪些流量会被系统交给这条隧道**。它必须是网关资源表里
  /// 的网段（见 `vpn_routes.dart`），**不能是 `0.0.0.0/0`** —— 隧道只会转发
  /// 落在资源表里的包，其余的会被静默丢掉，全路由等于把所有流量引向黑洞。
  ///
  /// [dnsServers] 是期望**走隧道**的 DNS（用户手填的，或网关下发且落在
  /// [routes] 内的）。原生侧一定会再追加底层网络那一组当兜底。
  ///
  /// [routes] 决定**哪些流量会被系统交给这条隧道**。它必须是**隧道真的
  /// 背得动**的那些网段（见 `ShuVpnRoutePlan.l3Routes`），而不是资源表的
  /// 全部：aTrust 的 L3 数据面对 TCP 有一道 `enableTcpPrefL3` 的硬门，
  /// 交给 TUN 的网段里只要有人做 TCP，那些 TCP 就会被静默丢弃。
  ///
  /// [httpProxyHost] / [httpProxyPort] 是**本机 HTTP 代理**的地址，会被写进
  /// 系统代理设置。应用们与隧道的 TCP 那一半就靠它 —— `VpnService` 的路由
  /// 按地址分流、认不出协议，TCP 进 TUN 只会进黑洞。
  ///
  /// 主机默认 `127.0.0.1`：系统代理是填给所有应用的，而应用都在本机发起
  /// 连接。只有当监听地址被限定在某一张具名网卡上时才会换成那个地址。
  static Future<ShuAndroidVpnDevice?> start({
    required String address,
    int prefixLength = 32,
    int mtu = 0,
    List<String> routes = const <String>[],
    List<String> dnsServers = const <String>[],
    String httpProxyHost = '127.0.0.1',
    int? httpProxyPort,
    String notificationTitle = 'ShuVPN',
    String disconnectLabel = '断开',
  }) async {
    final fd = await _channel.invokeMethod<int>('start', <String, Object?>{
      'address': address,
      'prefixLength': prefixLength,
      'mtu': mtu,
      'routes': routes,
      'dnsServers': dnsServers,
      'httpProxyHost': httpProxyHost,
      'httpProxyPort': httpProxyPort ?? 0,
      'notificationTitle': notificationTitle,
      'disconnectLabel': disconnectLabel,
    });
    if (fd == null || fd < 0) {
      ShuLog.w(ShuLogTag.vpn, '原生侧没有返回可用的 TUN 描述符 · fd=$fd');
      return null;
    }
    return ShuAndroidVpnDevice.fromFd(fd);
  }

  /// 停掉服务（关接口、撤掉通知栏）。
  static Future<void> stop() => _channel.invokeMethod<void>('stop');
}

/// 把原生交过来的 TUN 描述符包成 [SangforPacketDevice]。
///
/// 与 `AndroidVpnDevice` 的差别只在 [close]：它关掉 fd 之后还要通知原生
/// 停掉 `VpnService`，否则通知栏会留下来、系统也认为 VPN 仍然挂着。
class ShuAndroidVpnDevice implements SangforPacketDevice {
  ShuAndroidVpnDevice._(this._device);

  final FdPacketDevice _device;

  static Future<ShuAndroidVpnDevice> fromFd(int fd) async =>
      ShuAndroidVpnDevice._(await FdPacketDevice.fromFd(fd));

  @override
  Stream<Uint8List> get incoming => _device.incoming;

  @override
  bool get isClosed => _device.isClosed;

  @override
  Future<void> send(Uint8List packet) => _device.send(packet);

  @override
  Future<void> close() async {
    await _device.close();
    await ShuAndroidVpn.stop();
  }
}
