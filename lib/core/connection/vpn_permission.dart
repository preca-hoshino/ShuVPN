import 'dart:io';

import 'shu_android_vpn.dart';

/// 「系统 VPN 授权」这一层的接口。
///
/// 抽出来只为一件事：**测试**。widget 测试跑在桌面宿主上 ——
/// `Platform.isAndroid` 是 false、`shuvpn/vpn` 这条 channel 也不在，于是
/// 授权状态永远落在「未授权」上，引导页「点一下 → 已授权 → 底部按钮解禁」
/// 那条路一行也测不到。测试替换掉这一层，页面与 [ConnectionController] 都
/// 不用知道。
///
/// 默认实现直接打给原生（见 [ShuAndroidVpn]），所以生产路径上这就是一层
/// 三行的壳 —— 值在的地方是**它背后的那个系统状态**，不是这里的代码。
///
/// [ConnectionController] 是它唯一的消费者。
class ShuVpnPermission {
  const ShuVpnPermission();

  /// 这台设备有没有「系统 VPN 授权」这回事。
  ///
  /// 只有 Android 有。别的平台走本机代理，既不该被这一步挡住，也不该在
  /// 界面上摆一行永远拿不到的东西。
  bool get isSupported => Platform.isAndroid;

  /// 查一次当前状态：系统已经授权过就是 true。
  Future<bool> isPrepared() => ShuAndroidVpn.isPrepared;

  /// 弹系统授权对话框。
  ///
  /// 已经授权过时原生侧直接回 true、**不弹**（见 `ShuVpnPlugin.requestPermission`），
  /// 所以重复调用是安全的。
  Future<bool> request() => ShuAndroidVpn.requestPermission();
}
