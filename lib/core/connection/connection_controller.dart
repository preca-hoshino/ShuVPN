import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';
import 'package:flutter_sangfor_easy_connect/flutter_sangfor_easy_connect.dart';

import '../../app/app_info.dart';
import '../auth/atrust_device_id.dart';
import '../auth/atrust_sso_login.dart';
import '../auth/auth_constants.dart';
import '../auth/auth_session.dart';
import '../logging/shu_log.dart';
import '../settings/settings_store.dart';
import 'atrust_channel_probe.dart';
import 'protocol.dart';
import 'proxy_listen.dart';
import 'shu_android_vpn.dart';
import 'shu_http_proxy.dart';
import 'shu_traffic.dart';
import 'vpn_packet_log.dart';
import 'vpn_permission.dart';
import 'vpn_routes.dart';

/// Asks the user for an interactive code (SMS / TOTP).
///
/// Injected by the shell so the controller never has to touch `BuildContext`.
typedef ChallengePrompt = Future<String> Function(String title, String message);

/// What the button will connect to.
///
/// There is no username or password here on purpose: the aTrust gateway on this
/// campus authenticates through the unified-identity provider, so credentials
/// live in the account layer and never touch the connection draft.
///
/// 三次信息都是**从 [SettingsStore] 带过来的快照**，不是另一份真值：
/// `_onSettingsChanged` 会在设置页改完的同一帧把它们重新灌进来。
/// 这样保留 `draft` 的意义就只剩一个 —— 日志与提示里要说「刚才连的是什么」
/// 时不必把 `SettingsStore` 传得到处都是。
@immutable
class ConnectionDraft {
  const ConnectionDraft({
    this.protocol = ShuProtocol.atrust,
    this.server = '',
    this.loginDomain = '',
  });

  /// 用户选中的协议。
  ///
  /// 是应用自己的 [ShuProtocol] 而不是 SDK 的 `SangforProduct`：
  /// OpenVPN 在 SDK 里根本没有对应项，而连接页要能把它作为一个『关掉的
  /// 选项』显示出来。
  final ShuProtocol protocol;

  final String server;
  final String loginDomain;

  ConnectionDraft copyWith({
    ShuProtocol? protocol,
    String? server,
    String? loginDomain,
  }) => ConnectionDraft(
    protocol: protocol ?? this.protocol,
    server: server ?? this.server,
    loginDomain: loginDomain ?? this.loginDomain,
  );

  /// Nothing to fill in any more beyond a host.
  bool get isComplete => server.trim().isNotEmpty;
}

/// Owns the whole connection lifetime: the connector, the tunnel dialer, the
/// userspace SOCKS5 frontend and the trust-on-first-use store.
///
/// Everything the UI knows about the connection comes from here, which is why
/// the orb, the dock and the settings row can never disagree.
///
/// 日志**不在这里** —— 它已经搬到 `lib/core/logging/shu_log.dart`。原先的
/// 一份私有缓冲区只能装这一层自己的输出，而真正需要排障的现场一半在
/// `lib/core/auth/` 里（登录、凭据交换、教务解析），那些地方连
/// `BuildContext` 都没有。现在全应用写同一份。
class ConnectionController extends ChangeNotifier {
  ConnectionController(
    this._settings, {
    ConnectionDraft? draft,
    ShuVpnPermission? vpnPermission,
  }) : _vpnPermission = vpnPermission ?? const ShuVpnPermission(),
       _draft = draft ?? _draftFrom(_settings) {
    // 设置页改完协议开关或服务器地址之后，这一层要立刻知道 ——
    // 「关掉当前协议 → 自动切到另一个可用的」就发生在这个回调里。
    _settings.addListener(_onSettingsChanged);
  }

  final SettingsStore _settings;

  /// 系统 VPN 授权那一层。默认打给原生；测试换掉它（见 `ShuVpnPermission`）。
  final ShuVpnPermission _vpnPermission;

  /// 从设置里拼出初始草稿。
  static ConnectionDraft _draftFrom(SettingsStore settings) => ConnectionDraft(
    protocol: settings.firstEnabledProtocol ?? ShuProtocol.atrust,
    server: settings.server,
    loginDomain: settings.loginDomain,
  );

  /// 设置变了：把三项快照重新灌进草稿，并把关掉的协议换掉。
  ///
  /// 为什么要在这里处理而不是留给 UI：连接页的协议选择条、设置页的开关、
  /// 球下面那行状态，三处都要说「现在连的是谁」。把这个判断放在一处，
  /// 三者才不会各算一遍、算出三个答案。
  void _onSettingsChanged() {
    var protocol = _draft.protocol;
    if (!_settings.isProtocolEnabled(protocol)) {
      // 一个都没开时 `firstEnabledProtocol` 是 null，那就保留原选择不动 ——
      // 页面上三个选项会全部置灰，保留选中项比清空更能说明「本来选的是它」。
      protocol = _settings.firstEnabledProtocol ?? protocol;
    }
    final next = ConnectionDraft(
      protocol: protocol,
      server: _settings.server,
      loginDomain: _settings.loginDomain,
    );
    if (next.protocol == _draft.protocol &&
        next.server == _draft.server &&
        next.loginDomain == _draft.loginDomain) {
      return;
    }
    _draft = next;
    notifyListeners();
  }

  /// Set by the shell; required for SMS / TOTP challenges.
  ChallengePrompt? challengePrompt;

  /// Supplies the live unified-identity session for the aTrust OAuth path.
  ///
  /// Set by the shell from the account center. Returning `null` (or a session
  /// without `SHU_OAUTH2`) is what produces the “先去账号管理登录” error, so the
  /// controller never has to know how the account page is organised.
  ShuAuthSession? Function()? ssoSessionProvider;

  // ------------------------------------------------------------------ draft

  ConnectionDraft _draft;
  ConnectionDraft get draft => _draft;

  /// 当前选中的协议是不是真的可以连。
  ///
  /// 连接页在点球之前看它一眼：为 false 时不再往下走，改为弹一条提示。
  bool get hasEnabledProtocol => _settings.isProtocolEnabled(_draft.protocol);

  /// 用户在选择条上换了一个协议。
  ///
  /// 关掉的协议**静默忽略**（选择条上那一段本来就不可点）；
  /// 这样即使某条路径把一个禁用项递进来，也不会真的切换过去。
  void selectProtocol(ShuProtocol protocol) {
    if (!_settings.isProtocolEnabled(protocol)) return;
    if (protocol == _draft.protocol) return;
    _draft = _draft.copyWith(protocol: protocol);
    notifyListeners();
  }

  // ------------------------------------------------------------- live state

  SangforConnectionState _state = SangforConnectionState.disconnected;
  SangforConnectionState get state => _state;

  bool _busy = false;

  /// True while an operation is in flight; disables the orb and the settings
  /// that would race it.
  bool get busy => _busy;

  SangforErrorCode? _errorCode;
  String? _errorMessage;

  SangforErrorCode? get errorCode => _errorCode;

  /// 失败原因，**直接给用户看**。
  ///
  /// 界面只拿这一个字符串，不把 `SangforErrorCode` 拼进去：`certificateMismatch:
  /// 证书指纹不匹配` 这种写法是给人翻日志的，不是给人读的。枚举名在日志里
  /// （`ShuLog.e('conn', '[$code] $message')`），而日志在设置 → 日志里能翻到。
  String? get errorMessage => _errorMessage;

  String? _virtualAddress;
  String? get virtualAddress => _virtualAddress;

  List<String> _dnsServers = const <String>[];
  List<String> get dnsServers => _dnsServers;

  DateTime? _connectedAt;
  DateTime? get connectedAt => _connectedAt;

  bool get tunnelUp => _dialer != null;

  /// 本机 SOCKS5 代理是否在跑。
  bool get socksProxyRunning => _socks5 != null;

  /// 本机 HTTP 代理是否在跑。
  bool get httpProxyRunning => _httpProxy != null;

  /// 两个本机代理里只要有任意一个在跑就是 true。
  ///
  /// 界面用它决定「复制地址」这类行要不要置灰 —— 两个通道的服务对象不同，
  /// 只跑其中一个也是正常状态。
  bool get proxyRunning => socksProxyRunning || httpProxyRunning;

  /// 系统 VPN（Android `VpnService`）是否在跑。
  bool get vpnRunning => _vpnDevice != null;

  /// `VpnService` 的授权状态；`null` = 还没问过系统。
  bool? get vpnPrepared => _vpnPrepared;

  /// 这台设备有没有「系统 VPN 授权」这回事 —— 只有 Android 有。
  ///
  /// 界面据此决定要不要摆出那一行、以及要不要把「未授权」说成「不支持」。
  /// 由 [ConnectionController] 转述而不是让各处自己看 `Platform`：真正要去
  /// 调原生的就是这一层，两边各判一次迟早会不一样。
  bool get vpnSupported => _vpnPermission.isSupported;

  int? _boundSocksPort;

  /// 代理**实际绑定**的那个地址；没在跑时为 `null`。
  ///
  /// 它和 [_boundSocksPort] 是同一件事的两半，也为了同一个理由存在：设置
  /// 可能在代理跑着的时候被改掉，而**绑定已经发生了** —— 这时候界面该说
  /// 的是「现在实际绑在哪」，不是「设置里写着什么」。之前这两个值都直接
  /// 取自设置（地址甚至是写死的 `127.0.0.1`），于是改成监听所有网卡之后
  /// 页面上依然显示 `127.0.0.1`，抄出去的那个地址根本连不上。
  ShuProxyListen? _boundSocksListen;

  /// 绑定所有网卡时，拿哪个地址去告诉用户「让别的设备连这个」。
  ///
  /// `0.0.0.0` 不是一个能连上去的地址，它是「所有网卡」这个意图的写法。
  /// 别人要填的是这台机器在某张网卡上的真实地址，所以启动监听时顺手查一次
  /// 本机的非回环 IPv4 并存下来 —— 换 Wi-Fi 之后重启代理就会拿到新的那个，
  /// 而不是一直留着上一次的。
  String? _advertisedHost;

  /// The port actually served right now, falling back to the configured one.
  int get socksPort => _boundSocksPort ?? _settings.socksPort;

  /// 现在实际监听在哪。代理没在跑时就是设置里那一个 —— 界面在两种状态下
  /// 都要有东西可显示。
  ShuProxyListen get socksListen => _boundSocksListen ?? _settings.socksListen;

  /// 需要抄给别的应用 / 别的设备的那一串 `地址:端口`。
  ///
  /// 两处都不再写死：地址跟着 [socksListen] 走，端口跟着真正绑上的那个走。
  String get proxyAddress => '${_bindHost(socksListen)}:$socksPort';

  int? _boundHttpPort;

  /// HTTP 通道实际绑定的监听地址。
  ///
  /// 与 [_boundSocksListen] 分开存：两个通道各有一个监听地址设置，
  /// 「现在到底绑在哪」必须按各自的那一份回答。
  ShuProxyListen? _boundHttpListen;

  /// HTTP 通道现在实际监听的端口；没在跑时为 `null`。
  ///
  /// 它同时是 `VpnService.Builder.setHttpProxy` 要填的那个值，所以必须
  /// 是**实际绑定**的结果而不是设置里的数字 —— 端口被占时会退到系统
  /// 随便给一个，而系统代理只能指向真的在听的那个。
  int? get httpPort => _boundHttpPort;

  /// 现在实际监听的 HTTP 地址。代理没在跑时就是设置里那一个。
  ShuProxyListen get httpListen => _boundHttpListen ?? _settings.httpListen;

  /// 给系统代理 / 给用户看的 HTTP 地址；没在跑时为 `null`。
  String? get httpProxyAddress {
    final port = _boundHttpPort;
    final listen = _boundHttpListen;
    if (port == null || listen == null) return null;
    return '${_bindHost(listen)}:$port';
  }

  /// 与 [proxyAddress] 同形的那一串，给 HTTP 通道用。
  ///
  /// 与 [httpProxyAddress] 的分工：那个**只在真的在听时非空**（它的用途是
  /// 交给 `setHttpProxy`，只能填真实绑定的端口），而这一条任何时候都有值 ——
  /// 抽屉里那一行讲的是「这一路怎么连」，还没连上时照着设置里那个值写。
  String get httpListenAddress =>
      '${_bindHost(httpListen)}:${_boundHttpPort ?? _settings.httpPort}';

  /// 交给 `VpnService.Builder.setHttpProxy` 的主机部分。
  ///
  /// 系统代理把它填给所有应用，那些应用是在**本机**发起连接的，所以能用
  /// `127.0.0.1` 就必须用 `127.0.0.1`。只有把监听地址限定在某一张具名网卡上
  /// （既不包含回环、也不是通配地址）时，回环才真的没人监听 —— 那种配置下
  /// 只能填那个具名地址，并且要在日志里说一句。
  String get _systemProxyHost {
    final listen = _boundHttpListen;
    if (listen == null || listen.allInterfaces || listen.isLoopback) {
      return '127.0.0.1';
    }
    return listen.address;
  }

  /// 展示用的主机部分。
  String _bindHost(ShuProxyListen listen) {
    if (!listen.allInterfaces) return listen.address;
    // 查不到就照实写 `0.0.0.0` —— 它虽然连不上，但「所有网卡」这个含义
    // 是准确的；随便挑一个地址假装是它反而会引人去排查那个地址。
    return _advertisedHost ?? listen.address;
  }

  // -------------------------------------------------------------- 代理的账

  /// 目标不在网关资源表内、被拒的次数。
  int _proxyUnroutedCount = 0;

  /// 命中资源、隧道却**握手失败**的次数。
  ///
  /// 这是最坏的一种状态：判定说这条归网关管，而隧道那边又建不起来 ——
  /// 结果是一个能连上的网络里每一页都打不开。这个数字不为零就说明问题在
  /// 隧道那一侧，不在分流判定上。
  int _proxyTunnelFailures = 0;

  /// 已经记过日志的目标。
  ///
  /// 一个页面能带出几十个外部请求（统计、字体、CDN），逐条记会把缓冲区
  /// 冲干净；而排障时真正想知道的是「哪几个目标进不去」，所以每个目标
  /// 只说一次，次数由计数器汇总。
  final Set<String> _proxyUnroutedHosts = <String>{};

  /// 不在资源表内而被拒的目标次数。
  int get proxyUnroutedCount => _proxyUnroutedCount;

  /// 命中资源但隧道握手失败的次数。见 [_proxyTunnelFailures]。
  int get proxyTunnelFailureCount => _proxyTunnelFailures;

  /// 出现过的、进不去隧道的目标数（去重）。
  int get proxyUnroutedHostCount => _proxyUnroutedHosts.length;

  // --------------------------------------------------------- 流量与实时速率

  /// 代理这一侧的字节账本。系统 VPN 那一侧的账在 `_vpnObserver` 上。
  ///
  /// 两条不会重复计数：交给 TUN 的只有 UDP 网段，TCP 全部走代理。
  final ShuTrafficMeter _meter = ShuTrafficMeter();

  /// 每秒采一次速率的定时器。隧道建立之后才开，拆掉就停 —— 一个不在
  /// 连接中的设备不该每秒醒一次。
  Timer? _statsTimer;
  int _statsUpBytes = 0;
  int _statsDownBytes = 0;
  double _uploadRate = 0;
  double _downloadRate = 0;

  /// 上行速率（字节 / 秒）。
  double get uploadBytesPerSecond => _uploadRate;

  /// 下行速率（字节 / 秒）。
  double get downloadBytesPerSecond => _downloadRate;

  /// 隧道 TCP 建连耗时的滑动平均（毫秒）；还没有样本时为 `null`。
  ///
  /// 这个数是**用户能感知的那一段**：从代理收到请求到隧道里那条 TCP 通道
  /// 建好，包含 TLS、握手、服务端返回连接回复。它比 ping 网关更接近
  /// 「打开一个网页要等多久」。
  double? get latencyMs => _meter.latencyMs;

  /// 两个数据面加起来的上行字节（应用 → 隧道）。
  int get trafficUpBytes => (_vpnObserver?.egressBytes ?? 0) + _meter.upBytes;

  /// 两个数据面加起来的下载字节（隧道 → 应用）。
  int get trafficDownBytes =>
      (_vpnObserver?.ingressBytes ?? 0) + _meter.downBytes;

  /// 建立过的连接总数：TUN 上的流数 + 代理上的连接数。
  int get trafficConnections =>
      (_vpnObserver?.flowsSeen ?? 0) + _meter.connectionsOpened;

  // -------------------------------------------------------------- internals

  SangforConnector? _connector;
  SangforTcpDialer? _dialer;
  SangforSocks5Server? _socks5;

  /// 与 SOCKS5 并列的那条 HTTP 通道。
  ///
  /// 它不是可选项：Android 的系统代理（包括 `VpnService.Builder.setHttpProxy`）
  /// **只支持 HTTP**，把应用指向一个 SOCKS5 端口的结果就是永远没有连接进来。
  /// 两者共用同一个 dialer，见 `shu_http_proxy.dart`。
  ShuHttpProxy? _httpProxy;
  SangforCancellationToken? _loginToken;
  SangforCancellationToken? _proxyToken;
  SangforCancellationToken? _httpToken;

  // ------------------------------------------------------------------- VPN

  /// 当前跑着的系统 VPN 接口。
  ///
  /// 类型是 [ShuAndroidVpnDevice]（本项目的实现）而**不是**依赖包的
  /// `AndroidVpnDevice`：后者丢掉 `0.0.0.0/0` 那条路由，界面会显示「已启动」
  /// 而实际什么也劫持不到。详见 `shu_android_vpn.dart`。
  ShuAndroidVpnDevice? _vpnDevice;
  SangforTunnelRouter? _vpnRouter;
  SangforCancellationToken? _vpnToken;
  StreamSubscription<void>? _vpnDisconnectSub;
  bool? _vpnPrepared;

  /// 交给系统的路由表（就是网关资源表展开后的网段）。
  List<String> _vpnTunnelRoutes = const <String>[];

  /// 数据面的逐包观测器：每一个包去了哪、结果如何都在它那里记账。
  ///
  /// 它包在隧道外面（[_TunnelPacketAdapter]），而**不是**挂在
  /// `SangforTunnelRouter` 的 `egressFilter` 上：过滤器只能看到「包进来了」，
  /// 看不到 `sendPacket` 的真实返回值 —— 而那个返回值正是「结果」。
  ShuPacketObserver? _vpnObserver;

  /// 当前交给系统 VPN 的网段。空表表示 VPN 没在跑。
  ///
  /// 它同时是「VPN 有没有真的接管东西」的答案：系统只会把落在这张表里的
  /// 流量送进 TUN，表是空的就等于什么都没接管。
  List<String> get vpnTunnelRoutes => _vpnTunnelRoutes;

  int get vpnRouteCount => _vpnTunnelRoutes.length;

  /// 进过 TUN 的包（上行：应用 → 隧道）。
  int get vpnEgressPackets => _vpnObserver?.egressPackets ?? 0;

  /// 出过 TUN 的包（下行：隧道 → 应用）。
  int get vpnIngressPackets => _vpnObserver?.ingressPackets ?? 0;

  /// 上行 / 下行的字节数。
  int get vpnEgressBytes => _vpnObserver?.egressBytes ?? 0;

  int get vpnIngressBytes => _vpnObserver?.ingressBytes ?? 0;

  /// 上行包里，目的地址**不在网关资源表内**（或命中了资源但 TCP 走不了 L3）、
  /// 因此会被隧道丢弃的数量。
  ///
  /// 这个数字不为零就说明有人在访问资源之外的东西 —— 那些流量本该走
  /// 底层网络，出现在这里意味着路由表把范围放得太宽了。
  int get vpnUnroutablePackets => _vpnObserver?.unroutablePackets ?? 0;

  /// 命中了资源却仍然没发出去的包数。见 [ShuPacketObserver.failedPackets]。
  int get vpnFailedPackets => _vpnObserver?.failedPackets ?? 0;

  /// 建立过的流数。
  int get vpnFlowCount => _vpnObserver?.flowsSeen ?? 0;

  /// 走进 TUN 的 IPv6 包数。
  ///
  /// **正常永远是 0**：原生侧会把没接管的地址族放行，那一族的流量在进 TUN
  /// 之前就走了底层网络。非零就说明地址族那件事没配对 —— 而它曾经把
  /// 「VPN 开着却一个包都不进 TUN」藏了很久。
  int get vpnIpv6Packets => _vpnObserver?.ipv6Packets ?? 0;

  SettingsStore get settings => _settings;

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _stopStats();
    _loginToken?.cancel('controller disposed');
    _proxyToken?.cancel('controller disposed');
    _httpToken?.cancel('controller disposed');
    _vpnToken?.cancel('controller disposed');
    unawaited(_socks5?.close().catchError((Object _) {}));
    unawaited(_httpProxy?.close().catchError((Object _) {}));
    unawaited(_vpnRouter?.stop().catchError((Object _) {}));
    unawaited(_vpnDevice?.close().catchError((Object _) {}));
    unawaited(_vpnDisconnectSub?.cancel());
    _socks5 = null;
    _httpProxy = null;
    _boundHttpPort = null;
    _boundHttpListen = null;
    _vpnRouter = null;
    _vpnDevice = null;
    _connector = null;
    super.dispose();
  }

  // ------------------------------------------------------------- TOFU store

  String _tofuKey(String host) => 'tofu_sha256_$host';

  /// Trust-on-first-use certificate validation for Easy Connect data channels.
  ///
  /// The connector fails closed: without a validator (or an explicit
  /// `allowUnverifiedCertificates`) it refuses to open a data channel. The
  /// first certificate seen for a host is pinned by SHA-256 and every later
  /// connection must present the same one.
  bool _trustCertificate(String host, Uint8List certificateDer) {
    final prefs = _settings.preferences;
    final fingerprint = sha256.convert(certificateDer).toString();
    final pinned = prefs.getString(_tofuKey(host));

    if (pinned == null) {
      unawaited(prefs.setString(_tofuKey(host), fingerprint));
      ShuLog.i(ShuLogTag.conn, 'TOFU 首次见到 $host · 已固定证书 SHA-256 $fingerprint');
      return true;
    }
    if (pinned == fingerprint) {
      ShuLog.d(ShuLogTag.conn, 'TOFU $host 证书指纹匹配');
      return true;
    }
    ShuLog.e(
      ShuLogTag.conn,
      // 续行的缩进由 [ShuLogRecord.formatLines] 补，这里不要自己加空格 ——
      // 自己加一遍会让两份缩进叠起来。
      'TOFU $host 证书指纹不匹配\n'
      '已固定: $pinned\n'
      '本次:   $fingerprint',
    );
    return false;
  }

  int get pinnedCertificateCount => _settings.preferences
      .getKeys()
      .where((key) => key.startsWith('tofu_sha256_'))
      .length;

  /// Clears every pinned fingerprint so the next connection trusts again.
  Future<int> resetPinnedCertificates() async {
    final prefs = _settings.preferences;
    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith('tofu_sha256_'))
        .toList(growable: false);
    for (final key in keys) {
      await prefs.remove(key);
    }
    ShuLog.i(ShuLogTag.conn, '已清除 ${keys.length} 条证书固定记录 · 下次连接将重新信任');
    return keys.length;
  }

  // ------------------------------------------------------------- device id

  /// Returns the persisted aTrust device id, generating one on first use.
  ///
  /// aTrust binds a session to a device id, so it must survive restarts. The
  /// account layer reports the same value in `reportEnv`, so both sides share
  /// one definition (`ShuATrustDeviceId`) instead of generating two.
  String _deviceId() => ShuATrustDeviceId(_settings.preferences).value;

  // --------------------------------------------------------------- helpers

  Uri _serverUri(String raw) {
    var text = raw.trim();
    if (text.isEmpty) {
      throw const SangforException(
        SangforErrorCode.invalidOptions,
        '服务器地址不能为空',
      );
    }
    if (!text.contains('://')) text = 'https://$text';

    final parsed = Uri.tryParse(text);
    if (parsed == null || parsed.host.isEmpty) {
      throw SangforException(SangforErrorCode.invalidOptions, '服务器地址无法解析：$raw');
    }
    // The Sangfor control plane is HTTPS-only; silently upgrading is friendlier
    // than failing, and the handshake would fail anyway.
    return parsed.scheme == 'https' ? parsed : parsed.replace(scheme: 'https');
  }

  Future<String> _prompt(String title, String message) {
    final prompt = challengePrompt;
    if (prompt == null) {
      throw const SangforException(
        SangforErrorCode.mfaRequired,
        '当前上下文无法弹出验证码输入框',
      );
    }
    return prompt(title, message);
  }

  SangforConnector _buildConnector(Uri server, ShuProtocol protocol) {
    switch (protocol) {
      // EasyConnect 在界面上是被封住的那一个，但核心仍在包里，这个分支就是
      // 「要接上只需把设置里那个开关解封」的那一处。
      case ShuProtocol.easyConnect:
        return EasyConnectConnector(
          loginSession: EasyConnectLoginSession(),
          smsCodeProvider: () => _prompt('短信验证码', '服务器要求短信验证码'),
          totpCodeProvider: () => _prompt('动态口令', '请输入 TOTP 动态口令'),
          certificateValidator: (der) => _trustCertificate(server.host, der),
        );

      case ShuProtocol.atrust:
        // 上大的 aTrust 网关把统一身份认证当作外部 IdP（`auth/httpsOauth2`），
        // 账号密码是交给 newsso 而不是直传网关的。因此这条链路必须带上一个
        // 已登录的 SSO 会话；没有就走不到底，提前说清楚而不是弹个密码框。
        final session = ssoSessionProvider?.call();
        if (session == null || !session.hasSession) {
          throw const SangforException(
            SangforErrorCode.authenticationFailed,
            'aTrust 需要通过上海大学统一身份认证登录，请先在「账号管理」里登录',
          );
        }
        // 复用账号层已经登录过的 aTrust 链路：它持有网关的全部 Cookie 与
        // csrf token，`signIn` 会直接命中 `isLogin == 1` —— 既不会重复
        // 登录，也不会因为流程不同而与账号层产生设备不一致。
        return ATrustConnector(
          loginSession: ATrustSSOLoginSession(chain: session.atrustChain),
          // 给隧道 TLS 通道穿一层字节记录。它不改行为，只是把「握手时服务端
          // 到底回了什么」留下来 —— 没有它，TCP 隧道握手失败就只剩一句
          // `channel closed during TCP tunnel handshake`，无从下手。
          // 见 `atrust_channel_probe.dart`。
          socketFactory: shuProbedSocketFactory(),
          smsCodeProvider: (step) => _prompt(
            '短信验证码',
            'aTrust 要求完成 ${step.rawService ?? step.service.name} 验证',
          ),
          totpCodeProvider: (step) => _prompt(
            '动态口令',
            'aTrust 要求完成 ${step.rawService ?? step.service.name} 验证',
          ),
        );

      case ShuProtocol.openVpn:
        // 兜底。设置里那个开关本来就被封住了，正常走不到这里 ——
        // 留一条明确的错总好过一个「什么都不发生」。
        throw const SangforException(
          SangforErrorCode.unsupported,
          'OpenVPN 协议栈在本应用中尚未接入',
        );
    }
  }

  /// Exposes the connector's tunnel dialer as a SOCKS5 dialer.
  SangforTcpDialer _dialerFor(SangforConnector connector) {
    if (connector is EasyConnectConnector) return connector.dialTcp;
    if (connector is ATrustConnector) {
      // ⚠️ 这里**绕过了** `ATrustConnector.dialTcp`，直接调隧道那一层。
      //
      // 原因是那个方法把 `includeL3Preferred` 丢掉了：它只转发
      // `resolvedIp` / `zeroRtt`（`flutter_sangfor_atrust.dart:86`），
      // 于是网关标记为「L3 优先」的资源全部匹配不到，`ATrustTunnel.dialTcp`
      // 直接抛 `no TCP tunnel resource for host:port` —— 一个连不上的站点
      // 看起来与「网关没给你开权限」完全一样，排障时无从下手。
      //
      // `ATrustTcpTunnelStream` 是公开类型，所以自己包一下就行。
      // 这不是新增能力，只是把 SDK 默认关着的那一半资源打开。
      return (host, port) => _dialATrust(connector, host, port);
    }
    throw SangforException(
      SangforErrorCode.unsupported,
      '连接器 ${connector.runtimeType} 不提供 dialTcp',
    );
  }

  /// aTrust 的 TCP 拨号：**命中资源走隧道，资源外按设置直连**。
  ///
  /// ## 为什么必须先自己判一次
  ///
  /// `ATrustTunnel.dialTcp` 碰到资源表外的目标是抛
  /// `StateException('no TCP tunnel resource for host:port')` —— 一句只有
  /// 看过 SDK 源码才知道在说什么的话。而 SOCKS5 只有 CONNECT 一种请求，
  /// 没有「这一条别走代理」的表达方式：把浏览器指向一个只会转发校内资源的
  /// 代理，除了校内站点以外**所有**页面都会连不上，日志里刷满同一句话却
  /// 看不出「这不是故障，是这个目标本来就不归网关管」。
  ///
  /// 所以判定放在前面，用的是 SDK 自己的 [shuProxyRouteFor]（`dialTcp`
  /// 内部用的就是同一个调用），两边不可能出现「预检说能连、隧道说不能连」。
  ///
  /// ## 直连兜底与 VPN 的分流是一回事
  ///
  /// 系统 VPN 那条数据面里，资源外的流量本来就留在底层网络 —— 直连兜底只是
  /// 让代理这一条行为一致。关掉它（[SettingsStore.proxyDirectFallback]）
  /// 就只剩「校内可达」，那些包会被拦下并计数。
  Future<SangforTcpStream> _dialATrust(
    ATrustConnector connector,
    String host,
    int port,
  ) async {
    final tunnel = connector.tunnel;
    if (tunnel == null) {
      throw const SangforException(
        SangforErrorCode.invalidOptions,
        '隧道未建立，无法建立 TCP 通道',
      );
    }

    final target = '$host:$port';
    final route = shuProxyRouteFor(tunnel.resource.routes, host, port);
    if (route != null) {
      return _openTunnelStream(
        tunnel,
        target,
        shuRouteLabel(route),
        host,
        port,
      );
    }

    // 域名没命中 —— 先把名字解成地址，再拿地址判一次。
    //
    // 网关大量使用「整段地址 + 端口」这种写法授权，SHU 就是
    // `1.0.0.0-255.255.255.255/tcp:443`（整张 IPv4 表的 443 端口）：它按
    // **地址**写，所以只有先解出 A 记录才可能命中。而 `matchTcpRoute` 正好
    // 也是按这个规则判的 —— `destHost` 是 IP 就比地址、是域名就比名字。
    //
    // 这一步不能省。省略它的后果不是「少支持一种写法」，而是「学校明明
    // 把整张网都授权了，浏览器却什么都打不开」。
    final resolution = await _resolveIPv4(host);
    final resolved = resolution.ipv4;
    if (resolved != null) {
      final byAddress = shuProxyRouteFor(
        tunnel.resource.routes,
        resolved,
        port,
      );
      if (byAddress != null) {
        // 这里必须把**解析出来的地址**当目标传进去，不能用域名。
        //
        // `ATrustTunnel.dialTcp` 内部会**再跑一次** `matchTcpRoute`，用它拿到的
        // `host` 去比资源表。而 `128.0.0.0/1` 这类网关授权是**按地址**写的，
        // 比域名永远是 false —— 传域名进去会直接抛
        // `no TCP tunnel resource for <域名>:<端口>`，连握手帧都发不出去
        // （真机日志里真的出现过：命中判定说「归网关管」，`dialTcp` 说「不认得」）。
        //
        // 传地址还有一层依据：zju-connect 的 `tcpTunnelRealDstHost` 在没有域名
        // 可用时就是发 `addr.IP.String()`，而按地址授权的资源根本不需要网关
        // 再去解析什么。
        return _openTunnelStream(
          tunnel,
          target,
          shuRouteLabel(byAddress),
          resolved,
          port,
        );
      }
    }

    // ---- 不在资源表内 ----
    //
    // **没有直连兜底。** 所有目标一律走隧道，隧道接不下的就是一次明确的
    // 失败 —— 因为一个会私下从底层网络出去的代理，在用户看来与「隧道坏了
    // 但还能上网」完全一样，那是最难发现的一类故障。
    //
    // 三种「不在表内」的处境差别很大，说法必须分开：把「域名根本没有 IPv4
    // 记录」说成「不在资源表内」会让人去查网关的授权（查不出问题），而
    // 真正该看的是「这个域名只有 v6」这件事。
    final String outsideReason;
    if (resolution.failure != null) {
      outsideReason =
          '本机 DNS 解析失败：${resolution.failure}；'
          '目标归不归网关管无法判定';
    } else if (resolution.ipv4OnlyMissing) {
      outsideReason =
          '目标只有 IPv6 地址，而这条隧道只承载 IPv4'
          '（网关的授权是 `1.0.0.0-255.255.255.255` 这种 v4 写法）';
    } else {
      outsideReason = '目标不在网关下发的资源表内';
    }

    _proxyUnroutedCount++;
    if (_proxyUnroutedHosts.add(target)) {
      ShuLog.w(
        ShuLogTag.proxy,
        '[TCP] $target no match, refused · $outsideReason',
      );
    }
    throw SangforException(
      SangforErrorCode.unsupported,
      '$target 无法经隧道转发：$outsideReason',
    );
  }

  /// 真正拨一次隧道的 TCP 通道，并把结果写成两行连接日志。
  ///
  /// ## 行的形状
  ///
  /// ```text
  /// [TCP] --> 202.120.117.50:443 match 128.0.0.0/1/tcp:443 via tunnel · 240ms
  /// [TCP] --> 202.120.117.50:443 closed, up 4 pkt 812 B, down 9 pkt 8.4 KB, 1.2s
  /// ```
  ///
  /// 代理这一侧**没有源地址**：拨号接口只拿到「连谁」，客户端的本地端口在
  /// 调用方（HTTP 会话 / SOCKS5 服务）手里。为了一个好看的行头把整条链路的
  /// 签名都改一遍不划算；系统 VPN 那一侧的行头是完整的，需要五元组时看它。
  ///
  /// ## 为什么要单独接住这个失败
  ///
  /// 它是最难的一种状态：判定说这条目标归网关管，而隧道那边又建不起来。
  /// SDK 抛出的 `channel closed during TCP tunnel handshake` 一句看不出是
  /// 这个原因，而 `TimeoutException after 0:00:18` 更是只会让人以为网络慢。
  /// 所以这里把耗时一并记下来 —— 它是区分「握手被拒」与「网络慢」的唯一
  /// 现场信息。
  Future<SangforTcpStream> _openTunnelStream(
    ATrustTunnel tunnel,
    String target,
    String routeLabel,
    String host,
    int port,
  ) async {
    final started = DateTime.now();
    final ATrustTcpTunnelConn connection;
    try {
      connection = await tunnel.dialTcp(host, port, includeL3Preferred: true);
    } on Object catch (error) {
      _proxyTunnelFailures++;
      _meter.dialFailures++;
      ShuLog.w(
        ShuLogTag.proxy,
        '[TCP] --> $target match $routeLabel dial failed · '
        '${formatDuration(DateTime.now().difference(started))} — $error',
      );
      rethrow;
    }
    final elapsed = DateTime.now().difference(started);
    _meter.connectionsOpened++;
    _meter.sampleLatency(elapsed);
    ShuLog.i(
      ShuLogTag.proxy,
      '[TCP] --> $target match $routeLabel via tunnel · '
      '${formatDuration(elapsed)}',
    );
    return _meter.wrap(
      ATrustTcpTunnelStream(connection),
      target: target,
      routeLabel: routeLabel,
    );
  }

  /// 把域名解析成 IPv4（取第一个 A 记录），并说清没有拿到时的原因。
  ///
  /// 用系统 DNS 而不是网关 DNS：这一步只为了**匹配资源表里的地址段**，
  /// 而网关授权的是公网看得见的地址段（`1.0.0.0-255.255.255.255` 这种），
  /// 公网 DNS 解析出来的地址同样落在里面。真的需要网关 DNS 才能解出的
  /// 校内名字，在上一级就按域名命中了，走不到这里。
  ///
  /// ## 为什么返回值不是一个可空的字符串
  ///
  /// 「没拿到 IPv4」有三种完全不同的原因，而它们对应的下一步动作也不同：
  ///
  /// | 情况 | 该做的事 |
  /// | :--- | :--- |
  /// | 解析整个失败（域名不存在 / 本机没 DNS） | 说清是解析问题，不要赖到资源表上 |
  /// | 只有 AAAA、没有 A | 说明隧道只走 v4 —— 用 IPv6 探测站点测网就是这样翻车的 |
  /// | 解出来了，但表里没有 | 那才是真的「不在资源表内」 |
  ///
  /// 合成一句「不在资源表内」会让第二种看起来像网关没授权，而用户去查
  /// 授权是查不出问题的（日志里真的出现过：`ipv6.icanhazip.com` 被报成
  /// 「不在网关下发的资源表内」）。
  Future<({String? ipv4, bool ipv4OnlyMissing, String? failure})> _resolveIPv4(
    String host,
  ) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      if (literal.type == InternetAddressType.IPv4) {
        return (ipv4: literal.address, ipv4OnlyMissing: false, failure: null);
      }
      return (ipv4: null, ipv4OnlyMissing: true, failure: null);
    }
    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
      var sawIpv6 = false;
      for (final address in addresses) {
        if (address.type == InternetAddressType.IPv4) {
          return (ipv4: address.address, ipv4OnlyMissing: false, failure: null);
        }
        sawIpv6 = true;
      }
      return (ipv4: null, ipv4OnlyMissing: sawIpv6, failure: null);
    } on Object catch (error) {
      return (ipv4: null, ipv4OnlyMissing: false, failure: '$error');
    }
  }

  /// 把资源表里 SDK 认不出的**地址区间**展开成等价 CIDR（原地修改）。
  ///
  /// 网关用 `起始-结束` 授权 —— SHU 甚至用它授权整张 IPv4 表 —— 而 SDK 的
  /// `atrustRouteHostCovers` 只认 `地址/前缀`、`a~b` 和单个字面地址。于是
  /// 「整张网都给你」在客户端这一侧变成「不在资源表内」。展开之后就认得了，
  /// 而且两条数据面（代理与 VPN）用的是同一张表。
  ///
  /// 详见 [shuExpandATrustRouteRanges]。
  void _expandResourceTable(SangforConnector connector) {
    if (connector is! ATrustConnector) return;
    final tunnel = connector.tunnel;
    if (tunnel == null) return;
    if (!shuExpandATrustRouteRanges(tunnel.resource.routes)) return;
    ShuLog.i(
      ShuLogTag.conn,
      '资源表里的地址区间已展开成 CIDR · 网关用 `起始-结束` 授权，而 SDK 的'
      '匹配器只认 CIDR · 不展开的话那几条资源拨号时会被判成 no match',
    );
  }

  /// 实验：[SettingsStore.vpnTcpOverL3] 打开时，把每条资源的
  /// `enableTCPPrefL3` 在本地翻成 `true`。
  ///
  /// 改写逻辑在 [shuForceTcpOverL3]（纯函数，有单测）；这里只负责「读设置、
  /// 找个时机、说一句」。时机在 [_expandResourceTable] **之后**：区间展开会把
  /// 原标志原样带到展开出来的条目上，所以先展开再翻能一次盖全。
  void _forceTcpOverL3IfRequested(SangforConnector connector) {
    if (!_settings.vpnTcpOverL3) return;
    if (connector is! ATrustConnector) return;
    final tunnel = connector.tunnel;
    if (tunnel == null) return;
    final changed = shuForceTcpOverL3(tunnel.resource.routes);
    ShuLog.w(
      ShuLogTag.conn,
      '实验：本地把 $changed 条资源的 enableTCPPrefL3 翻成打开 · '
      'TCP 将由 TUN 接管、不设系统代理 · 服务端是否接受要看 L3 流认证的结论',
    );
  }

  /// 资源表是否可路由、覆盖了哪些目标 —— 每次隧道建好都记一行。
  ///
  /// 放在这里而不是只在 `startVpn()` 里：两条数据面都要靠这张表，而
  /// 「我把浏览器指向了代理却什么都打不开」的答案就在这一行里。只在系统
  /// VPN 启动时才记，等于「只用代理的人永远看不到网关给了他什么」。
  ///
  /// ## 为什么还要逐条列出来
  ///
  /// 概要那一行只说「有几个网段」，说不出**具体覆盖了哪里** —— 而
  /// 「VPN 开着却打不开某个站点」的判定完全取决于此。把它逐条列在 DEBUG 档：
  /// 平时不占地方，真要查的时候一条都不缺。
  ///
  /// 尤其要看有没有 `0.0.0.0/0`：
  ///
  /// * **有** → 网关给的是全网访问，路由表会折叠成一条，全部流量进隧道；
  /// * **没有** → 这条链路只能访问网关点名的那些目标。这不是客户端的选择：
  ///   `ATrustTunnel.sendPacket` 拿目的地址去 `matchL3Route` 里找不到路由就
  ///   直接 `return false`（而 `SangforTunnelRouter` 把返回值丢掉），
  ///   所以授权之外的目标进隧道也是石沉大海。**官方客户端用的是同一张表**，
  ///   它同样越不过网关的授权。
  void _logResourceTable(SangforConnector connector) {
    if (connector is! ATrustConnector) return;
    final tunnel = connector.tunnel;
    if (tunnel == null) return;
    final plan = shuVpnRoutePlanFor(tunnel.resource.routes);
    ShuLog.i(ShuLogTag.conn, plan.describe());
    if (!ShuLog.instance.allows(ShuLogLevel.debug)) return;
    // 上限只是为了不让一条日志把缓冲区冲干净；正常网关下发的条数远小于它。
    const limit = 120;
    final routes = tunnel.resource.routes;
    final shown = routes.length > limit ? limit : routes.length;
    for (var index = 0; index < shown; index++) {
      ShuLog.d(ShuLogTag.conn, '资源[$index] ${shuRouteLabel(routes[index])}');
    }
    if (routes.length > shown) {
      ShuLog.d(ShuLogTag.conn, '资源表还有 ${routes.length - shown} 条未列出');
    }
  }

  void _fail(SangforErrorCode code, String message) {
    _errorCode = code;
    _errorMessage = message;
    _state = SangforConnectionState.error;
    _busy = false;
    ShuLog.e(ShuLogTag.conn, '[$code] $message');
    notifyListeners();
  }

  void _clearError() {
    _errorCode = null;
    _errorMessage = null;
  }

  // --------------------------------------------------------------- commands

  /// Connects with the current draft and, when configured, brings the SOCKS5
  /// frontend up in the same gesture — the orb is a single button, so the user
  /// should not have to press something else to actually get traffic flowing.
  Future<bool> connect() async {
    if (_busy) return false;

    // 设置里三个协议全关时不能走到拨号那一步 —— 那句话在页面上已经由
    // 一条提示说过了（`hasEnabledProtocol`），这里是第二道门：
    // 无论 UI 怎么变，这条判断都不能省。
    if (!hasEnabledProtocol) {
      _fail(SangforErrorCode.unsupported, '无可用协议，请先在设置中启用一个');
      return false;
    }

    _clearError();
    _busy = true;
    // 这里**不再清空日志**。缓冲区现在是全应用共用的，一次连接把上一轮的
    // 排障现场擦掉，正是「事情刚发生就没了」的那种遗憾。要清空有日志页上
    // 那个按钮，用不着一连接就自动来一次。
    ShuLog.i(ShuLogTag.conn, '开始一次新的连接');
    _state = SangforConnectionState.connecting;
    notifyListeners();

    final draft = _draft;
    SangforConnector? connector;
    var succeeded = false;

    try {
      final server = _serverUri(draft.server);

      // The gateway authenticates through the unified-identity provider, so the
      // real precondition is a live SSO session — `_buildConnector` states that
      // in its own words when the session is missing.
      final options = SangforConnectOptions(
        server: server,
        // OAuth2 链路不发送用户名，这里只是满足 SDK 的非空校验。
        username: ShuAuthConstants.oauthPlaceholderUsername,
        password: '-',
        loginDomain: draft.loginDomain.trim(),
        deviceId: _deviceId(),
        timeout: _settings.timeout,
        cancellationToken: _loginToken = SangforCancellationToken(),
      );

      ShuLog.i(
        ShuLogTag.conn,
        '连接 ${server.host}:${server.port} · ${draft.protocol.label}',
      );
      connector = _buildConnector(server, draft.protocol);
      options.validate();

      final session = await connector.connect(options);
      ShuLog.i(
        ShuLogTag.conn,
        '登录结束 · state=${session.state.name} · '
        'vip=${session.virtualAddress ?? "-"} · '
        'dns=${session.dnsServers.isEmpty ? "-" : session.dnsServers.join(", ")}',
      );

      if (session.state != SangforConnectionState.connected) {
        throw SangforException(
          SangforErrorCode.tunnelFailed,
          '认证已通过，但隧道未建立（state=${session.state.name}）。'
          '地址或 DNS 为空通常意味着服务端拒绝了隧道请求。',
        );
      }

      _connector = connector;
      _dialer = _dialerFor(connector);
      _virtualAddress = session.virtualAddress;
      _dnsServers = List<String>.unmodifiable(session.dnsServers);
      _connectedAt = DateTime.now();
      _state = session.state;
      ShuLog.i(ShuLogTag.conn, '隧道已建立 · 虚拟地址 ${session.virtualAddress ?? "-"}');
      _expandResourceTable(connector);
      _forceTcpOverL3IfRequested(connector);
      _logResourceTable(connector);
      succeeded = true;
    } on SangforException catch (error) {
      await _teardown(connector);
      _fail(error.code, error.message);
      return false;
    } on Object catch (error) {
      await _teardown(connector);
      _fail(SangforErrorCode.unknown, '$error');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }

    if (succeeded) {
      _startStats();
      // 三条数据面互不排斥，各自跟着自己的开关起来。
      //
      // 顺序有讲究：VPN 起在前面 —— 它内部会确保 HTTP 通道也已经起来
      //（系统代理只认 HTTP），那样 HTTP 那一步就不用再判一次。
      if (_settings.vpnEnabled) await startVpn();
      if (_settings.socksProxyEnabled) await startSocksProxy();
      if (_settings.httpProxyEnabled) await startHttpProxy();
    }
    return succeeded;
  }

  /// Cancels an in-flight connect.
  ///
  /// The aTrust connector races the token; the Easy Connect Dart core does not
  /// observe it yet, so the cancellation may only take effect once the current
  /// request times out.
  void cancel() {
    if (!_busy) return;
    _loginToken?.cancel('user cancelled');
    ShuLog.i(ShuLogTag.conn, '已请求取消连接');
  }

  // --------------------------------------------------------------- 本机代理

  /// 按设置把该起的本机代理都起起来。
  ///
  /// 它是给「隧道刚建好」那一步用的，不是开关本身 —— 设置页上那两个开关
  /// 各自调 [startHttpProxy] / [startSocksProxy]，这样「HTTP 起得来、SOCKS5
  /// 端口被占」这种部分失败也能被分别看见。
  Future<bool> startProxy() async {
    var ok = true;
    if (_settings.httpProxyEnabled && _httpProxy == null) {
      ok = await startHttpProxy() && ok;
    }
    if (_settings.socksProxyEnabled && _socks5 == null) {
      ok = await startSocksProxy() && ok;
    }
    return ok;
  }

  /// 起本机 HTTP 代理。系统代理（含 `VpnService.Builder.setHttpProxy`）
  /// 指的就是它，所以它同时是系统 VPN 的 TCP 出口。
  Future<bool> startHttpProxy() async {
    if (_httpProxy != null) return true;

    final dialer = _dialer;
    if (dialer == null) {
      _fail(SangforErrorCode.invalidOptions, '尚未建立隧道，无法启动 HTTP 代理');
      return false;
    }

    _busy = true;
    _clearError();
    notifyListeners();

    try {
      final token = SangforCancellationToken();
      final listen = _settings.httpListen;
      final advertised = listen.allInterfaces ? await _localIPv4() : null;
      final server = ShuHttpProxy(
        dialer: dialer,
        listenAddress: listen.internetAddress,
        port: _settings.httpPort,
        onDialError: (host, port, error) => ShuLog.w(
          ShuLogTag.proxy,
          '[TCP] --> $host:$port dial failed — $error',
        ),
        cancellationToken: token,
      );
      _httpProxy = server;
      _boundHttpPort = await server.start();
      _boundHttpListen = listen;
      _advertisedHost = advertised;
      ShuLog.i(
        ShuLogTag.proxy,
        'HTTP 代理已监听 ${listen.address}:$_boundHttpPort · ${listen.label}'
        '${advertised == null ? '' : ' · 同网络设备连 $advertised:$_boundHttpPort'}',
      );
      return true;
    } on SangforException catch (error) {
      await _stopHttpProxy();
      _fail(error.code, error.message);
      return false;
    } on Object catch (error) {
      // 半启动状态比没启动更糟：`httpProxyRunning` 会说 true，而系统代理
      // 指向的那个端口根本没人听。回滚干净再报错。
      await _stopHttpProxy();
      _fail(SangforErrorCode.unknown, '启动 HTTP 代理失败：$error');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 起本机 SOCKS5 代理。
  ///
  /// 它服务的是「自己支持 SOCKS5 的应用」—— 浏览器、Telegram、命令行工具。
  /// 系统层面没有任何开关能表达「所有应用都用 SOCKS5」，所以它不会被
  /// 自动接管，只能由用户手动填。
  Future<bool> startSocksProxy() async {
    if (_socks5 != null) return true;

    final dialer = _dialer;
    if (dialer == null) {
      _fail(SangforErrorCode.invalidOptions, '尚未建立隧道，无法启动 SOCKS5');
      return false;
    }

    _busy = true;
    _clearError();
    notifyListeners();

    try {
      final token = SangforCancellationToken();
      final listen = _settings.socksListen;
      final advertised = listen.allInterfaces ? await _localIPv4() : null;
      final server = SangforSocks5Server(
        dialer: dialer,
        // 监听范围是一条安全边界，不是偏好 —— 默认只有本机能连。
        listenAddress: listen.internetAddress,
        port: _settings.socksPort,
        onDialError: (host, port, error) => ShuLog.w(
          ShuLogTag.proxy,
          '[TCP] --> $host:$port dial failed — $error',
        ),
        cancellationToken: token,
      );
      final port = await server.start();
      _socks5 = server;
      _proxyToken = token;
      _boundSocksPort = port;
      _boundSocksListen = listen;
      _advertisedHost = advertised;
      ShuLog.i(
        ShuLogTag.proxy,
        'SOCKS5 代理已监听 ${listen.address}:$port · ${listen.label}'
        '${advertised == null ? '' : ' · 同网络设备连 $advertised:$port'}',
      );
      return true;
    } on SangforException catch (error) {
      await _stopSocksProxy();
      _fail(error.code, error.message);
      return false;
    } on Object catch (error) {
      await _stopSocksProxy();
      _fail(SangforErrorCode.unknown, '启动 SOCKS5 代理失败：$error');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 两个本机代理一起停，并把这轮的账归总一行。
  Future<void> stopProxy() async {
    await _stopHttpProxy();
    await _stopSocksProxy();
    _reportProxyRouting();
    if (!_busy) notifyListeners();
  }

  /// 只停 HTTP 那一半。
  Future<void> stopHttpProxy() async {
    if (_httpProxy == null) return;
    await _stopHttpProxy();
    if (!_busy) notifyListeners();
  }

  /// 只停 SOCKS5 那一半。
  Future<void> stopSocksProxy() async {
    if (_socks5 == null) return;
    await _stopSocksProxy();
    if (!_busy) notifyListeners();
  }

  Future<void> _stopHttpProxy() async {
    final server = _httpProxy;
    final token = _httpToken;
    _httpProxy = null;
    _httpToken = null;
    _boundHttpPort = null;
    _boundHttpListen = null;
    token?.cancel('http proxy stopped');
    try {
      await server?.close();
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.proxy, '关闭 HTTP 代理失败：$error');
    }
    if (server != null) ShuLog.i(ShuLogTag.proxy, 'HTTP 代理已停止');
  }

  Future<void> _stopSocksProxy() async {
    final server = _socks5;
    final token = _proxyToken;
    _socks5 = null;
    _proxyToken = null;
    _boundSocksPort = null;
    _boundSocksListen = null;
    token?.cancel('socks proxy stopped');
    try {
      await server?.close();
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.proxy, '关闭 SOCKS5 代理失败：$error');
    }
    if (server != null) ShuLog.i(ShuLogTag.proxy, 'SOCKS5 代理已停止');
  }

  /// 把这一轮代理的失败情况归总一行，然后把账归零。
  ///
  /// 只在真出过事时才写：一轮下来一切正常就不该留下任何一行 ——
  /// 「小结：0 个失败」是纯噪音。
  void _reportProxyRouting() {
    if (_proxyUnroutedCount > 0) {
      ShuLog.w(
        ShuLogTag.proxy,
        'summary · no match $_proxyUnroutedCount 条（涉及 '
        '${_proxyUnroutedHosts.length} 个目标）',
      );
    }
    if (_proxyTunnelFailures > 0) {
      ShuLog.w(
        ShuLogTag.proxy,
        'summary · dial failed $_proxyTunnelFailures 条 · '
        '问题在隧道那一侧，不在分流判定上',
      );
    }
    _proxyUnroutedCount = 0;
    _proxyTunnelFailures = 0;
    _proxyUnroutedHosts.clear();
  }

  // ------------------------------------------------------------ 实时速率

  /// 开始每秒采样一次速率。
  ///
  /// 基线在**开始采样那一刻**取，而不是等第一次 tick —— 否则第一次的
  /// 增量会是「连接建立之前的所有字节」，界面上会闪出一个假的高峰。
  void _startStats() {
    _statsUpBytes = trafficUpBytes;
    _statsDownBytes = trafficDownBytes;
    _uploadRate = 0;
    _downloadRate = 0;
    _statsTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickStats(),
    );
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _uploadRate = 0;
    _downloadRate = 0;
  }

  void _tickStats() {
    final up = trafficUpBytes;
    final down = trafficDownBytes;
    final deltaUp = (up - _statsUpBytes).clamp(0, 1 << 40).toDouble();
    final deltaDown = (down - _statsDownBytes).clamp(0, 1 << 40).toDouble();
    _statsUpBytes = up;
    _statsDownBytes = down;
    // 平滑一下：原始增量每秒跳一次，直接显示会看着像在闪。系数 0.6 ——
    // 大约两三个采样之后真实值就占主导，而单帧的毛刺会被压掉。
    _uploadRate = _uploadRate * 0.4 + deltaUp * 0.6;
    _downloadRate = _downloadRate * 0.4 + deltaDown * 0.6;
    notifyListeners();
  }

  /// 监听地址或端口改了：已经跑着就按新值重新绑一次。
  ///
  /// ## 为什么必须有这个方法
  ///
  /// 绑定地址是**建立监听那一刻**定下来的，改设置不会自动生效。而且
  /// 用户改完之后还得手动「停一下再开一下」的话，那个开关注定会被当成
  /// 「改了没反应」—— 设置页上那两行本来就没有「重新绑定」这个按钮。
  /// 把重启收在这里，两个调用点（地址、端口）就只剩一句赋值。
  ///
  /// 两个通道**各自重绑**：只改 HTTP 的地址时 SOCKS5 那一侧不该断一下，
  /// 那种「改一个设置把另一个服务重启」的行为在用户看来就是故障。
  ///
  /// 没在跑的通道**什么都不做**：那时新取值会在下次启动时自然生效，
  /// 而一个「为了改设置而先把代理起来」的动作谁也不想要。
  Future<void> rebindHttpProxy() async {
    if (_httpProxy == null) return;
    await _stopHttpProxy();
    // 隧道在这中间断了就不重启 —— `startHttpProxy` 会报「尚未建立隧道」，
    // 而那个错在用户看来就像「改个端口把我代理关了」。
    if (_dialer == null) return;
    await startHttpProxy();
  }

  Future<void> rebindSocksProxy() async {
    if (_socks5 == null) return;
    await _stopSocksProxy();
    if (_dialer == null) return;
    await startSocksProxy();
  }

  /// 本机的非回环 IPv4，取不到时返回 `null`。
  ///
  /// 只用于告诉用户「让别人连哪一个」：多网卡（Wi-Fi + 蜂窝 + USB 共享）时
  /// 取系统列出的第一个。选哪一个在理论上没有更好的答案 —— 它只是一个
  /// 提示，真填错了用户会看到连不上，而不是得到一个错误的结论。
  Future<String?> _localIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } on Object catch (error) {
      ShuLog.d(ShuLogTag.proxy, '查询本机局域网地址失败：$error');
    }
    return null;
  }

  // ------------------------------------------------------------ VPN（安卓）

  /// 问一次系统「VPN 权限给了没」。
  ///
  /// 设置页与引导页每次进入都调它 —— 授权可能在系统设置里被手动取消，
  /// 缓存一个值就等于漏掉那种情况。
  Future<bool> refreshVpnPermission() async {
    if (!vpnSupported) {
      _vpnPrepared = false;
      notifyListeners();
      return false;
    }
    try {
      _vpnPrepared = await _vpnPermission.isPrepared();
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.vpn, '查询 VPN 授权失败：$error');
      _vpnPrepared = false;
    }
    notifyListeners();
    return _vpnPrepared ?? false;
  }

  /// 弹出系统 VPN 授权对话框。
  Future<bool> requestVpnPermission() async {
    if (!vpnSupported) return false;
    try {
      final granted = await _vpnPermission.request();
      _vpnPrepared = granted;
      if (!granted) ShuLog.w(ShuLogTag.vpn, '用户拒绝了 VPN 授权');
      notifyListeners();
      return granted;
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.vpn, '请求 VPN 授权失败：$error');
      return false;
    }
  }

  /// 「授权已经拿到手」——给引导页与设置页用的一句判断。
  ///
  /// 与 [requestVpnPermission] 的差别在于**先查再问**：已经授权过的设备直接
  /// 返回 true，不弹第二次对话框。系统的 VPN 授权是**一次性**的（对话框只
  /// 在你没授权时出现），但每次调 `requestPermission` 都要过一次原生往返，
  /// 而这条路径在引导页上是「按一下按钮」的必经之路 —— 没必要为已经成立的
  /// 事情再问一遍。
  ///
  /// **非 Android 平台返回 true**：那里根本没有系统 VPN 可授权，把引导卡在
  /// 一个永远给不出的权限上没有意义。调用方据此把这一步当成「不需要做」，
  /// 而不是「做失败了」。
  Future<bool> ensureVpnPermission() async {
    if (!vpnSupported) return true;
    if (await refreshVpnPermission()) return true;
    return requestVpnPermission();
  }

  /// 用 Android 的 `VpnService` 把整机流量接到隧道上。
  ///
  /// 与 SOCKS5 的关系：两者共用同一条隧道，但消费方式不同 ——
  /// SOCKS5 只管「主动把代理地址填进来的应用」，VPN 接管全部流量。
  /// 同时开不会双份转发（SOCKS5 监听的是 loopback，不进 TUN）。
  ///
  /// 本应用自己被排除在 VPN 之外（`addDisallowedApplication`）：隧道自己的
  /// 传输是 dart:io 的 socket，被 `0.0.0.0/0` 吸进 TUN 就会自环。代价是
  /// 应用内 WebView（只用于登录 SSO，走公网）不经过隧道 —— 那本来也不需要。
  Future<bool> startVpn() async {
    if (_vpnDevice != null) return true;
    if (!Platform.isAndroid) {
      _fail(SangforErrorCode.unsupported, '系统 VPN 只有 Android 支持');
      return false;
    }
    final connector = _connector;
    final tunnel = connector is ATrustConnector ? connector.tunnel : null;
    if (tunnel == null) {
      _fail(SangforErrorCode.invalidOptions, '尚未建立隧道，无法启动 VPN 服务');
      return false;
    }
    final address = tunnel.virtualAddress ?? _virtualAddress;
    if (address == null || address.isEmpty) {
      _fail(SangforErrorCode.tunnelFailed, '网关没有下发虚拟地址，无法建立 VPN 接口');
      return false;
    }

    // 实验模式：TCP 也交给 L3，于是不需要本机 HTTP 代理、也不设系统代理。
    final forceTcpOverL3 = _settings.vpnTcpOverL3;

    // 本机代理必须先起来：系统 VPN 的 TCP 那一半完全靠它（见下面那段
    // 关于 `l3Routes` 的注释），而 `setHttpProxy` 要填的就是它实际绑定的
    // 端口。
    //
    // 这里是**强制拉起**，不看「启用 HTTP 代理」那个开关 —— HTTP 通道不是
    // 一个可选的数据面，是系统 VPN 的依赖。那个开关管的是「不接 VPN 时
    // 要不要也起一个 HTTP 代理」，不是「允许不允许 VPN 用它」。
    //
    // ⚠️ 实验模式下**跳过**这一步：那时 TCP 由 TUN 送进 L3，系统代理一个字
    // 都不设 —— 那正是这次实验要测的东西。同时也意味着：服务端要是不接受
    // TCP-over-L3，这台设备在连着的时候就没有 TCP 联网能力了。
    if (!forceTcpOverL3 && _boundHttpPort == null) {
      await startHttpProxy();
      // `startHttpProxy` 会把失败写进错误区 —— 那是给「HTTP 代理」那个
      // 开关看的；这里下面会用更贴合现场的话重新说一遍。
      _clearError();
      if (_boundHttpPort == null) {
        _fail(SangforErrorCode.unsupported, '本机 HTTP 代理没能启动，无法把 TCP 流量送进隧道');
        return false;
      }
    }

    _busy = true;
    _clearError();
    notifyListeners();

    try {
      // `start` 在未授权时是返回 `null` 而不是抛错，静默失败会被当成
      // 「开关拨了但没反应」。先自己问一次。
      if (!await refreshVpnPermission()) {
        _fail(SangforErrorCode.unsupported, '没有系统 VPN 授权，请先在下方授权');
        return false;
      }

      // ⚠️ 路由表**必须**来自网关的资源表，不能用 `0.0.0.0/0`。
      //
      // aTrust 的 L3 数据面是按资源授权的转发表：`ATrustTunnel.sendPacket`
      // 拿目的地址去 `matchL3Route` 里找不到路由就 `return false`，而
      // `SangforTunnelRouter` 把这个返回值丢掉了 —— 包是无声消失的。
      // 全路由的后果就是把所有应用的流量都导向一个只会丢弃的黑洞。
      final plan = shuVpnRoutePlanFor(tunnel.resource.routes);
      ShuLog.i(ShuLogTag.vpn, plan.describe());

      // 交出去的是哪些网段，看模式：
      //
      // 常态下是 `plan.l3Routes` —— 「同一条网段上没有任何非 UDP 资源」的
      // 那一小部分，因为 aTrust 的 L3 数据面对 TCP 有一道
      // `if (protocol == 'tcp' && !route.enableTcpPrefL3) continue;`，而 SHU
      // 的网关一条都没开。把一条 TCP 也能到达的网段交给 TUN，那些地址上的
      // TCP 会全部进黑洞：连不上、没报错、也查不出来。
      //
      // 实验模式下是 `plan.tunRoutes` —— **全部**可路由网段，包括 TCP
      // 那些。那正是在验证「网关那道门到底是硬限制还是偏好」。
      //
      // 常态下 TCP 那一半走本机 HTTP 代理：`setHttpProxy` 把系统代理指到
      // 我们自己的端口上，应用连的是它，它再把每一条连接挖进隧道的 TCP
      // 通道。这才是官方客户端「全部流量走学校出口」的做法 —— 学校的授权
      // 本来就是写给 TCP 隧道的（`1.0.0.0-255.255.255.255/tcp:443` 那种
      // 整表授权）。
      final routes = forceTcpOverL3 ? plan.tunRoutes : plan.l3Routes;
      if (!forceTcpOverL3 && routes.isEmpty) {
        // ⚠️ 这句以前写成「网关没有只给 UDP 的网段」，那是**错的**：
        // SHU 的网关确实下发了 `10.10.0.116/udp:53` 和
        // `202.120.119.224-254/udp` 这些只给 UDP 的段，但它们**都落在**
        // `1.0.0.0-255.255.255.255/tcp:…` 那三条整表授权里面。而 TUN 的路由
        // 是按地址下发的、认不出协议 —— 交出去就等于把那些地址上的 TCP
        // 一起送进黑洞。所以是「被压住」而不是「不存在」。
        ShuLog.i(
          ShuLogTag.vpn,
          'TUN 不接管任何路由：网关把整张 IPv4 表的 TCP 都授权了'
          '（`1.0.0.0-255.255.255.255/tcp:80-90,443,8000-9001`），而路由认不出'
          '协议 —— 交出任何一段都会把那里的 TCP 送进黑洞。'
          'TCP 全部走本机 HTTP 代理，UDP 走底层网络',
        );
      }

      // DNS：用户手填的优先；否则用网关下发**且落在路由表内**的那些
      // （那些查询才可能被隧道转发）。原生侧一定还会追加底层网络那一组
      // 当兜底，所以这里给空表也是安全的。
      final List<String> dns;
      if (_settings.vpnDns.isNotEmpty) {
        dns = <String>[_settings.vpnDns];
      } else {
        dns = shuTunnelDnsFor(plan, tunnel.resource.dnsServers);
        if (dns.isNotEmpty) {
          ShuLog.d(ShuLogTag.vpn, '使用网关下发的 DNS：${dns.join(", ")}（落在路由表内）');
        } else if (tunnel.resource.dnsServers.isNotEmpty) {
          ShuLog.d(
            ShuLogTag.vpn,
            '网关下发了 DNS（${tunnel.resource.dnsServers.join(", ")}）'
            '但不在路由表内，改用底层网络的',
          );
        }
      }

      final device = await ShuAndroidVpn.start(
        address: address,
        prefixLength: 32,
        mtu: _settings.vpnMtu,
        routes: routes,
        dnsServers: dns,
        // 把系统代理指到本机的 HTTP 通道上 —— 常态下这是应用们的 TCP 能进
        // 隧道的唯一入口（见上面关于 `routes` 的那段）。
        //
        // 实验模式下传 `0`，原生侧于是**一个字都不设** —— 那时 TCP 走 TUN。
        httpProxyHost: _systemProxyHost,
        httpProxyPort: forceTcpOverL3 ? 0 : _boundHttpPort,
        notificationTitle: ShuAppInfo.name,
        disconnectLabel: '断开',
      );
      if (device == null) {
        _fail(SangforErrorCode.unsupported, '系统未授予 VPN 权限');
        return false;
      }

      _vpnTunnelRoutes = routes;

      // 观测器包在隧道外面，拿得到 `sendPacket` 的真实返回值。
      // 资源表直接交进去 —— 它要拿同一张表复现 SDK 的路由判定，
      // 好把「命中 / 资源表外 / TCP 走不了 L3」分开说。
      final observer = ShuPacketObserver(routes: tunnel.resource.routes);
      _vpnObserver = observer;

      final token = SangforCancellationToken();
      final router = SangforTunnelRouter(
        cancellationToken: token,
        // 逐包日志已经在 observer 里带着目的地记过了，这里只留一条
        // 兜底的链路级错误。
        onError: (error) => ShuLog.w(ShuLogTag.vpn, 'VPN 转发链路出错：$error'),
      )..start(device: device, tunnel: _TunnelPacketAdapter(tunnel, observer));
      _vpnDevice = device;
      _vpnRouter = router;
      _vpnToken = token;
      _vpnDisconnectSub = ShuAndroidVpn.disconnectRequests.listen((_) {
        ShuLog.i(ShuLogTag.vpn, '通知栏请求断开');
        unawaited(disconnect());
      });
      ShuLog.i(
        ShuLogTag.vpn,
        'VPN 已启动 $address/32 · ${forceTcpOverL3 ? "TUN 路由" : "L3 路由"} '
        '${routes.length} 条 · MTU ${_settings.vpnMtu} · '
        'DNS ${dns.isEmpty ? "底层网络" : dns.join(", ")} · '
        '系统 HTTP 代理 ${forceTcpOverL3 ? "未设置" : "$_systemProxyHost:${_boundHttpPort ?? "-"}"}',
      );
      if (forceTcpOverL3) {
        ShuLog.w(
          ShuLogTag.vpn,
          '实验模式：TCP 与 UDP 全部交给 TUN，系统代理未设置 · '
          '若服务端不接受 TCP-over-L3，浏览器会打不开任何页面 —— '
          '那正是本次要验证的结论，看 L3 流认证的日志',
        );
      }
      // 单独一行说地址族：这是「接口建好了但一个包都不进 TUN」的真因，
      // 而它不在上面那一行里看不出任何异常。
      ShuLog.i(
        ShuLogTag.vpn,
        plan.hasIpv6Routes
            ? '接管 IPv4 与 IPv6'
            : '只接管 IPv4 · IPv6 已放行走底层网络。不放行的话系统会默认把'
                  '整族 IPv6 封死',
      );
      return true;
    } on SangforException catch (error) {
      _fail(error.code, error.message);
      return false;
    } on Object catch (error) {
      _fail(SangforErrorCode.unknown, '启动 VPN 服务失败：$error');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> stopVpn() async {
    final device = _vpnDevice;
    _vpnDevice = null;
    final router = _vpnRouter;
    _vpnRouter = null;
    final token = _vpnToken;
    _vpnToken = null;
    final sub = _vpnDisconnectSub;
    _vpnDisconnectSub = null;
    final observer = _vpnObserver;
    _vpnObserver = null;
    await sub?.cancel();
    token?.cancel('vpn stopped');
    try {
      await router?.stop();
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.vpn, '停止 VPN 转发时出错：$error');
    }
    try {
      await device?.close();
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.vpn, '关闭 VPN 接口时出错：$error');
    }
    // 数据面的账在 observer 那里 —— 先让它把这次会话小结写完，再丢弃它。
    observer?.finish();
    ShuLog.i(ShuLogTag.vpn, 'VPN 已停止');
    // 统计与路由表跟着接口一起归零：留着上一轮的计数会让界面看起来
    // 像是「还连着」。
    _vpnTunnelRoutes = const <String>[];
    if (!_busy) notifyListeners();
  }

  Future<void> toggleVpn() async {
    if (_busy) return;
    if (_vpnDevice == null) {
      await startVpn();
    } else {
      await stopVpn();
    }
  }

  Future<void> disconnect() async {
    if (_state == SangforConnectionState.disconnected && _connector == null) {
      return;
    }

    _busy = true;
    _state = SangforConnectionState.disconnecting;
    notifyListeners();

    await _teardown(_connector);

    _busy = false;
    _clearError();
    _state = SangforConnectionState.disconnected;
    ShuLog.i(ShuLogTag.conn, '已断开');
    notifyListeners();
  }

  /// Single entry point for the orb and the dock.
  Future<void> toggle() async {
    if (_busy) return;
    switch (_state) {
      case SangforConnectionState.connected:
      case SangforConnectionState.authenticated:
        await disconnect();
      case SangforConnectionState.connecting:
      case SangforConnectionState.disconnecting:
        cancel();
      case SangforConnectionState.disconnected:
      case SangforConnectionState.error:
        await connect();
    }
  }

  /// Best-effort teardown used by the failure paths. It never throws so the
  /// original error stays the one reported to the user.
  Future<void> _teardown(SangforConnector? connector) async {
    _stopStats();

    final loginToken = _loginToken;
    _loginToken = null;
    loginToken?.cancel('teardown');

    // 两个本机代理一起停：它们是同一条隧道的两个入口，先停哪一个在语义上
    // 没有区别，但漏停一个会留下一个指向已经不存在的隧道的监听端口。
    await stopProxy();
    _advertisedHost = null;

    // VPN 必须比隧道先停：`VpnService` 还开着而隧道已经拆了的话，
    // 系统会把整机流量扔进一个没有出口的接口 —— 那段时间是彻底断网。
    await stopVpn();

    _connector = null;
    _dialer = null;
    _virtualAddress = null;
    _dnsServers = const <String>[];
    _connectedAt = null;

    try {
      await connector?.disconnect();
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.conn, '清理连接失败：$error');
    }
  }
}

/// 把 [ATrustTunnel] 适配成 [SangforTunnelRouter] 要的 [SangforPacketTunnel]，
/// 并在中间穿上逐包观测。
///
/// SDK 里 `ATrustTunnel` 的成员与 `SangforPacketTunnel` 逐项对得上
/// （`incoming` / `isClosed` / `sendPacket` / `close`），但它**没有声明
/// `implements`**，所以不能直接传过去。
///
/// 观测为什么放在这里而不是 `SangforTunnelRouter` 的过滤器上：
///
/// * `egressFilter` 只能回答「包进来了」，拿不到 `sendPacket` 的返回值 ——
///   而那个返回值就是「结果」；
/// * `ingressFilter` 在下行一侧，而把两个方向合到同一个观测器里，
///   才能把下行包算回它那条流上。
///
/// 两个方向都**只看不改**：上行原样转发，下行原样还给系统。
///
/// ⚠️ [close] 不会被 router 调用 —— `SangforTunnelRouter.stop()` 只取消订阅。
/// 隧道的生命周期属于 connector（`disconnect()` 里关），这里跟着关会重复关一次。
class _TunnelPacketAdapter implements SangforPacketTunnel {
  _TunnelPacketAdapter(this._tunnel, this._observer);

  final ATrustTunnel _tunnel;
  final ShuPacketObserver _observer;

  @override
  Stream<Uint8List> get incoming =>
      _tunnel.incoming.map(_observer.observeIngress);

  @override
  bool get isClosed => _tunnel.isClosed;

  @override
  Future<bool> sendPacket(Uint8List packet) =>
      _observer.observeEgress(packet, () => _tunnel.sendPacket(packet));

  @override
  Future<void> close() => _tunnel.close();
}
