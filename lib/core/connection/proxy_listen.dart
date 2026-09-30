import 'dart:io';

/// 本机 SOCKS5 代理**监听在哪张网卡上**。
///
/// 这不是「代理模式」那种偏好，而是一条**安全边界**：
///
/// | 地址 | 谁能连上这个代理 |
/// | :--- | :--- |
/// | `127.0.0.1` | 只有这台手机上的应用 |
/// | `0.0.0.0` | 同一网络里**任何一台设备** |
/// | `192.168.x.y` | 只有那个网段里的设备 |
///
/// 隧道是「以你的身份进校园网」的东西，把入口开给同网段的陌生人等于把校园
/// 账号借出去，所以任何非 loopback 的取值都要在界面上过一道确认 ——
/// 这一项不像端口号那样「填错了也能用」。
///
/// ## 为什么是自由填写而不是两个预设
///
/// 只有「仅本机 / 所有网卡」两项时，想让**某一张网卡**上的设备连进来
/// （比如只放行 USB 网络共享出来的那一台，而不放行整个 Wi-Fi）就没有办法
/// 表达。而 `SangforSocks5Server.listenAddress` 收的就是一个
/// [InternetAddress]，「绑哪一张网卡」本来就是它最直接的一个参数。
/// 所以这里放开成字面地址，只保留一条底线：**必须是一个能解析的 IP
/// 字面量**（不接受主机名 —— 那需要一次 DNS 查询，而绑定发生在代理启动
/// 的那条路径上）。
///
/// 两个预设仍然保留成常量：它们是用户最常用的两个值，界面上直接给出来
/// 比让人手打一遍好。它们也是 `test/` 与界面之外唯一需要认识的名字。
class ShuProxyListen {
  const ShuProxyListen._(this.address);

  /// 只监听回环 —— 出厂值，也是唯一不需要确认的取值。
  static const ShuProxyListen loopback = ShuProxyListen._('127.0.0.1');

  /// 监听所有网卡（IPv4）。
  static const ShuProxyListen anyNetwork = ShuProxyListen._('0.0.0.0');

  /// 监听所有网卡（IPv6）。
  static const ShuProxyListen anyNetworkV6 = ShuProxyListen._('::');

  /// 用户填的地址文本。
  ///
  /// 存进磁盘的也是它（而不是一个枚举 id）：地址本身就是设置的内容，
  /// 多一层 id 映射只会让「磁盘上的旧值」与「现在的取值」容易分叉。
  final String address;

  /// 绑定所有网卡吗。
  bool get allInterfaces =>
      address == anyNetwork.address || address == anyNetworkV6.address;

  bool get isLoopback => address == loopback.address;

  /// 这个取值会把代理暴露给本机之外的东西。
  ///
  /// 界面拿它决定「要不要弹确认框」：`127.0.0.1` 之外的**每一个**取值都要，
  /// 因为任何一个非回环地址都意味着别的设备能连上。
  bool get exposesToNetwork => !isLoopback;

  /// 交给 `SangforSocks5Server.listenAddress` 的取值。
  ///
  /// [parse] / [fromStored] 保证了 [address] 一定是能解析的字面量，所以
  /// 这里的兜底分支正常走不到；留着它是为了「一个坏值不该让代理起不来」——
  /// 回退到最保守的回环比回退到 `0.0.0.0` 安全。
  InternetAddress get internetAddress =>
      InternetAddress.tryParse(address) ?? InternetAddress.loopbackIPv4;

  /// 设置行上显示的名字。
  ///
  /// 非预设的地址直接显示地址本身：那时「这是哪一台机器」正是用户唯一想
  /// 确认的事，再起一个名字反而把它挡住了。
  String get label => switch (address) {
    '127.0.0.1' => '仅本机',
    '0.0.0.0' => '所有网卡',
    '::' => '所有网卡 (IPv6)',
    _ => address,
  };

  /// 设置行上的完整取值：名字 + 地址，两个都要有。
  ///
  /// 只写名字（「仅本机」）看不出它其实是 `127.0.0.1`；只写地址又要在
  /// 「`0.0.0.0` 是什么」上想一下。这一行是用户确认「现在到底绑在哪」的
  /// 唯一地方，所以两个都给。
  String get display =>
      isLoopback || allInterfaces ? '$label · $address' : address;

  /// 解析用户填的文本。不是能绑定的字面地址时返回 `null`。
  ///
  /// 只认 IP 字面量，不认主机名：主机名要过一次 DNS，而绑定地址必须在
  /// 监听建立之前就定下来。
  static ShuProxyListen? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parsed = InternetAddress.tryParse(text);
    if (parsed == null) return null;
    // 存 `InternetAddress` 认下的那一份而不是用户输入的原样：两者可能差
    // 一个首尾空格之类的东西，而磁盘上的值必须与真正拿去绑定的那一个
    // 逐字符一致，否则界面上显示的和实际绑定的会对不上。
    return ShuProxyListen._(parsed.address);
  }

  /// 从磁盘读回来。
  ///
  /// 认不出时退回 [loopback]，不是「把坏值当默认放行」—— 这是白名单语义：
  /// 读不懂的取值一律按最保守的算。
  ///
  /// 同时兼容两个历史 id（`loopback` / `any`）：早期版本存的是枚举 id，
  /// 那份数据还在用户手机上。
  static ShuProxyListen fromStored(String? raw) => switch (raw) {
    'loopback' => loopback,
    'any' => anyNetwork,
    _ => parse(raw ?? '') ?? loopback,
  };

  @override
  bool operator ==(Object other) =>
      other is ShuProxyListen && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => 'ShuProxyListen($address)';
}
