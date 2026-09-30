import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sangfor/flutter_sangfor.dart';

import '../logging/shu_log.dart';
import 'vpn_packet_log.dart';

/// 两条数据面的流量账本。
///
/// ## 为什么需要它
///
/// 数据面有两条，各记各的账：
///
/// | 数据面 | 字节从哪来 | 层次 |
/// | :--- | :--- | :--- |
/// | 系统 VPN（TUN） | `ShuPacketObserver` 逐包累加 | IP 层（含包头） |
/// | 本机代理（HTTP + SOCKS5） | 本文件，在流上包一层 | TCP 载荷层 |
///
/// 两条**不会重复计数**：交给 TUN 的只有 UDP 网段（见 `vpn_routes.dart` 的
/// `l3Routes`），TCP 全部走代理，两者的字节集合不相交。
///
/// 层次不同（一个含 IP 头、一个不含）这件事不打算抹平：这两个数字的用途是
/// 「连接页上那行实时速率」，用户在系统设置里对的是同一量级的量；为了对齐
/// 包头去人为加减反而是编造数据。
///
/// ## 逐连接日志
///
/// 代理这一侧每条连接写两行，与 Clash 的连接日志同形：
///
/// ```text
/// [TCP] 10.0.0.2:52314 --> 202.120.117.50:443 match 128.0.0.0/1/tcp:443 via tunnel
/// [TCP] 10.0.0.2:52314 --> 202.120.117.50:443 closed, up 4 pkt 812 B, down 9 pkt 8.4 KB, 1.2s
/// ```
///
/// 上行字节按 `send` 的入参算，下行按 `incoming` 的每个 chunk 算 —— 都是
/// **隧道里真正过去的量**，不是应用写出来的量。
class ShuTrafficMeter {
  /// 应用 → 隧道（代理这一侧）。
  int upBytes = 0;

  /// 隧道 → 应用（代理这一侧）。
  int downBytes = 0;

  /// 建起来过的连接数（含已经关掉的）。
  int connectionsOpened = 0;

  /// 建连失败次数（隧道拒绝、目标不在资源表内、TLS 出错）。
  int dialFailures = 0;

  /// 隧道 TCP 建连耗时的指数滑动平均（毫秒）；一次样本都还没有时为 `null`。
  ///
  /// 用滑动平均而不是最后一次：单次建连会被一次 DNS 超时或者一次 TCP 重传
  /// 拉得很难看，而这一格要回答的是「现在这条隧道快不快」。
  /// 系数 0.3 —— 大约三四次样本之后新值就占主导。
  double? latencyMs;

  /// 记一次建连耗时样本。
  void sampleLatency(Duration duration) {
    final sample = duration.inMicroseconds / 1000;
    final previous = latencyMs;
    latencyMs = previous == null ? sample : previous * 0.7 + sample * 0.3;
  }

  /// 把一条已经建好的代理流包上计数与收尾日志。
  ///
  /// [target] 与 [routeLabel] 由调用方给：只有它知道这条连接命中了哪条资源，
  /// 而那一项正是日志里最有用的部分。
  SangforTcpStream wrap(
    SangforTcpStream inner, {
    required String target,
    required String routeLabel,
  }) => _MeteredStream(
    inner,
    meter: this,
    target: target,
    routeLabel: routeLabel,
  );
}

/// 计数 + 收尾日志的流包装。除 [send] / [incoming] 外一律原样转发。
class _MeteredStream implements SangforTcpStream {
  _MeteredStream(
    this._inner, {
    required this.meter,
    required this.target,
    required this.routeLabel,
  }) : _started = DateTime.now();

  final SangforTcpStream _inner;
  final ShuTrafficMeter meter;
  final String target;
  final String routeLabel;
  final DateTime _started;

  int _upPackets = 0;
  int _downPackets = 0;

  /// 每条连接的字节数单独记：meter 上是全局累计，收尾那一行要的是这一条。
  int _upBytes = 0;
  int _downBytes = 0;

  Stream<Uint8List>? _wrapped;
  bool _closedLogged = false;

  @override
  Stream<Uint8List> get incoming => _wrapped ??= _inner.incoming.map((chunk) {
    _downPackets++;
    _downBytes += chunk.length;
    meter.downBytes += chunk.length;
    return chunk;
  });

  @override
  bool get isClosed => _inner.isClosed;

  @override
  Future<void> send(Uint8List data) {
    _upPackets++;
    _upBytes += data.length;
    meter.upBytes += data.length;
    return _inner.send(data);
  }

  @override
  Future<void> closeWrite() => _inner.closeWrite();

  @override
  Future<void> close() async {
    _closeLog();
    await _inner.close();
  }

  /// 收尾那一行。同一条连接只写一次 —— `close` 与对端关闭都可能先到。
  void _closeLog() {
    if (_closedLogged) return;
    _closedLogged = true;
    final elapsed = DateTime.now().difference(_started);
    ShuLog.i(
      ShuLogTag.proxy,
      '[TCP] $target closed, '
      'up $_upPackets pkt ${formatByteCount(_upBytes)}, '
      'down $_downPackets pkt ${formatByteCount(_downBytes)}, '
      '${formatDuration(elapsed)} · $routeLabel',
    );
  }
}
