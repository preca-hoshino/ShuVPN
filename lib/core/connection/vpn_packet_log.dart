/// VPN 数据面的**逐包观测**：每一个包的「去哪、凭什么、结果如何」。
///
/// ## 为什么要在这一层再做一次判断
///
/// `ATrustTunnel.sendPacket` 是**静默**的：拿目的地址去资源表里找不到路由
/// 就 `return false`，而 `SangforTunnelRouter._forward` 是
/// `unawaited(send().catchError(...))` —— 返回值直接丢掉。于是「VPN 开着但
/// 某个站点打不开」在日志里**一句都看不到**，只能靠猜。
///
/// 这里把同一个判断（SDK 的 `matchL3Route`，不另写一份逻辑）在包进入隧道
/// **之前**做一次，并把它与 `sendPacket` 的真实返回值配成对记下来。
/// 结论只有三种，第三种是最容易误判的一种：
///
/// | 结论 | 原因 | 谁来丢的 |
/// | :--- | :--- | :--- |
/// | [ShuPacketVerdict.routed] | 五元组命中资源表 | —— 交给对应节点组 |
/// | [ShuPacketVerdict.unroutable] | 目的地址压根不在资源表里 | 隧道静默丢弃 |
/// | [ShuPacketVerdict.tcpNotL3] | TCP 命中了资源，但那条资源没开 `enableTcpPrefL3` | 隧道静默丢弃 |
///
/// ## 四个等级各写什么
///
/// 行头固定是 `[协议] 源 --> 目的`，后面跟「匹配到什么 + 结果」，与 Clash 的
/// 连接日志同形。
///
/// | 等级 | 内容 |
/// | :--- | :--- |
/// | `ERROR` | 发送失败 |
/// | `WARN` | 注定被丢弃：资源表外、TCP 未开 L3、畸形包、IPv6 |
/// | `INFO` | **每条流两行** —— 建立时一行、收尾时一行（含字节数与时长） |
/// | `DEBUG` | **逐个包一行**：方向、序号、长度、TCP 标志、结果 |
///
/// **任何等级都不打原始字节转储。** 十六进制读不出结论，却会按几十倍的比例
/// 吃掉缓冲区容量。
///
/// DEBUG 那一档有**每秒预算**（[ShuPacketObserver.debugBudgetPerSecond]）：
/// 一条 10 Mbps 的连接每秒近千个包，逐条写会把缓冲区在半秒内冲干净、
/// 日志页一秒重画上千次。超出预算的只计数，下一秒用一行汇总说明漏了多少。
/// 要看的那条流通常只有几十个包，预算之内逐条都在。
library;

import 'dart:typed_data';

import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';

import '../logging/shu_log.dart';
import 'vpn_routes.dart';

/// 一个上行包在隧道里会得到的结论。
///
/// 取值本身就是日志里的那个词，与 Clash 的 `match` / `no match` 对齐。
enum ShuPacketVerdict {
  /// 命中资源表 —— `sendPacket` 会把它交给对应的节点组。
  routed('match'),

  /// 目的地址不在网关下发的资源表里。
  unroutable('no match'),

  /// TCP 命中了某条资源，但那条资源的 `enableTcpPrefL3` 是 `false`，
  /// `matchL3Route` 的第三条门把它挡掉了。
  ///
  /// 之所以单独给一个名字：它的现象和「网关没给你权限」一模一样，
  /// 但原因完全不同（权限是有的，只是这条资源不走 L3）。
  /// 只有网关自己知道哪些资源能走 L3，客户端唯一能做的就是**说出来**。
  tcpNotL3('no l3'),

  /// IPv6 包。
  ///
  /// 正常**不应该出现**：原生侧会把没接管的地址族 `allowFamily` 放行，
  /// 那一族于是在进 TUN 之前就走了底层网络（见
  /// `ShuVpnService.applyAddressFamilies`）。如果它出现了，说明地址族那件事
  /// 没配对 —— 而这正是曾经把「VPN 开着却一个包都不进 TUN」藏住的地方：
  /// aTrust 的 L3 数据面只解 IPv4，这些包进来只会被丢掉。
  ///
  /// 单独一档而不是归进「无法解析」：后者会让人去查包是不是坏了，
  /// 而这里包是好的，只是**没人答应处理它**。
  ipv6('ipv6');

  const ShuPacketVerdict(this.label);

  /// 日志里那一列的中文说法。
  final String label;

  /// 这个结论意味着包会被隧道丢掉吗。
  ///
  /// [unroutable] 与 [tcpNotL3] 都是丢包，但原因不同 —— 计数只要一个数，
  /// 日志里才需要分开说。
  bool get dropped => this != ShuPacketVerdict.routed;
}

/// 一条流（五元组，双向共用一条）的账本。
///
/// key 是**规范化**的：两个端点按字典序串起来，所以上行和下行落在同一条
/// 流上 —— 否则下行包会因为源目相反被当成另一条连接。
class ShuPacketFlow {
  ShuPacketFlow({
    required this.key,
    required this.protocol,
    required this.source,
    required this.destination,
    required this.verdict,
    required this.route,
    required this.firstSeen,
  }) : lastSeen = firstSeen;

  /// 规范化五元组。
  final String key;

  /// `TCP` / `UDP` / `ICMP`。
  final String protocol;

  /// 上行包的源（`地址:端口`；ICMP 之类没有端口时只有地址）。
  final String source;

  /// 上行包的目的。
  final String destination;

  final ShuPacketVerdict verdict;

  /// 命中的资源条目（[ShuPacketVerdict.routed] 与
  /// [ShuPacketVerdict.tcpNotL3] 才有）。
  final ATrustRoute? route;

  final DateTime firstSeen;
  DateTime lastSeen;

  int egressPackets = 0;
  int ingressPackets = 0;
  int egressBytes = 0;
  int ingressBytes = 0;

  /// 已经收过尾（看到 FIN / RST）。
  bool closed = false;

  /// `192.168.5.2:51234 --> 10.1.2.3:443`。
  ///
  /// 箭头用 Clash 的那一个（`-->`）而不是 `→`：网络日志里的这一行是给人
  /// 扫的，字符越少越容易在一屏里对齐。
  String get label => '$source --> $destination';
}

/// 观察数据面上的每一个包，并把结论写进日志。
///
/// 它**只看不改**：`observeEgress` 一定会把包交给隧道，`observeIngress` 一定
/// 把原包还回去。在客户端擅自丢包会让行为与 SDK 分叉，而这一层要的只是
/// 「看得见」。
class ShuPacketObserver {
  ShuPacketObserver({
    required List<ATrustRoute> routes,
    DateTime Function()? clock,
  }) : _routes = List<ATrustRoute>.unmodifiable(routes),
       _now = clock ?? DateTime.now;

  /// 流表的条数上限。
  ///
  /// 一张长期跑着的表（几百条流）完全正常，所以这个上限只用来兜住
  /// 「应用不停地开新连接」这种情况 —— 到顶之后按最久没动过的淘汰。
  static const int maxFlows = 512;

  /// DEBUG 档逐包日志的每秒预算。见库文档。
  static const int debugBudgetPerSecond = 200;

  final List<ATrustRoute> _routes;
  final DateTime Function() _now;

  final Map<String, ShuPacketFlow> _flows = <String, ShuPacketFlow>{};

  // ------------------------------------------------------------------ 计数

  int egressPackets = 0;
  int ingressPackets = 0;
  int egressBytes = 0;
  int ingressBytes = 0;

  /// 目的地址不在资源表内（或 TCP 走不了 L3）、因此被隧道**静默**丢掉的
  /// 包数。这个数字不为零就说明有人访问了资源之外的东西，或者路由表把范围
  /// 放得太宽了。
  int unroutablePackets = 0;

  /// 命中了资源却仍然没发出去的包数（异常或 `sendPacket` 返回 `false`）。
  int failedPackets = 0;

  /// 解析不出 IPv4 头的包数。
  int malformedPackets = 0;

  /// 走进 TUN 的 IPv6 包数。
  ///
  /// 正常情况下永远是 0（那一族被原生侧放行了，不进 TUN）。见
  /// [ShuPacketVerdict.ipv6]。
  int ipv6Packets = 0;

  /// 建立过的流总数（不受 [maxFlows] 淘汰影响）。
  int flowsSeen = 0;

  int get flowCount => _flows.length;

  // ------------------------------------------------------------ DEBUG 预算

  int _debugSecond = -1;
  int _debugUsed = 0;
  int _debugSuppressed = 0;

  // ------------------------------------------------------------------ 入口

  /// 上行：应用把包交给隧道。返回 [send] 的**原始结果**。
  ///
  /// 异常在这里被吃掉并记成 `ERROR`（不再向外抛）：`SangforTunnelRouter`
  /// 只会把同一个异常转给 `onError`，抛上去等于同一件事记两遍。
  Future<bool> observeEgress(
    Uint8List packet,
    Future<bool> Function() send,
  ) async {
    egressPackets++;
    egressBytes += packet.length;

    final view = _parse(packet, egress: true);
    if (view == null) {
      if (_isIpv6(packet)) {
        ipv6Packets++;
        if (ipv6Packets == 1 || ipv6Packets % 200 == 0) {
          ShuLog.w(
            ShuLogTag.packet,
            '[IPv6] ${packet.length} B ipv6, dropped · 本接口只接管 IPv4，'
            '累计 $ipv6Packets 个。正常情况下它们应在进 TUN 之前由地址族'
            '放行走底层网络',
          );
        }
      } else {
        malformedPackets++;
        // 畸形包可能成千上万地来，只在第一个与每 200 个时说话。
        if (malformedPackets == 1 || malformedPackets % 200 == 0) {
          ShuLog.w(
            ShuLogTag.packet,
            '[?] ${packet.length} B malformed, dropped · 非 IPv4 或头部长度'
            '与实际不符，累计 $malformedPackets 个',
          );
        }
      }
      return _dispatch(send, null, null);
    }

    final flow = _ensureFlow(view);
    flow.egressPackets++;
    flow.egressBytes += packet.length;
    if (flow.verdict.dropped) unroutablePackets++;

    final routed = await _dispatch(send, view, flow);
    if (view.tcpClosing) _closeFlow(flow);
    return routed;
  }

  /// 下行：隧道把包还给系统。
  ///
  /// **必须原样返回** —— 调用方是 `Stream.map`，返回值就是给系统的那一份。
  Uint8List observeIngress(Uint8List packet) {
    ingressPackets++;
    ingressBytes += packet.length;

    final view = _parse(packet, egress: false);
    if (view == null) return packet;

    final flow = _ensureFlow(view);
    flow.ingressPackets++;
    flow.ingressBytes += packet.length;

    _debugLine(view, flow, outcome: 'forwarded');
    if (view.tcpClosing) _closeFlow(flow);
    return packet;
  }

  /// VPN 停止时收尾：把这次会话的账报一行。
  void finish() {
    if (_debugSuppressed > 0) {
      ShuLog.d(
        ShuLogTag.packet,
        '另有 $_debugSuppressed 个包未逐条记录（DEBUG 档每秒预算 '
        '$debugBudgetPerSecond）',
      );
      _debugSuppressed = 0;
    }
    if (egressPackets == 0 &&
        ingressPackets == 0 &&
        malformedPackets == 0 &&
        ipv6Packets == 0) {
      return;
    }
    ShuLog.i(
      ShuLogTag.packet,
      'summary · up $egressPackets pkt ${formatByteCount(egressBytes)} · '
      'down $ingressPackets pkt ${formatByteCount(ingressBytes)} · '
      '$flowsSeen 条流'
      '${unroutablePackets == 0 ? '' : ' · no match $unroutablePackets'}'
      '${failedPackets == 0 ? '' : ' · send failed $failedPackets'}'
      '${malformedPackets == 0 ? '' : ' · malformed $malformedPackets'}'
      '${ipv6Packets == 0 ? '' : ' · ipv6 $ipv6Packets'}',
    );
  }

  // ------------------------------------------------------------- 内部实现

  /// 真发一次，并把结果记下来。
  ///
  /// 行的顺序是「**明细在前、结论在后**」：读到 ERROR 那一行时，它上面
  /// 就是那个包的完整样子。写法上就是把 ERROR 留到明细之后才写 ——
  /// 不需要任何缓冲区上的小动作。
  Future<bool> _dispatch(
    Future<bool> Function() send,
    _PacketView? view,
    ShuPacketFlow? flow,
  ) async {
    var routed = false;
    Object? failure;
    try {
      routed = await send();
    } on Object catch (error) {
      failure = error;
    }

    /// `null` 表示这个包没有出错，不需要第二行。
    String? errorLine;
    final String outcome;

    if (failure != null) {
      failedPackets++;
      outcome = 'send failed';
      errorLine = view == null
          ? '[?] send failed · 包无法解析 — $failure'
          : '[${view.protocol}] ${view.source} --> ${view.destination} '
                'send failed · ${view.tag} — $failure';
    } else if (!routed &&
        flow != null &&
        flow.verdict == ShuPacketVerdict.routed) {
      // 命中了资源、`sendPacket` 却返回 false：SDK 里只有「隧道已关闭」
      // 这一种可能。它同样不会有任何提示，所以必须在这里说出来。
      failedPackets++;
      outcome = 'send failed';
      errorLine =
          '[${view!.protocol}] ${view.source} --> ${view.destination} '
          'send failed · ${view.tag} · 命中的资源 ${shuRouteLabel(flow.route!)} '
          '正常，sendPacket 返回 false（隧道已关闭）';
    } else if (flow != null && !routed) {
      // 命中了「会被丢掉」的判定 —— `sendPacket` 返回 false 是**预期**的，
      // 不是失败。
      outcome = '${flow.verdict.label}, dropped';
    } else {
      outcome = 'forwarded';
    }

    if (view != null && flow != null) {
      _debugLine(view, flow, outcome: outcome);
    }
    if (errorLine != null) ShuLog.e(ShuLogTag.packet, errorLine);
    return routed;
  }

  /// 新流建立时那一行（`INFO` 档的内容）。
  void _announce(ShuPacketFlow flow) {
    final route = flow.route;
    switch (flow.verdict) {
      case ShuPacketVerdict.routed:
        ShuLog.i(
          ShuLogTag.packet,
          '[${flow.protocol}] ${flow.label} match ${shuRouteLabel(route!)} '
          'via tunnel',
        );
      case ShuPacketVerdict.tcpNotL3:
        ShuLog.w(
          ShuLogTag.packet,
          '[TCP] ${flow.label} no l3, dropped · 命中的资源 '
          '${shuRouteLabel(route!)} 未开 enableTcpPrefL3，L3 隧道不背 TCP。'
          '本机代理会接管这一条',
        );
      case ShuPacketVerdict.unroutable:
        ShuLog.w(
          ShuLogTag.packet,
          '[${flow.protocol}] ${flow.label} no match, dropped · 不在网关'
          '资源表内。这条流量出现在 TUN 里说明交给系统的路由表放得太宽',
        );
      case ShuPacketVerdict.ipv6:
        // 建流时已经是 IPv6 结论；它在 `observeEgress` 里单独报，
        // 这里不该出现（IPv6 包解不出 IPv4 头，永远进不了流表）。
        break;
    }
  }

  /// 一条流收尾。看到 FIN / RST 就算结束 —— 不做空闲超时：
  /// 那需要一条定时器，而它带来的复杂度换不来更多的信息。
  void _closeFlow(ShuPacketFlow flow) {
    if (flow.closed) return;
    flow.closed = true;
    final elapsed = _now().difference(flow.firstSeen);
    ShuLog.i(
      ShuLogTag.packet,
      '[${flow.protocol}] ${flow.label} closed, '
      'up ${flow.egressPackets} pkt ${formatByteCount(flow.egressBytes)}, '
      'down ${flow.ingressPackets} pkt ${formatByteCount(flow.ingressBytes)}, '
      '${formatDuration(elapsed)}',
    );
  }

  /// 逐包明细（`DEBUG` 档）。**先问等级再拼字符串**。
  ///
  /// 只写长度，不写字节内容。十六进制读不出结论，却会把缓冲区的容量按
  /// 几十倍的比例吃掉。
  void _debugLine(
    _PacketView view,
    ShuPacketFlow flow, {
    required String outcome,
  }) {
    if (!ShuLog.instance.allows(ShuLogLevel.debug)) return;
    final now = _now();
    if (!_takeDebugBudget(now)) return;

    final sequence = view.egress ? flow.egressPackets : flow.ingressPackets;
    final direction = view.egress ? 'up' : 'down';
    ShuLog.d(
      ShuLogTag.packet,
      '[${view.protocol}] ${view.source} --> ${view.destination} '
      '$direction#$sequence ${view.tag} ${view.bytes} B $outcome',
    );
  }

  /// 取一次 DEBUG 预算。
  ///
  /// 跨秒时把上一秒被压掉的条数补一行汇总 —— 省略必须是**说出来的**，
  /// 否则「日志里没有这条流」和「这条流没发生」就分不清了。
  bool _takeDebugBudget(DateTime now) {
    final second = now.millisecondsSinceEpoch ~/ 1000;
    if (second != _debugSecond) {
      _debugSecond = second;
      _debugUsed = 0;
      if (_debugSuppressed > 0) {
        ShuLog.d(
          ShuLogTag.packet,
          '上一秒另有 $_debugSuppressed 个包未逐条记录（DEBUG 档每秒预算 '
          '$debugBudgetPerSecond）',
        );
        _debugSuppressed = 0;
      }
    }
    if (_debugUsed >= debugBudgetPerSecond) {
      _debugSuppressed++;
      return false;
    }
    _debugUsed++;
    return true;
  }

  /// 取这条流；没有就按**第一个包的规范方向**建一条并报一次「建立」。
  ShuPacketFlow _ensureFlow(_PacketView view) {
    final existing = _flows[view.key];
    if (existing != null) {
      existing.lastSeen = _now();
      return existing;
    }

    final canonical = view.canonical;
    final protocol = protocolName(canonical.protocol);
    final route = matchL3Route(
      _routes,
      canonical.destinationAddress,
      protocol,
      canonical.destinationPort,
    );
    // `matchL3Route` 返回 null 之后才去解释「为什么 null」：先问 SDK 要结论，
    // 拿不到再用放宽条件的同一份判定说明原因。顺序反过来就成了「自己算一份
    // 结论」，两边一旦分叉，日志会开始骗人。
    final explained = route == null
        ? _explainL3Route(canonical, protocol)
        : null;
    final verdict = switch ((route, explained)) {
      (final ATrustRoute _, _) => ShuPacketVerdict.routed,
      (null, final ATrustRoute _) => ShuPacketVerdict.tcpNotL3,
      _ => ShuPacketVerdict.unroutable,
    };

    final flow = ShuPacketFlow(
      key: view.key,
      protocol: view.protocol,
      source: _endpoint(canonical.sourceAddress, canonical.sourcePort),
      destination: _endpoint(
        canonical.destinationAddress,
        canonical.destinationPort,
      ),
      verdict: verdict,
      route: route ?? explained,
      firstSeen: _now(),
    );
    _flows[view.key] = flow;
    flowsSeen++;
    _evictIfNeeded();
    _announce(flow);
    return flow;
  }

  /// 按最久没用过淘汰，直到回到上限之内。
  void _evictIfNeeded() {
    while (_flows.length > maxFlows) {
      String? oldestKey;
      DateTime? oldest;
      for (final entry in _flows.entries) {
        if (oldest == null || entry.value.lastSeen.isBefore(oldest)) {
          oldest = entry.value.lastSeen;
          oldestKey = entry.key;
        }
      }
      if (oldestKey == null) return;
      _flows.remove(oldestKey);
    }
  }

  /// 放宽 `matchL3Route` 的那条 TCP 门之后能命中的资源。
  ///
  /// 与 SDK 的判定**逐条对齐**（协议、端口区间、地址），只少了
  /// `protocol == 'tcp' && !enableTcpPrefL3` 这一条。所以它非空就等价于
  /// 「TCP 门是唯一的原因」—— 对 UDP / ICMP 而言两条判定完全相同，
  /// 永远不会出现「解释得出来但 SDK 说没有」的情况。
  ATrustRoute? _explainL3Route(ATrustPacketMeta meta, String protocol) {
    for (final route in _routes) {
      if (route.protocol != 'all' && route.protocol != protocol) continue;
      if (meta.destinationPort < route.portMin ||
          meta.destinationPort > route.portMax) {
        continue;
      }
      if (!atrustRouteHostCovers(route.host, meta.destinationAddress)) {
        continue;
      }
      return route;
    }
    return null;
  }

  /// 解析一个包。**解析异常一律收敛在这里**。
  ///
  /// `buildPacketMeta` 在头部长度字段与实际长度不符时会抛 `RangeError`
  /// （它直接 `sublistView(data, headerLength)`），而这是数据面的热路径：
  /// 让一个畸形包把整条转发链路（尤其 `observeIngress` 那个 `Stream.map`）
  /// 打断是不可接受的。所以先自己挡一道，再用 try/catch 兜住。
  _PacketView? _parse(Uint8List packet, {required bool egress}) {
    if (packet.length < _ipv4MinHeader || (packet[0] >> 4) != _ipv4Version) {
      return null;
    }
    final headerLength = (packet[0] & 0x0f) * 4;
    if (headerLength < _ipv4MinHeader || headerLength > packet.length) {
      return null;
    }
    try {
      final meta = buildPacketMeta(packet);
      if (meta == null) return null;
      final flags = _tcpFlags(packet);
      return _PacketView(
        raw: meta,
        canonical: egress ? meta : meta.reversed,
        egress: egress,
        protocol: protocolName(meta.protocol).toUpperCase(),
        tag: flags == null
            ? protocolName(meta.protocol).toUpperCase()
            : _tcpFlagLabel(flags),
        bytes: packet.length,
        tcpClosing: flags != null && (flags & (_tcpFin | _tcpRst)) != 0,
      );
    } on Object {
      return null;
    }
  }
}

/// 一个包解析出来、日志要用到的那几项。
class _PacketView {
  const _PacketView({
    required this.raw,
    required this.canonical,
    required this.egress,
    required this.protocol,
    required this.tag,
    required this.bytes,
    required this.tcpClosing,
  });

  /// 包**本身**的五元组（下行包的方向与原包一致）。
  final ATrustPacketMeta raw;

  /// **规范方向**的五元组（永远当作上行看）。五元组 key 由它算，
  /// 所以同一条连接的两个方向落在同一条流上。
  final ATrustPacketMeta canonical;

  final bool egress;
  final String protocol;

  /// `SYN` / `ACK-PSH` / `UDP`：日志里的那个标志词。
  ///
  /// 都大写：它是协议常量（TCP 标志位的名字），不是普通单词。
  final String tag;

  final int bytes;

  /// 这个 TCP 包带 FIN 或 RST。
  final bool tcpClosing;

  String get source => _endpoint(raw.sourceAddress, raw.sourcePort);

  String get destination =>
      _endpoint(raw.destinationAddress, raw.destinationPort);

  String get key => _flowKey(canonical);
}

// --------------------------------------------------------------- 纯函数工具

/// 规范化五元组：两个端点按字典序串起来。
///
/// 这是「上行与下行是同一条连接」在代码里的落点。用规范化的 key 而不是
/// 「上行 key + 反向索引表」：后者要在两个地方维护同一份不变量的两个副本，
/// 而这里只要 key 一样就够。
String _flowKey(ATrustPacketMeta meta) {
  final from = _endpoint(meta.sourceAddress, meta.sourcePort);
  final to = _endpoint(meta.destinationAddress, meta.destinationPort);
  final pair = from.compareTo(to) <= 0 ? '$from|$to' : '$to|$from';
  return '${meta.atype}:${meta.protocol}:$pair';
}

/// `10.1.2.3:443`；ICMP 之类端口为 0 的只写地址。
String _endpoint(String address, int port) =>
    port == 0 ? address : '$address:$port';

/// `812 B` / `1.4 KB` / `2.1 MB`。
///
/// 1024 进制但写作 KB/MB —— 与 Android 自己的流量统计一致。这里要的不是
/// 量纲严谨，而是用户在系统设置里看到的数字能跟日志对上。
String formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

/// `820 ms` / `3.1s` / `1m12s`。
///
/// 与 [formatByteCount] 同一定位：给人在日志里对时间用。1 秒以下用毫秒
/// （那才是连接建立耗时真正所在的量级），以上用秒并保留一位小数。
String formatDuration(Duration duration) {
  final millis = duration.inMilliseconds;
  if (millis < 1000) return '${millis}ms';
  final seconds = millis / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  final minutes = duration.inMinutes;
  return '${minutes}m${duration.inSeconds - minutes * 60}s';
}

/// `0 B/s` / `812 B/s` / `1.4 MB/s`。
///
/// 与 [formatByteCount] 同一套量纲，只是后缀带 `/s` —— 连接页上那一行要
/// 一眼看出这是速率而不是累计量。
String formatRate(double bytesPerSecond) {
  if (bytesPerSecond.isNaN || bytesPerSecond <= 0) return '0 B/s';
  final rounded = bytesPerSecond.round();
  return '${formatByteCount(rounded)}/s';
}

// ------------------------------------------------------------- TCP 包头细节

const int _ipv4Version = 4;
const int _ipv6Version = 6;
const int _ipv4MinHeader = 20;

/// 一个包是 IPv6 吗（只看版本号，不做任何结构校验）。
bool _isIpv6(Uint8List packet) =>
    packet.isNotEmpty && (packet[0] >> 4) == _ipv6Version;

const int _tcpFin = 0x01;
const int _tcpSyn = 0x02;
const int _tcpRst = 0x04;
const int _tcpPsh = 0x08;
const int _tcpAck = 0x10;
const int _tcpUrg = 0x20;

/// IPv4 包里 TCP 头部的标志字节；不是 TCP 或取不到时返回 `null`。
int? _tcpFlags(Uint8List packet) {
  if (packet.length < _ipv4MinHeader) return null;
  final headerLength = (packet[0] & 0x0f) * 4;
  // TCP 头 20 字节，标志位在第 13 字节 —— 不够就说明包被截断了。
  if (headerLength < _ipv4MinHeader || packet.length < headerLength + 14) {
    return null;
  }
  return packet[headerLength + 13];
}

/// 把标志位翻译成 `SYN` / `SYN-ACK` / `ACK-PSH` 这种短标签。
String _tcpFlagLabel(int flags) {
  final names = <String>[
    if (flags & _tcpFin != 0) 'FIN',
    if (flags & _tcpSyn != 0) 'SYN',
    if (flags & _tcpRst != 0) 'RST',
    if (flags & _tcpPsh != 0) 'PSH',
    if (flags & _tcpAck != 0) 'ACK',
    if (flags & _tcpUrg != 0) 'URG',
  ];
  return names.isEmpty ? '-' : names.join('-');
}
