import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection/presets.dart';
import '../connection/protocol.dart';
import '../connection/proxy_listen.dart';
import '../logging/shu_log.dart';

/// Persisted user preferences.
///
/// Loaded once before `runApp` so every screen can read it synchronously and
/// `MaterialApp` can pick the theme on the first frame.
///
/// 数据面有**三条**，各有一个开关：
///
/// | 数据面 | 开关 | 出厂值 |
/// | :--- | :--- | :--- |
/// | 系统 VPN（TUN） | [vpnEnabled] | 安卓上 true |
/// | 本机 SOCKS5 | [socksProxyEnabled] | false |
/// | 本机 HTTP | [httpProxyEnabled] | false |
///
/// 三条互不排斥，但**不代表可以任意组合**：系统 VPN 依赖本机 HTTP 通道
/// （系统代理只认 HTTP），所以它开着时那一半会被强制拉起。
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs) {
    // 把磁盘上的日志设置推给缓冲区。**必须在这里做**：日志设施是个单例，
    // 没有第二个地方能在「任何一行日志产生之前」把阈值装上。
    _syncLog();
  }

  static Future<SettingsStore> load() async =>
      SettingsStore(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  /// Shared with [ConnectionController] so the trust-on-first-use store, the
  /// aTrust device id and the user settings live in one preferences database.
  SharedPreferences get preferences => _prefs;

  static const String _kThemeMode = 'settings.themeMode';
  static const String _kSocksPort = 'settings.socksPort';
  static const String _kSocksListen = 'settings.socksListen';
  static const String _kAutoStartProxy = 'settings.autoStartProxy';
  static const String _kHttpEnabled = 'settings.httpProxyEnabled';
  static const String _kHttpListen = 'settings.httpListen';
  static const String _kHttpPort = 'settings.httpPort';
  static const String _kVpnEnabled = 'settings.vpnEnabled';
  static const String _kVpnMtu = 'settings.vpnMtu';
  static const String _kVpnDns = 'settings.vpnDns';
  static const String _kVpnTcpOverL3 = 'settings.vpnTcpOverL3';
  static const String _kReachabilityTimeout = 'settings.timeoutSeconds';
  static const String _kServer = 'settings.server';
  static const String _kLoginDomain = 'settings.loginDomain';
  static const String _kLogEnabled = 'settings.logEnabled';
  static const String _kLogLevel = 'settings.logLevel';

  /// 「新用户引导走完了没有」。
  ///
  /// 见 [welcomeCompleted]。
  static const String kWelcomeCompletedKey = 'settings.welcomeCompleted';

  /// 协议开关的键前缀，后面接 [ShuProtocol.id]。
  static const String _kProtocolPrefix = 'settings.protocol.';

  /// 本机 SOCKS5 代理的出厂端口。
  ///
  /// 不是 1080 —— 那是「默认 SOCKS 端口」，在安卓上常被其它 VPN / 代理类
  /// 应用抢先监听。2233 是这一套应用自己的取值。
  static const int defaultSocksPort = 2233;

  /// 本机 HTTP 代理的出厂端口。
  ///
  /// 与 [defaultSocksPort] 错开是**硬要求**：两条通道可以同时开着，撞在
  /// 同一个端口上的话第二条会绑不上，而失败发生在「用户刚打开第二个开关」
  /// 的那一刻，表现出来是「开关自己弹回去了」。3322 与 2233 一样，都是这一套
  /// 应用自己的取值。
  static const int defaultHttpPort = 3322;

  /// VPN 接口的出厂 MTU。1400 是移动网络上的保险值（隧道会再套一层封装）。
  static const int defaultVpnMtu = 1400;

  /// 连接超时的出厂值，也是「恢复默认值」写回的那个数。
  static const int defaultTimeoutSeconds = 60;

  // ------------------------------------------------------------- appearance

  ThemeMode get themeMode {
    final raw = _prefs.getString(_kThemeMode);
    return switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  set themeMode(ThemeMode value) => _writeString(_kThemeMode, value.name);

  // ------------------------------------------------------------- onboarding

  /// 新用户引导（`/welcome`）是否已经走完。
  ///
  /// 出厂 **false** —— 全新安装的第一屏就是引导，这一点由路由的重定向保证
  /// （见 `createShuRouter` 的 `redirect`）。老版本升上来的用户不在其中：
  /// 他们已经在用这个应用了，再拦一次「欢迎使用」没有意义，
  /// 所以 `_migrateToV3` 会把这一项直接写成 true。
  ///
  /// 只有**登录成功**才会把它置真。中途退出（VPN 权限没给、登录失败）不写，
  /// 下次冷启动仍在引导里 —— 引导的三个步骤正是「没做完就没法用」的三件事。
  bool get welcomeCompleted => _prefs.getBool(kWelcomeCompletedKey) ?? false;

  set welcomeCompleted(bool value) => _writeBool(kWelcomeCompletedKey, value);

  // ----------------------------------------------------------- connection

  int get socksPort => _prefs.getInt(_kSocksPort) ?? defaultSocksPort;

  set socksPort(int value) => _writeInt(_kSocksPort, value);

  /// 本机 SOCKS5 代理监听在哪张网卡上。
  ///
  /// 默认 [ShuProxyListen.loopback] —— 与 SDK 自己的默认一致，也是唯一
  /// 「不会把校园账号借给同网段陌生人」的取值。
  ///
  /// 磁盘上存的是地址文本（`127.0.0.1` 这种）而不是枚举 id，
  /// [ShuProxyListen.fromStored] 会顺带认下早期版本写过的两个 id。
  ShuProxyListen get socksListen =>
      ShuProxyListen.fromStored(_prefs.getString(_kSocksListen));

  set socksListen(ShuProxyListen value) =>
      _writeString(_kSocksListen, value.address);

  /// 代理碰到**不在网关资源表里**的目标时怎么办。
  ///
  /// **没有这个设置，也没有直连兜底**：所有目标一律走隧道，隧道接不下的
  /// 就是一次明确的失败。理由有二：
  ///
  /// * 学校给的是**整张 IPv4 表**的授权（`1.0.0.0-255.255.255.255/tcp:443`
  ///   这种写法），正常根本没有「表外目标」可掉；
  /// * 一个会私下从底层网络出去的代理，在用户看来与「隧道坏了但还能上网」
  ///   完全一样 —— 那正是最难发现的一类故障。
  ///
  /// 「启用本机 SOCKS5 代理」—— 隧道起来之后要不要把 SOCKS5 拉起来。
  ///
  /// 出厂值 **false**：安卓上默认走系统 VPN（[vpnEnabled]），本机代理是给
  /// 「只想让某几个应用走隧道」的场景准备的。
  bool get socksProxyEnabled => _prefs.getBool(_kAutoStartProxy) ?? false;

  set socksProxyEnabled(bool value) => _writeBool(_kAutoStartProxy, value);

  /// 「启用 HTTP 代理」。
  ///
  /// 与 SOCKS5 分开开关是有必要的：Android 的**系统代理只支持 HTTP**
  /// （`VpnService.Builder.setHttpProxy` 收的就是 HTTP），而 SOCKS5 只能
  /// 由用户自己往应用里填。两个通道对着不同的消费者，混在一个开关里会让
  /// 「我只想让浏览器走隧道」和「我要接管全部应用」变成同一件事。
  ///
  /// 出厂值 **false**。但注意 [vpnEnabled] 为真时这个通道会被**强制拉起**：
  /// 系统 VPN 的 TCP 那一半完全靠它（见 `connection_controller.dart` 的
  /// `startVpn`），那不是偏好，是依赖。
  bool get httpProxyEnabled => _prefs.getBool(_kHttpEnabled) ?? false;

  set httpProxyEnabled(bool value) => _writeBool(_kHttpEnabled, value);

  /// HTTP 代理监听在哪张网卡上。与 [socksListen] 同性质，各存一份：
  /// 两个通道的服务对象不同，监听范围也是两条独立的安全边界。
  ShuProxyListen get httpListen =>
      ShuProxyListen.fromStored(_prefs.getString(_kHttpListen));

  set httpListen(ShuProxyListen value) =>
      _writeString(_kHttpListen, value.address);

  int get httpPort => _prefs.getInt(_kHttpPort) ?? defaultHttpPort;

  set httpPort(int value) => _writeInt(_kHttpPort, value);

  /// 「启用 VPN 服务」—— 用 Android 的 `VpnService` 接管整机流量。
  ///
  /// 出厂值 **安卓上为 true**：这是把隧道真正用起来的那条路（不需要用户
  /// 逐应用配置代理），也是官方客户端的行为。其它平台没有 `VpnService`，
  /// 只能回落到本机代理。
  bool get vpnEnabled {
    final stored = _prefs.getBool(_kVpnEnabled);
    if (stored != null) return stored;
    return defaultTargetPlatform == TargetPlatform.android;
  }

  set vpnEnabled(bool value) => _writeBool(_kVpnEnabled, value);

  /// VPN 接口的 MTU。
  int get vpnMtu => _prefs.getInt(_kVpnMtu) ?? defaultVpnMtu;

  set vpnMtu(int value) => _writeInt(_kVpnMtu, value);

  /// 自定义 DNS；空串表示「用网关下发的那一组」。
  String get vpnDns => _prefs.getString(_kVpnDns) ?? '';

  set vpnDns(String value) => _writeString(_kVpnDns, value);

  /// **实验**：把 TCP 也交给 L3，不依赖本机 HTTP 代理与系统代理。
  ///
  /// 出厂值 **false** —— 它默认关着不是保守，而是因为：
  ///
  /// * 网关把每一条资源的 `enableTCPPrefL3` 都写成了 `false`（意图明确：
  ///   「这个 app 的 TCP 走 TCP 隧道」），本地翻它是在逆着配置走；
  /// * 打开之后 TCP 全部进 TUN，而**系统代理一个字都不设** —— 如果服务端
  ///   不接受 TCP-over-L3，这台设备在连着的时候会彻底没有 TCP 联网能力。
  ///
  /// 它的用途是**验证**一件事：服务端到底接不接受 TCP-over-L3。接受的话，
  /// 整个「系统代理 + HTTP 代理」那一半就可以撤掉（数据面从三条收成一条）；
  /// 不接受的话，`atrust_channel_probe.dart` 会把服务端回的那个 status /
  /// code 原样记进日志。
  bool get vpnTcpOverL3 => _prefs.getBool(_kVpnTcpOverL3) ?? false;

  set vpnTcpOverL3(bool value) => _writeBool(_kVpnTcpOverL3, value);

  /// 一次连接握手的上限。
  ///
  /// 它进的是 `SangforConnectOptions.timeout`，也就是**认证 + 建隧道**整段的
  /// 死线，不是单条 HTTP 请求的超时。所以 60 秒是它的出厂值：上大这条链路
  /// 要走授权码 → reportEnv → 节点探测 → 虚拟 IP 分配，冷启动的第一次接近
  /// 半分钟是常态。
  Duration get timeout => Duration(
    seconds: _prefs.getInt(_kReachabilityTimeout) ?? defaultTimeoutSeconds,
  );

  set timeout(Duration value) =>
      _writeInt(_kReachabilityTimeout, value.inSeconds);

  // ------------------------------------------------------------------ 日志

  /// 「启用日志」。
  ///
  /// 出厂值取 [kDebugMode]：开发版开着（`flutter run` 时问题一发生就能在
  /// 「设置 → 日志」里翻到现场），发布版关着 —— 缓冲区会随每一条日志
  /// `notifyListeners()`，那是一条不该让普通用户付的开销。
  ///
  /// ⚠️ `flutter test` 下 `kDebugMode` 同样为真，所以测试里默认是**开**的。
  bool get logEnabled => _prefs.getBool(_kLogEnabled) ?? kDebugMode;

  set logEnabled(bool value) {
    if (value == logEnabled) return;
    _writeBool(_kLogEnabled, value);
    _syncLog();
  }

  /// 记到哪一档。出厂 [ShuLogLevel.info] —— 只记流程，不记逐跳细节。
  ShuLogLevel get logLevel =>
      ShuLogLevel.fromName(_prefs.getString(_kLogLevel));

  set logLevel(ShuLogLevel value) {
    if (value == logLevel) return;
    _writeString(_kLogLevel, value.label);
    _syncLog();
  }

  /// 把两个设置推给缓冲区。
  ///
  /// 关掉日志时**不清空**已记录的内容：拨开关是「别再长了」，擦掉是
  /// AppBar 上那个按钮的事。
  void _syncLog() =>
      ShuLog.instance.configure(enabled: logEnabled, level: logLevel);

  // --------------------------------------------------------------- 协议

  /// 某个协议是不是被用户打开了。
  ///
  /// ⚠️ **没有实现的东西无论磁盘上存了什么都是关的**（[ShuProtocol.implemented]
  /// 为 false 时直接返回 false）。这条不能省：`implemented` 是代码里的事实，
  /// 而磁盘上的布尔值是历史 —— 先前的版本可能写过一个 `true`，之后那条实现
  /// 被删掉了，那个 `true` 就成了一个指向空气的开关。
  bool isProtocolEnabled(ShuProtocol protocol) {
    if (!protocol.implemented) return false;
    return _prefs.getBool('$_kProtocolPrefix${protocol.id}') ??
        protocol.implemented;
  }

  /// 写入协议开关。没有实现的协议**直接忽略**，不是抛错 ——
  /// 调用方是设置页的开关，而那个开关本来就画成了不可点。
  void setProtocolEnabled(ShuProtocol protocol, bool value) {
    if (!protocol.implemented) return;
    _writeBool('$_kProtocolPrefix${protocol.id}', value);
  }

  /// 被打开的协议，**顺序即 [ShuProtocol.values] 的顺序**。
  ///
  /// 连接页拿它决定「自动切到哪一个」—— 取第一个即可，因为顺序是固定的，
  /// 不会两次打开应用给出两个不同的答案。
  List<ShuProtocol> get enabledProtocols => [
    for (final protocol in ShuProtocol.values)
      if (isProtocolEnabled(protocol)) protocol,
  ];

  /// 当前可用的协议；一个都没开时为 `null`。
  ///
  /// 调用方（连接页）拿到 `null` 时的表现是「三个选项全灰 + 点按钮报无可用
  /// 协议」，而不是「禁止点按钮」—— 后者会让用户不知道为什么点不动。
  ShuProtocol? get firstEnabledProtocol {
    for (final protocol in ShuProtocol.values) {
      if (isProtocolEnabled(protocol)) return protocol;
    }
    return null;
  }

  // -------------------------------------------------------------- server

  /// The gateway the user last pointed the app at.
  ///
  /// 默认值就是唯一那台网关（[ShuEndpoint.host]）—— 它不是一个「空着待填」
  /// 的字段，而是一个**已经填好、可以改**的字段。设置页上写着当前值，
  /// 用户不需要先去别处找一个地址回来填。
  String get server => _prefs.getString(_kServer) ?? ShuEndpoint.host;

  set server(String value) => _writeString(_kServer, value);

  /// aTrust 的 `loginDomain`（`sfDomain`）。
  ///
  /// 出厂值来自网关 `authConfig` 里实测到的那一个（[ShuEndpoint.loginDomain]）。
  /// 它与服务器地址同性质：填好了、可以改，不是必填的空格。
  String get loginDomain =>
      _prefs.getString(_kLoginDomain) ?? ShuEndpoint.loginDomain;

  set loginDomain(String value) => _writeString(_kLoginDomain, value);

  /// 把协议相关的设置恢复出厂值。
  ///
  /// 「恢复」在这里是**删键**而不是写一份常量进去：出厂值本来就是「读不到时
  /// 用哪个」，把它写进磁盘只会让「用户没改过」和「用户改成了恰好等于出厂值」
  /// 从此分不清。
  ///
  /// 它**只碰协议那几项**（服务器 / 登录域 / 握手超时 / 协议开关）。
  /// 本机代理与 VPN 的设置不在这里 —— 那个按钮长在「aTrust 协议」页上，
  /// 拨一下把整机 VPN 关掉不属于它管的事。日志设置同理。
  Future<void> restoreConnectionDefaults() async {
    await _prefs.remove(_kServer);
    await _prefs.remove(_kLoginDomain);
    await _prefs.remove(_kReachabilityTimeout);
    for (final protocol in ShuProtocol.values) {
      await _prefs.remove('$_kProtocolPrefix${protocol.id}');
    }
    notifyListeners();
  }

  // ------------------------------------------------------------- internals

  void _writeString(String key, String value) {
    unawaited(_prefs.setString(key, value));
    notifyListeners();
  }

  void _writeBool(String key, bool value) {
    unawaited(_prefs.setBool(key, value));
    notifyListeners();
  }

  void _writeInt(String key, int value) {
    unawaited(_prefs.setInt(key, value));
    notifyListeners();
  }
}
