import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';

import '../logging/shu_log.dart';
import 'atrust_l3_framing.dart';

/// 给 aTrust 的隧道 TLS 通道穿一层记录，把**握手那一刻的原始字节**留下来。
///
/// ## 为什么需要它
///
/// TCP 隧道握手失败时，SDK 只给两句「只有看过源码才知道在说什么」的话：
///
/// * `StateException: channel closed during TCP tunnel handshake` —— 对端把
///   连接关了（`ATrustTcpTunnelConn._beginListen` 的 `onDone`），**关之前
///   回没回过东西、回了什么，它一个字都不说**；
/// * `TimeoutException after 0:00:18` —— 18 秒内没等到一个完整的握手响应
///   （`ATrustTcpTunnelConn.connect` 的 `timeout` 默认值）。
///
/// 而「服务端到底回了什么」是唯一的真凭据：拒绝的到底是 appId、sid、
/// 目标地址，还是它根本不认这个帧头。那段字节被 SDK 丢在私有的 `_buffer`
/// 里、随对象一起死掉，从外面看不见 —— 所以在这里记一份。
///
/// ## 为什么可以这么做
///
/// [ATrustTunnelChannel] 是只有三个成员的 `abstract interface class`
/// （`incoming` / `send` / `close`），装饰它就是纯转发，不改 SDK 任何行为。
/// 工厂通过 `ATrustConnector(socketFactory: ...)` 注入，L3 与 TCP 隧道**两条**
/// 通道都会经过这里。
///
/// ## 这一层做两件事
///
/// 1. **把服务端的话记下来**。TCP 隧道认出 `05 81 53 00` 这一帧，L3 交给
///    [ShuL3Framer]，把认证负载里的 `status` / `code` / `message` 写成一行
///    日志 —— 那是排障唯一的真凭据。
/// 2. **把那 4 个字节补上**。对端关闭、而我们手上已经有一个**非零**认证码时，
///    在读流末尾补 `05 01 00 00`，让 SDK 的解析器收尾，于是它抛出的不再是
///    「通道被关闭」，而是 `TCP tunnel authentication failed (code N): <服务端原话>`。
///
///    只在「服务端已经明说失败」时才补（`_authError != null`）。认证成功却没
///    等到连接回复的情况**不**走这里，那种失败仍然是原来那句诚实的错误。
///
/// ## L3 那一条为什么也要解析
///
/// 因为它是「TCP 能不能走 L3」这个问题的**唯一**观察窗口。L3 的每一个
/// 五元组第一次出现时都要先发一次流认证请求（`ATrustL3Protocol.authRequest`，
/// 带 `url: "tcp:1.2.3.4:443"` 与 `ip.protocol`），而 SDK 把失败结果丢在
/// `ATrustL3FlowTracker` 里（`tracker.complete(id, error:)`），既不写日志也不
/// 抛给调用方 —— 缓存住的包就这么没了。只有在这一层才看得见服务端回了什么。
///
/// ## 记多少
///
/// 只记**长度与结论**，不记任何字节内容：完整帧里有 sid / deviceId / 账号名，
/// 逐字节转储会把这些带进日志，而且读不出结论。下行的数据帧与心跳一个字节
/// 都不看（只解帧头）。
class ShuATrustChannelProbe implements ATrustTunnelChannel {
  ShuATrustChannelProbe(
    this._inner, {
    required this.id,
    required this.host,
    required this.port,
  });

  /// 握手响应的累积上限。
  ///
  /// 认证失败那一帧只有一百多字节；4 KB 已经很宽松。**必须有上限** ——
  /// 认不出格式时不能把整条连接的数据都攒在内存里。
  static const int _handshakeLimit = 4096;

  final ATrustTunnelChannel _inner;

  /// 连接序号，从 1 开始 —— 日志里靠它把「连上 / 发出 / 收到 / 关闭」串起来。
  final int id;
  final String host;
  final int port;

  Stream<List<int>>? _incoming;
  Uint8List? _firstSend;
  int _sentBytes = 0;
  int _receivedBytes = 0;
  bool _closedLogged = false;
  bool _injected = false;

  final BytesBuilder _handshake = BytesBuilder(copy: false);
  bool _handshakeSettled = false;

  /// 服务端在认证负载里说的话（只有 `code != 0` 时非空）。
  String? _authError;

  /// 认证负载结束的位置；用来判断「连接回复」有没有到。
  int _authOffset = 0;

  // ------------------------------------------------------------------- L3
  //
  // L3 那条通道的帧格式与 TCP 隧道完全不同，而且是**五段式握手 + 连续稳态帧**：
  //
  // | 阶段 | 形状 |
  // | :--- | :--- |
  // | 握手响应 | `05 D0 53 <状态> <长度:2> <JSON> <VIP 头 4B> <VIP 数据 6/18/22 B>` |
  // | 稳态帧 | `05 <命令> <长度:2> <负载>` |
  // | 带状态的帧 | `05 <命令> <状态> <长度:2> <负载>` |
  //
  // 带状态的是 authResponse 与 secondVipResponse（`decodeFrame` 里那两行）。
  //
  // 逐字节的解析在 [ShuL3Framer] 里 —— 那一段被一次错位咬过（VIP 块没吃掉），
  // 所以它必须能被单独喂字节测出来，而不是埋在日志逻辑里。

  final ShuL3Framer _l3 = ShuL3Framer();

  int _l3AuthOk = 0;
  int _l3AuthFailed = 0;

  /// 这条通道在跑哪一套握手。
  ///
  /// 两种握手的首帧同形 —— `05 01 <method> 53 …` —— 只有 method 不同：
  ///
  /// | 通道 | method | 出处 |
  /// | :--- | :--- | :--- |
  /// | TCP 隧道 | `0x81` | `ATrustTcpTunnelProtocol.handshakeMessage` |
  /// | L3 | `0xd0` | `ATrustL3Protocol.authTunnelRequest` |
  bool get _isTcpTunnel {
    final first = _firstSend;
    return first != null &&
        first.length >= 4 &&
        first[2] == 0x81 &&
        first[3] == 0x53;
  }

  bool get _isL3 {
    final first = _firstSend;
    return first != null &&
        first.length >= 4 &&
        first[2] == 0xd0 &&
        first[3] == 0x53;
  }

  String get _kind {
    if (_firstSend == null) return '未知';
    if (_isTcpTunnel) return 'TCP 隧道';
    if (_isL3) return 'L3';
    return '未知';
  }

  @override
  Stream<List<int>> get incoming => _incoming ??= _wrap(_inner.incoming);

  @override
  Future<void> send(Uint8List bytes) async {
    _sentBytes += bytes.length;
    if (_firstSend == null) {
      _firstSend = bytes;
      ShuLog.d(
        ShuLogTag.proxy,
        'aTrust 通道 #$id $_kind → 首个帧 ${bytes.length} B',
      );
    }
    await _inner.send(bytes);
  }

  @override
  Future<void> close() async {
    _report('本地关闭');
    await _inner.close();
  }

  /// 把「对端关了 / 出错了」记成一行。同一条通道只记一次，
  /// 谁先撒手就是谁的原因。
  void _report(String reason) {
    if (_closedLogged) return;
    _closedLogged = true;
    final received = _receivedBytes == 0 ? '对端未回字节' : '收到 $_receivedBytes B';
    final detail = _authError == null ? '' : ' · 服务端说 $_authError';
    ShuLog.w(
      ShuLogTag.proxy,
      'aTrust 通道 #$id $_kind $reason · 发出 $_sentBytes B · $received'
      '${_l3Summary()}$detail',
    );
  }

  /// L3 那三个读数。
  ///
  /// **「握手之后收到多少」是这一轮实验最直接的一个数**：它等于「服务端
  /// 在承认握手之后还说了多少话」。为零就是明确的「一个字节都没答」，
  /// 有值而流认证计数为零就是「答了，但不是流认证的答复」。
  String _l3Summary() {
    if (!_l3.handshakeDone) return '';
    final postHandshake = _receivedBytes - _l3.handshakeBytes;
    final auth = _l3AuthOk + _l3AuthFailed == 0
        ? ''
        : ' · 流认证 通过 $_l3AuthOk 失败 $_l3AuthFailed';
    return ' · L3 握手之后收到 $postHandshake B'
        ' · 数据帧 ${_l3.dataFrames}${_l3.heartbeats == 0 ? '' : ' · 心跳 ${_l3.heartbeats}'}'
        '$auth';
  }

  /// 原样转发 + 观察。单订阅透传：SDK 只监听一次，这里不改变这个事实。
  Stream<List<int>> _wrap(Stream<List<int>> source) {
    StreamSubscription<List<int>>? subscription;
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        subscription = source.listen(
          (chunk) {
            _tapIncoming(chunk);
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            _report('出错：$error');
            controller.addError(error, stackTrace);
          },
          onDone: () {
            // 服务端已经明说失败、却因为「少了 4 字节连接回复」被 SDK 吞掉 ——
            // 把那 4 字节补上，让真实错误浮出来。见类文档。
            final needsReply =
                _authError != null && _receivedBytes < _authOffset + 4;
            if (needsReply && !_injected) {
              _injected = true;
              controller.add(Uint8List.fromList(<int>[0x05, 0x01, 0x00, 0x00]));
              ShuLog.w(
                ShuLogTag.proxy,
                'aTrust 通道 #$id TCP 隧道 对端关闭且未回连接回复 · '
                '已补 4 字节让 SDK 抛出服务端的原话',
              );
            }
            _report('被对端关闭');
            controller.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  void _tapIncoming(List<int> chunk) {
    _receivedBytes += chunk.length;
    if (_isTcpTunnel) {
      _tapHandshake(chunk);
    } else if (_isL3) {
      _tapL3(chunk);
    }
  }

  /// 从 TCP 隧道握手响应里读出服务端的结论。
  ///
  /// 帧形如 `05 81 53 00 [len:2] [JSON] [连接回复]`，与
  /// `ATrustTcpTunnelConn._handleHandshakeChunk` 认的是同一套。
  void _tapHandshake(List<int> chunk) {
    if (_handshakeSettled || !_isTcpTunnel) return;
    if (_handshake.length + chunk.length > _handshakeLimit) {
      // 不是我们认得的形状，别再攒了。
      _handshakeSettled = true;
      return;
    }
    _handshake.add(chunk);
    final bytes = _handshake.toBytes();
    if (bytes.length < 6) return;
    if (bytes[0] != 0x05 || bytes[1] != 0x81 || bytes[2] != 0x53) return;
    final authLength = (bytes[4] << 8) | bytes[5];
    if (bytes.length < 6 + authLength) return;

    _authOffset = 6 + authLength;
    _handshakeSettled = true;

    final Map<String, Object?> payload;
    try {
      final decoded = jsonDecode(
        utf8.decode(bytes.sublist(6, _authOffset), allowMalformed: true),
      );
      if (decoded is! Map) return;
      payload = Map<String, Object?>.from(decoded);
    } on Object {
      // 解不出来就只说「被拒了」，不猜内容。
      _authError = '认证负载不是 JSON';
      ShuLog.w(ShuLogTag.proxy, 'aTrust 通道 #$id TCP 隧道 握手中被拒 · $_authError');
      return;
    }

    final code = payload['code'] is int
        ? payload['code'] as int
        : int.tryParse('${payload['code'] ?? 0}') ?? 0;
    if (code == 0) return;
    _authError = 'code $code: ${payload['message'] ?? ''}';
    ShuLog.w(
      ShuLogTag.proxy,
      'aTrust 通道 #$id TCP 隧道 被服务端拒绝 · $_authError'
      '${bytes.length >= _authOffset + 4 ? '' : ' · 未回连接回复'}',
    );
  }

  // ------------------------------------------------------------------ L3 观察

  /// 把 L3 字节喂给解析器，把解出来的语义写成日志。
  void _tapL3(List<int> chunk) {
    for (final notice in _l3.add(chunk)) {
      _logL3(notice);
    }
  }

  void _logL3(ShuL3Notice notice) {
    switch (notice.kind) {
      case ShuL3NoticeKind.handshakeAccepted:
        // 昇到 INFO：每条通道只有一次，而它不在日志里的时候分不清是
        // 「解析挂了」还是「服务端没回」。虚拟地址顺带写出来 —— 它是
        // 握手被完整吃掉（含 VIP 那一段）的证明。
        ShuLog.i(
          ShuLogTag.proxy,
          '[L3] 通道 #$id 握手完成 · deviceId ${notice.deviceId ?? "-"}'
          ' · VIP ${_join(notice.virtualAddresses)}',
        );
      case ShuL3NoticeKind.handshakeRejected:
        _authError =
            'L3 握手 status=${notice.status}'
            '${notice.code == null ? '' : ' · code ${notice.code}'}'
            '${notice.message == null ? '' : ' · ${notice.message}'}';
        ShuLog.w(ShuLogTag.proxy, '[L3] 通道 #$id 握手被拒 · $_authError');
      case ShuL3NoticeKind.flowAuthAccepted:
        _l3AuthOk++;
        if (_l3AuthOk <= 3 || _l3AuthOk % 50 == 0) {
          ShuLog.i(ShuLogTag.proxy, '[L3] 通道 #$id 流认证通过 · 累计 $_l3AuthOk 条');
        }
      case ShuL3NoticeKind.flowAuthRejected:
        _l3AuthFailed++;
        if (_l3AuthFailed > 5 && _l3AuthFailed % 50 != 0) return;
        // `0x84` 与 `0x85..0x87` 在 SDK 里是**重试**信号
        // （`ATrustL3TunnelConnection._handleAuthResponse`），不是终局 ——
        // 分开说，否则会把一次重试读成一次硬拒绝。
        final verdict = switch (notice.status) {
          0x84 => '要求立即重试',
          >= 0x85 && <= 0x87 => '要求稍后重试',
          _ => '被拒',
        };
        ShuLog.w(
          ShuLogTag.proxy,
          '[L3] 通道 #$id 流认证$verdict'
          ' · status=0x${notice.status.toRadixString(16)}'
          '${notice.code == null || notice.code == 0 ? '' : ' · code ${notice.code}'}'
          '${notice.message == null ? '' : ' · ${notice.message}'}'
          ' · 累计失败 $_l3AuthFailed 条',
        );
      case ShuL3NoticeKind.secondVip:
        ShuLog.d(
          ShuLogTag.proxy,
          '[L3] 通道 #$id 二次 VIP 下发 · status=${notice.status}'
          ' · ${_join(notice.virtualAddresses)}',
        );
      case ShuL3NoticeKind.unparsable:
        ShuLog.w(
          ShuLogTag.proxy,
          '[L3] 通道 #$id 的帧认不出来 · ${notice.reason}'
          ' · 已停止观察这一条通道 · 之前的流量统计仍准确',
        );
    }
  }

  static String _join(List<String> addresses) =>
      addresses.isEmpty ? '-' : addresses.join(', ');
}

/// 把 [ATrustTunnelSocketFactory] 包一层：记下 TLS 建连的结果与耗时，
/// 并把之后的通道换成 [ShuATrustChannelProbe]。
///
/// 不传 [inner] 时用 SDK 的默认工厂（`atrustDefaultSocketFactory()`），
/// 也就是本应用原来那条路径 —— 这个包装不改变任何行为。
ATrustTunnelSocketFactory shuProbedSocketFactory([
  ATrustTunnelSocketFactory? inner,
]) {
  final base = inner ?? atrustDefaultSocketFactory();
  var counter = 0;
  return (String host, int port) async {
    final id = ++counter;
    final started = DateTime.now();
    final channel = await base(host, port);
    ShuLog.d(
      ShuLogTag.proxy,
      'aTrust 通道 #$id TLS 已建 $host:$port · '
      '${DateTime.now().difference(started).inMilliseconds} ms',
    );
    return ShuATrustChannelProbe(channel, id: id, host: host, port: port);
  };
}
