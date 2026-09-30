import 'package:flutter/material.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';

/// 本应用能「用哪种协议去连」的那几种可能。
///
/// 它**不等于** [SangforProduct]：那是 SDK 里真的有两套实现的协议栈
/// （aTrust / EasyConnect），而这里是一个更大的集合 —— OpenVPN 完全不在
/// SDK 的范围内，一行实现都没有，但它是用户会问的那类问题
/// （「这个应用能怎么连」），所以照样列出来。
///
/// 三者的差别不在「偏好」上，而在**有没有实现**：
///
/// | 值 | 实现 | 默认启用 | 说明 |
/// | :--- | :--- | :--- | :--- |
/// | [atrust] | 有（`flutter_sangfor_atrust`） | **是** | 上大部署的网关 |
/// | [easyConnect] | 有核心，未接入 | 否，且开关封掉 | 同一台网关的另一个入口 |
/// | [openVpn] | 没有 | 否，且开关封掉 | 不是 Sangfor 家族的东西 |
///
/// 所以「开关关掉」在这三者身上是两件不同的事：aTrust 是真的可以关
/// （用户只想要一个不联网的状态），另外两个是**关不了也开不了** ——
/// 它们没有可执行的代码路径。设置页把开关画成灰的而不是藏起来，
/// 是为了让人看到「这个位置将来会有一个开关」，而不是以为漏了。
enum ShuProtocol {
  atrust(
    id: 'atrust',
    label: 'aTrust',
    icon: Icons.shield_moon_outlined,
    implemented: true,
  ),
  easyConnect(
    id: 'easyconnect',
    label: 'EasyConnect',
    icon: Icons.hub_outlined,
    implemented: false,
  ),
  openVpn(
    id: 'openvpn',
    label: 'OpenVPN',
    icon: Icons.lock_open_outlined,
    implemented: false,
  );

  const ShuProtocol({
    required this.id,
    required this.label,
    required this.icon,
    required this.implemented,
  });

  /// 持久化与路由里用的标识。同时也是 SDK [SangforProduct] 的名字
  /// （除 OpenVPN 之外），所以两边的取值刻意保持一致。
  final String id;

  /// 界面上的名字。
  final String label;

  /// 设置页与协议选择条上的图标。
  final IconData icon;

  /// 本应用里**有没有**这条可执行的连接路径。
  ///
  /// 为 false 时开关不可点、也不会被自动选中 —— 但是**照样显示**，
  /// 见类注释里那段理由。
  final bool implemented;

  /// 映射到 SDK 的协议栈。OpenVPN 没有对应项，返回 `null`。
  ///
  /// 连接层拿它决定造哪个 connector；`null` 就是「这条路径不存在」，
  /// 由调用方转成一条明确的错误，而不是默默去试一个别的协议。
  SangforProduct? get product => switch (this) {
    ShuProtocol.atrust => SangforProduct.atrust,
    ShuProtocol.easyConnect => SangforProduct.easyConnect,
    ShuProtocol.openVpn => null,
  };

  static ShuProtocol? fromId(String? id) {
    for (final protocol in values) {
      if (protocol.id == id) return protocol;
    }
    return null;
  }
}
