import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';

/// 由网关下发的资源表推导出**可以交给系统 VPN 的路由表**。
///
/// ## 为什么不能用 `0.0.0.0/0`
///
/// aTrust 的 L3 数据面**不是一条全隧道，而是一张按资源授权的转发表**。
/// `ATrustTunnel.sendPacket` 的第一件事就是拿目的地址去资源表里找路由：
///
/// ```dart
/// final route = matchL3Route(resource.routes, meta.destinationAddress,
///     protocolName(meta.protocol), meta.destinationPort);
/// if (route == null) return false;          // ← 静默丢弃
/// ```
///
/// 而 `SangforTunnelRouter` 把 `sendPacket` 的返回值丢掉了
/// （`unawaited(send().catchError(...))`），所以不匹配的包是**无声无息地消失**的。
///
/// 于是 `0.0.0.0/0` 的后果非常具体：系统把所有应用的包都送进 TUN →
/// 隧道逐包检查 → 只有落在资源表里的那部分能转发 → 其余全部蒸发。
/// 表现就是「VPN 开着，通知栏也在，但什么网站都打不开」。
///
/// 正确的做法是和官方客户端一样，**只把资源表里那些网段交给系统**：
/// 资源内的流量进隧道，资源外的流量留在底层网络照常走。这不是妥协，
/// 这正是 RVPN（反向 VPN）的定义 —— 它是拿来访问校内资源的，不是全机代理。
///
/// ## 反过来也成立
///
/// 网关没有下发 IP 网段（全是域名）时，系统 VPN 一件有意义的事都做不了。
/// 那种情况下返回空表，由调用方明确报错，而不是建一个「什么都没接管」的
/// 接口来假装成功。
class ShuVpnRoutePlan {
  const ShuVpnRoutePlan({
    required this.tunRoutes,
    required this.l3Routes,
    required this.resourceRoutes,
    required this.domainRoutes,
    required this.tcpL3Routes,
    this.domainHosts = const <String>[],
  });

  /// 资源表里所有能变成网段的条目（含域名型之外的 udp/tcp/all），
  /// 也就是「这张资源表一共覆盖了哪些地址」。
  ///
  /// 已去重、已折叠（被更大网段包含的会被删掉）、已按数值排序 ——
  /// 排序是为了让日志与测试有确定的顺序。它用来回答「网关给了我什么」
  /// 以及「这个 DNS 在不在资源表内」，**不是**直接交给系统的那一份。
  final List<String> tunRoutes;

  /// 真正可以交给 `VpnService.Builder.addRoute` 的那一批。
  ///
  /// 它是 [tunRoutes] 的子集，只留下**隧道确实背得动**的目的地。
  ///
  /// ## 为什么不把 [tunRoutes] 整份交给系统
  ///
  /// aTrust 的 L3 数据面在 `matchL3Route` 里对 TCP 有一道硬门：
  ///
  /// ```dart
  /// if (protocol == 'tcp' && !route.enableTcpPrefL3) continue;
  /// ```
  ///
  /// 网关没有逐资源打开 `enableTCPPrefL3` 时（SHU 的网关就是一条都没开），
  /// **任何 TCP 包都会被 `sendPacket` 静默丢弃**：它返回 `false`，而
  /// `SangforTunnelRouter` 把返回值丢掉了，包就此蒸发。
  ///
  /// 而 `VpnService` 的路由是按**目的地址**分流的，认不出「这条是 UDP」。
  /// 把一条 TCP 也能到达的网段交给 TUN，等于把那些地址上的 TCP 全部送进
  /// 黑洞：浏览器打不开、连不上，而且**没有任何报错** —— 这比不接管更难排查。
  ///
  /// 所以这里只保留「同一条网段上没有任何非 UDP 资源」的那些。SHU 的网关
  /// 给 `1.0.0.0-255.255.255.255/tcp:443` 这种全表授权，于是这一列经常是空的；
  /// 那正是 TCP 必须交给本机代理（`shu_http_proxy.dart` / SOCKS5）的信号。
  final List<String> l3Routes;

  /// 网关下发的资源条数（含域名型）。
  final int resourceRoutes;

  /// 其中**域名型**的条数。它们没法变成 TUN 路由，只能靠 DNS 解析出
  /// 内网地址之后落进上面某一条网段里。
  final int domainRoutes;

  /// 其中 TCP 走 L3 的条数。
  ///
  /// 这是网关侧的一个开关（`enableTCPPrefL3`）。**没开这个开关的资源，
  /// 它的 TCP 流量进了 TUN 也会被丢掉** —— 见 [describe] 里那句提醒。
  final int tcpL3Routes;

  /// 域名型资源的原始写法（`*.shu.edu.cn` 这种），原序、已去重。
  ///
  /// 对系统 VPN 没用，但对**本机代理**是最要紧的一列：代理是按域名拨号的，
  /// 能不能命中资源表由 [shuProxyRouteFor] 决定。把它列出来，日志才能回答
  /// 「这个站点到底归不归网关管」。
  final List<String> domainHosts;

  bool get isEmpty => tunRoutes.isEmpty;

  /// 路由表里有 IPv6 网段吗。
  ///
  /// 它决定原生侧要不要把 IPv6 这一族**放行**：`VpnService.Builder` 的默认
  /// 行为是封掉没有配置过的地址族，而本应用的数据面（aTrust L3）只解 IPv4，
  /// 所以正常情况下这里是 `false` —— 那一族必须显式放行、走底层网络，
  /// 否则双栈网络里几乎全部流量会被系统在进 TUN 之前就丢掉。
  ///
  /// 只有当网关真的下发 IPv6 网段时它才是 `true`（那时我们确实「配置过」
  /// IPv6，系统不会再封）。见 `ShuVpnService.applyAddressFamilies`。
  bool get hasIpv6Routes => tunRoutes.any((route) => route.contains(':'));

  /// 资源表覆盖某个地址吗（用于判断网关下发的 DNS 能不能走隧道）。
  bool covers(String address) {
    final target = _ipv4ToInt(address);
    if (target == null) return false;
    for (final cidr in tunRoutes) {
      final parsed = _parseCidr(cidr);
      if (parsed == null) continue;
      if ((target & _maskFor(parsed.prefix)) == parsed.base) return true;
    }
    return false;
  }

  /// 给日志用的一句话。不带任何网关下发的密钥类内容。
  ///
  /// 它同时回答两个数据面的问题：
  ///
  /// * **系统 VPN** 看 [tunRoutes]（它按目的**地址**分流）；
  /// * **本机代理** 看 [domainHosts] 与那些网段（它按**域名**拨号，
  ///   域名型资源是它真正吃得着的那一类）。
  ///
  /// 行内分隔一律用 ` · `，不用全角分号或破折号 —— 这一行会被抄进日志、
  /// 和别的行排在一起看，符号越单一越好扫。
  String describe() {
    final parts = <String>[
      '资源表 $resourceRoutes 条',
      '可路由网段 ${tunRoutes.length} 个',
      '域名型 $domainRoutes 条',
      'TCP 可走 L3 $tcpL3Routes 条',
      if (tunRoutes.isNotEmpty) '网段 ${_preview(tunRoutes, 8)}',
      if (domainHosts.isNotEmpty) '域名 ${_preview(domainHosts, 6)}',
    ];
    // 收尾那句话看的是**有没有网段**，而不是有没有域名：这两件事对应的是
    // 两条不同的数据面。「只有域名」是最容易被误判的一种 —— 系统 VPN 建得
    // 起来却什么也接管不到，而本机代理恰好能用，所以必须分开说清楚。
    switch ((tunRoutes.isEmpty, domainHosts.isEmpty)) {
      case (true, true):
        parts.add('网关没有下发任何可用目标 · 三条数据面都接管不到东西');
      case (true, false):
        parts.add('没有任何网段 · 系统 VPN 接管不到流量 · 这些域名只能靠本机代理访问');
      case (false, _):
        break;
    }
    // 地址族那一句必须说出来：它曾经就是「VPN 开着但一个包都不进 TUN」的
    // 真因，而现象与「路由表为空」几乎一模一样。
    parts.add(hasIpv6Routes ? '接管 IPv4 与 IPv6' : '只接管 IPv4 · IPv6 已放行走底层网络');
    return parts.join(' · ');
  }

  /// 列出前 [limit] 项，超出时用「等」收尾。
  ///
  /// 不写省略号：它在等宽字体里是三个点，容易被当成地址的一部分。
  static String _preview(List<String> values, int limit) {
    final shown = values.take(limit).join(', ');
    return values.length > limit ? '$shown 等 ${values.length} 项' : shown;
  }
}

/// 由资源表算出 TUN 路由表。
///
/// 三条规则，与 [atrustRouteHostCovers] 认得的写法一一对应：
///
/// | 资源里的写法 | 变成 |
/// | :--- | :--- |
/// | `10.0.0.0/8` | 原样（前缀为 0 时也保留 —— 那是网关自己声明要全路由） |
/// | `10.1.2.3` | `10.1.2.3/32` |
/// | `10.0.0.1~10.0.3.254` | 拆成最少的若干 CIDR |
/// | `*.shu.edu.cn` | **跳过**，靠 DNS 落到某条网段里 |
///
/// 不做协议过滤：TUN 路由本身不带协议，而「哪些 TCP 能走 L3」是网关那边
/// 逐资源的开关，在客户端这一侧无法用路由表达。
ShuVpnRoutePlan shuVpnRoutePlanFor(List<ATrustRoute> routes) {
  final cidrs = <_Cidr>{};
  final l3Cidrs = <_Cidr>{};
  final tcpTouched = <_Cidr>{};
  final domains = <String>[];
  var domainRoutes = 0;
  var tcpL3Routes = 0;

  for (final route in routes) {
    if (route.protocol == 'tcp' && route.enableTcpPrefL3) tcpL3Routes++;
    final host = route.host.trim();
    if (host.isEmpty) continue;

    final parsed = _parseHostCidrs(host);
    if (parsed == null) {
      // 域名 / 通配域名：TUN 路由里没有它，只能指望 DNS 把名字解析到
      // 上面某条网段里；而本机代理正好相反 —— 它拨的就是名字。
      domainRoutes++;
      if (!domains.contains(host)) domains.add(host);
      continue;
    }
    cidrs.addAll(parsed);
    // 这条资源覆盖的地址上有没有人做**走不了 L3 的 TCP**？有的话这一段一个
    // 都不能进 TUN（会变成黑洞，见 [ShuVpnRoutePlan.l3Routes]）。
    //
    // 判据是「协议不是 UDP」**且**「这条资源的 TCP 走不了 L3」：
    //
    // * `udp` —— `matchL3Route` 对 UDP 本来就没有那道门，永远安全；
    // * `tcp` / `all` 且 `enableTcpPrefL3` —— 它的 TCP 本来就走 L3，
    //   把这一段交给 TUN 是**对的**（SHU 的网关没有这样的资源，别处的可能
    //   有；本地实验开关翻转出来的就是这一类）；
    // * 其余 —— 那个地址上的 TCP 只能走 TCP 隧道，交出去就是黑洞。
    if (route.protocol == 'udp') {
      l3Cidrs.addAll(parsed);
    } else if (route.enableTcpPrefL3) {
      l3Cidrs.addAll(parsed);
    } else {
      tcpTouched.addAll(parsed);
    }
  }

  // 把「被非 UDP 资源压住」的段摘掉：`10.0.0.0/16` 是 `all`，它一出现，
  // 落在里面的 `10.10.0.116/32`（网关 DNS）就不该再进 TUN。
  l3Cidrs.removeWhere(
    (candidate) => tcpTouched.any((other) => _overlaps(other, candidate)),
  );

  final collapsed = _collapse(cidrs).toList()..sort(_byAddress);
  final collapsedL3 = _collapse(l3Cidrs).toList()..sort(_byAddress);
  return ShuVpnRoutePlan(
    tunRoutes: <String>[for (final cidr in collapsed) cidr.format()],
    l3Routes: <String>[for (final cidr in collapsedL3) cidr.format()],
    resourceRoutes: routes.length,
    domainRoutes: domainRoutes,
    tcpL3Routes: tcpL3Routes,
    domainHosts: List<String>.unmodifiable(domains),
  );
}

/// 把 SDK 认不出的**破折号区间**就地展开成等价 CIDR，追加回资源表。
///
/// ## 为什么必须这么做
///
/// 网关用 `起始-结束` 这种写法授权整段地址，SHU 的网关甚至用它授权了
/// **整张 IPv4 表**：
///
/// ```
/// 1.0.0.0-255.255.255.255/tcp:80-90
/// 1.0.0.0-255.255.255.255/tcp:8000-9001
/// 1.0.0.0-255.255.255.255/tcp:443
/// ```
///
/// 这三条就是「上网流量全部走学校出口」的授权本身。
///
/// 而 SDK 的 `atrustRouteHostCovers` 只认三种写法：`地址/前缀`、`a~b`、
/// 单个字面地址。**破折号区间它一个都认不出来** —— 于是
/// `matchTcpRoute` 对任何主机都返回 `null`，`ATrustTunnel.dialTcp` 直接抛
/// `no TCP tunnel resource for host:port`。换句话说：网关说「整张网都给你」，
/// 客户端却回答「不在资源表内」。
///
/// 这里不去改依赖包的代码，而是把区间**等价展开**成 SDK 本来就认得的 CIDR
/// 条目追加进同一个列表 —— `ATrustResource.routes` 是公开的可增长列表，
/// SDK 的匹配器遍历的就是它，所以追加之后 `matchTcpRoute` / `matchL3Route`
/// 立刻就能命中，`appId` / `nodeGroupId` 也原样带过去（网关认的是它们，
/// 不是 host 写法）。
///
/// 返回是否真的追加了东西。同一条资源表只会展开一次 —— 展开过的表上再跑
/// 一遍会把条目翻倍。
bool shuExpandATrustRouteRanges(List<ATrustRoute> routes) {
  if (_rangesExpanded[routes] == true) return false;
  _rangesExpanded[routes] = true;

  final additions = <ATrustRoute>[];
  for (final route in routes) {
    final host = route.host.trim();
    if (!host.contains('-')) continue;
    final parsed = _parseHostCidrs(host);
    if (parsed == null) continue;
    for (final cidr in parsed) {
      additions.add(
        ATrustRoute(
          host: cidr.format(),
          protocol: route.protocol,
          portMin: route.portMin,
          portMax: route.portMax,
          appId: route.appId,
          nodeGroupId: route.nodeGroupId,
          addrPretend: route.addrPretend,
          enableTcpPrefL3: route.enableTcpPrefL3,
        ),
      );
    }
  }
  if (additions.isEmpty) return false;
  routes.addAll(additions);
  return true;
}

/// 已展开过的资源表（按列表对象本身记），避免重复追加。
final Expando<bool> _rangesExpanded = Expando<bool>('shuATrustRangesExpanded');

/// **实验用**：把资源表里每一条「TCP 能到达」的资源在本地翻成
/// `enableTcpPrefL3 = true`，让 `matchL3Route` 收下 TCP。
///
/// ## 它改的是客户端的信念，不是服务端的配置
///
/// `enableTcpPrefL3` 来自网关 JSON 的 `enableTCPPrefL3`（`resource.dart:69`），
/// 是**应用级**的标记。它的真正含义是「这个 app 的 TCP 走哪条通道」，两条
/// 匹配器对它严格互补：
///
/// | 标志 | `matchL3Route` | `matchTcpRoute` |
/// | :--- | :--- | :--- |
/// | `true` | 放行 | 要 `includeL3Preferred` 才收 |
/// | `false` | 跳过 TCP | 收 |
///
/// 本地翻它**不会**改变服务端的行为：L3 的每个五元组第一次出现时要先发一次
/// 流认证请求，而那个请求里明写了协议（`url: "tcp:1.2.3.4:443"` 与
/// `ip.protocol = 6`）—— 服务端答不答应取决于它自己那份配置。
///
/// 所以这个函数的用途是**验证**而不是优化：服务端接受 TCP-over-L3 的话，
/// 「系统代理 + HTTP 代理」那一半就可以撤掉；不接受的话它会话里回来一个
/// 非零 status，而 `atrust_channel_probe.dart` 会把那个 status 记下来。
///
/// 原地修改（与 [shuExpandATrustRouteRanges] 同性质），返回被翻转的条数。
int shuForceTcpOverL3(List<ATrustRoute> routes) {
  var changed = 0;
  for (var index = 0; index < routes.length; index++) {
    final route = routes[index];
    if (route.enableTcpPrefL3) continue;
    if (route.protocol != 'tcp' && route.protocol != 'all') continue;
    routes[index] = ATrustRoute(
      host: route.host,
      protocol: route.protocol,
      portMin: route.portMin,
      portMax: route.portMax,
      appId: route.appId,
      nodeGroupId: route.nodeGroupId,
      addrPretend: route.addrPretend,
      enableTcpPrefL3: true,
    );
    changed++;
  }
  return changed;
}

/// 本机代理能不能把这个目标交给隧道。
///
/// ## 为什么代理需要单独一次判定
///
/// 代理接到的是**一个域名加一个端口**（SOCKS5 的 CONNECT 请求里带的就是
/// 名字），而系统 VPN 分的是**目的地址**。两者用的不是同一条门：
///
/// * VPN：`matchL3Route`，要求目标落在某个网段里；
/// * 代理：`matchTcpRoute`，把域名拿 `atrustRouteDomainCovers` 比对。
///
/// 于是「校内站点上不去」在两条数据面上是两个完全不同的原因，而这个函数
/// 就是给代理那一边提供一句确定的结论。
///
/// ## 为什么直接转调 SDK
///
/// `ATrustTunnel.dialTcp` 里用的就是这个调用（带同一个 `includeL3Preferred`），
/// 所以它说「不在表内」，隧道那边也一定拨不通 —— 两边不可能分叉。
/// 反过来如果自己写一份近似判定，就会出现「预检说能连、隧道说不能连」
/// 这种最费时间的差别。
ATrustRoute? shuProxyRouteFor(
  List<ATrustRoute> routes,
  String host,
  int port,
) => matchTcpRoute(routes, host, port, includeL3Preferred: true);

/// 资源条目的简短写法，供日志用：`10.1.0.0/16/tcp:443 app=af1c gid=10`。
///
/// 协议与端口区间是 `matchL3Route` / `matchTcpRoute` 的另外两条门 ——
/// 漏掉它们会让「明明在网段里却匹配不上」变成无解的谜题。
///
/// 它是公开的而不是某个日志模块的私货：[vpn_packet_log.dart] 与代理拨号
/// 两处都要说「命中的是哪一条」，两处必须长得一模一样。
String shuRouteLabel(ATrustRoute route) {
  final buffer = StringBuffer(route.host);
  if (route.protocol != 'all') buffer.write('/${route.protocol}');
  // 「全部端口」有好几种等价写法（`0-65535`、`1-65535`、不写），
  // 一律不写出来 —— 它们在日志里只是噪音，反而盖住了真正收窄了的那几条。
  if (route.portMin > 1 || route.portMax < 65535) {
    buffer.write(
      route.portMin == route.portMax
          ? ':${route.portMin}'
          : ':${route.portMin}-${route.portMax}',
    );
  }
  if (route.appId.isNotEmpty) buffer.write(' app=${route.appId}');
  if (route.nodeGroupId.isNotEmpty) buffer.write(' gid=${route.nodeGroupId}');
  return buffer.toString();
}

/// 网关下发的 DNS 里，**落在资源网段内的那些**。
///
/// 只有这些才可能被隧道转发；网段之外的（比如 `8.8.8.8`）放进 VPN 的
/// DNS 列表只会让所有查询超时。
List<String> shuTunnelDnsFor(ShuVpnRoutePlan plan, List<String> candidates) =>
    <String>[
      for (final server in candidates)
        if (_ipv4ToInt(server) != null && plan.covers(server)) server,
    ];

// --------------------------------------------------------------- 内部工具

class _Cidr {
  const _Cidr(this.base, this.prefix);

  /// 已按掩码对齐的网络地址。
  final int base;
  final int prefix;

  String format() => '${_intToIpv4(base)}/$prefix';
}

/// 把网段集合折叠：被别的网段包含的直接删掉。
///
/// 资源表里同一个地址段常常被多个应用各列一遍，折叠之后交给系统的路由
/// 条数会少很多 —— 几百条路由在 `VpnService` 里是要逐条下发到 netd 的。
Set<_Cidr> _collapse(Set<_Cidr> input) {
  final list = input.toList();
  final result = <_Cidr>{};
  for (var index = 0; index < list.length; index++) {
    final candidate = list[index];
    var contained = false;
    for (var other = 0; other < list.length; other++) {
      if (index == other) continue;
      if (_covers(list[other], candidate)) {
        // 完全相同的两条：只留先出现的那条，避免互相"包含"导致全丢。
        if (_covers(candidate, list[other])) {
          if (other < index) {
            contained = true;
            break;
          }
          continue;
        }
        contained = true;
        break;
      }
    }
    if (!contained) result.add(candidate);
  }
  return result;
}

bool _covers(_Cidr outer, _Cidr inner) {
  if (outer.prefix > inner.prefix) return false;
  return (inner.base & _maskFor(outer.prefix)) == outer.base;
}

/// `10.0.0.1~10.0.3.254` 这种区间拆成最少的 CIDR。
///
/// 标准做法：每次从当前地址开始，取「对齐到当前地址、且不越过区间末尾」
/// 的最大 2 的幂块。
List<_Cidr> _rangeToCidrs(int start, int end) {
  final out = <_Cidr>[];
  var current = start;
  while (current <= end) {
    var bits = 0;
    while (bits < 32) {
      final size = 1 << (bits + 1);
      if (current % size != 0) break;
      if (current + size - 1 > end) break;
      if (current + size - 1 > 0xFFFFFFFF) break;
      bits++;
    }
    out.add(_Cidr(current, 32 - bits));
    current += 1 << bits;
  }
  return out;
}

/// 资源里出现的四种 IPv4 写法 → CIDR 列表；**域名返回 `null`**。
///
/// | 写法 | 结果 |
/// | :--- | :--- |
/// | `10.0.0.0/16` | 原样 |
/// | `10.1.2.3` | `10.1.2.3/32` |
/// | `10.0.0.1~10.0.3.254` | 拆成最少的若干 CIDR |
/// | `49.52.105.0-49.52.111.255` | 同上（**破折号区间**，SDK 不认，见 [shuExpandATrustRouteRanges]）|
/// | `*.shu.edu.cn` | `null` |
List<_Cidr>? _parseHostCidrs(String host) {
  // `10.0.0.0/16` 这种标准 CIDR。`int.tryParse` 会把 `/udp` 这类后缀挡掉，
  // 挡掉之后继续往下面几种写法里试。
  if (host.contains('/')) {
    final parsed = _parseCidr(host);
    if (parsed != null) return <_Cidr>[parsed];
  }
  for (final separator in const <String>['~', '-']) {
    if (!host.contains(separator)) continue;
    final bounds = host.split(separator);
    if (bounds.length != 2) return null;
    final low = _ipv4ToInt(bounds.first.trim());
    final high = _ipv4ToInt(bounds.last.trim());
    if (low == null || high == null || low > high) return null;
    return _rangeToCidrs(low, high);
  }
  final single = _ipv4ToInt(host);
  return single == null ? null : <_Cidr>[_Cidr(single, 32)];
}

_Cidr? _parseCidr(String raw) {
  final parts = raw.split('/');
  if (parts.length != 2) return null;
  final base = _ipv4ToInt(parts[0].trim());
  final prefix = int.tryParse(parts[1].trim());
  if (base == null || prefix == null || prefix < 0 || prefix > 32) return null;
  return _Cidr(base & _maskFor(prefix), prefix);
}

/// 两个网段有没有交集（含一方完全包含另一方的两种情况）。
bool _overlaps(_Cidr left, _Cidr right) =>
    _covers(left, right) || _covers(right, left);

int _byAddress(_Cidr left, _Cidr right) {
  final byBase = left.base.compareTo(right.base);
  return byBase != 0 ? byBase : left.prefix.compareTo(right.prefix);
}

int _maskFor(int prefix) =>
    prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;

int? _ipv4ToInt(String address) {
  final parts = address.trim().split('.');
  if (parts.length != 4) return null;
  var value = 0;
  for (final part in parts) {
    final octet = int.tryParse(part);
    if (octet == null || octet < 0 || octet > 255) return null;
    value = (value << 8) | octet;
  }
  return value;
}

String _intToIpv4(int value) =>
    '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}'
    '.${(value >> 8) & 0xFF}.${value & 0xFF}';
