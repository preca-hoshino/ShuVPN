import 'dart:convert';

/// L3 通道上值得记下来的一件事。**只有语义，没有字节。**
enum ShuL3NoticeKind {
  /// 认证通道的握手被服务端接受。
  handshakeAccepted,

  /// 握手被拒：`status` 非零，或认证负载里的 `code` 非零。
  handshakeRejected,

  /// 一条五元组的流认证被接受。这是「TCP 能不能走 L3」这个问题的正面答案。
  flowAuthAccepted,

  /// 流认证没被接受（含 `0x84` / `0x85..0x87` 那两种「要求重试」）。
  flowAuthRejected,

  /// 服务端重新下发虚拟地址。
  secondVip,

  /// 帧格式不是 SDK 认得的那个样子。
  ///
  /// **看到它就该先怀疑这个解析器，而不是服务端** —— 服务端说的话
  /// 在 [ShuL3Notice.reason] 里，而那句话是「结构」类的，不是「数据」类的。
  unparsable,
}

/// 一条 L3 通知。
class ShuL3Notice {
  const ShuL3Notice({
    required this.kind,
    this.status = 0,
    this.code,
    this.message,
    this.deviceId,
    this.virtualAddresses = const <String>[],
    this.reason,
  });

  final ShuL3NoticeKind kind;

  /// 帧头里的状态字节。`authResponse` 与 `secondVipResponse` 才有。
  final int status;

  /// 认证负载 JSON 里的 `code`。解不出来时为 null。
  final int? code;

  /// 认证负载 JSON 里的 `message`。那是**服务端的原话**。
  final String? message;

  /// 认证负载 JSON 里的 `data.deviceId`。
  final String? deviceId;

  /// VIP 数据段里的地址。
  final List<String> virtualAddresses;

  /// [ShuL3NoticeKind.unparsable] 的原因。
  ///
  /// 它只说**结构**（`稳态帧命令 0x0，不在 SDK 认得的七个里`），不吐字节 ——
  /// 与 `shu_log.dart` 里那条「任何等级都不打原始字节转储」一致：单个字段值
  /// 是结构的一部分，字节序列不是。
  final String? reason;
}

/// 把 L3 通道的下行字节切成帧，只留下语义。
///
/// ## 它逐字节镜像 SDK 的解析器
///
/// `ATrustL3HandshakeParser`（五个阶段）与 `ATrustL3FrameStreamDecoder`
/// 是唯一正确的参考。这里是它们的**只读镜像**：不多吃一个不被它们吃掉的
/// 字节，也不接受任何它们要抛异常的字节。
///
/// 握手响应的形状：
///
/// ```
/// 05 D0 53 <状态:1> <认证长度:2> <认证 JSON> <VIP 头:4> <VIP 数据:6|18|22>
/// ```
///
/// ## VIP 那一段为什么必须吃掉
///
/// `ATrustL3Protocol.authTunnelRequest` 发出的请求里就带着同样的一串
/// `05 04 00 01 00 00 00 00 00 00`，服务端把其中的地址填成真实虚拟地址回过来。
/// 漏掉它的后果**不是「少解析一点」，而是从握手结束起整条通道全部错位**：
///
/// * `05 00 00 01` 会被稳态帧解码器当成 `command = 0x0`、长度 1 的一帧吃掉
///   五个字节；
/// * 于是下一个「首字节」落在 VIP 地址的**第二个字节**上。
///
/// 实测的读数正是这样：VIP 是 `10.95.x.x`，第二个字节是 `0x5f`，于是 62 条
/// 通道全部报 `稳态帧首字节 0x5f` —— 一个看着像噪声、其实是账号级常量的值。
///
/// 所以 [add] 对**未知命令**直接判失败：`0x0` 根本不在 SDK 认得的七个命令里，
/// 早一步说出来就不用反推了。
class ShuL3Framer {
  ShuL3Framer({this.bufferLimit = 64 * 1024});

  /// 缓冲上限。认不出格式时不能把整条连接的数据都攒在内存里。
  final int bufferLimit;

  /// 协议版本号。握手、稳态帧、VIP 头三处的第一个字节都是它。
  static const int _version = 0x05;

  /// `ATrustL3Protocol.authTunnelRequest` 的第三个字节。
  static const int _authTunnelMethod = 0xd0;

  static const int _authResponse = 0x93;
  static const int _secondVipResponse = 0x96;
  static const int _dataResponse = 0x94;
  static const int _heartbeatResponse = 0x95;

  /// `ATrustL3Command` 的全部取值。
  ///
  /// SDK 的 `decodeFrame` 对未知命令直接抛 `unknown aTrust L3 command 0x..`，
  /// 这里必须同样严格 —— 宽松地「跳过看不懂的」正是上次那个 bug 的成因。
  static const Set<int> _knownCommands = <int>{
    0x13,
    0x14,
    0x15,
    0x93,
    0x94,
    0x95,
    0x96,
  };

  final List<int> _buffer = <int>[];

  /// 握手整段吃掉之后一共占了多少字节。
  ///
  /// 调用方拿「这条通道总共收到多少字节」减去它就是「握手之后服务端还说了
  /// 多少」—— 「服务端到底答不答流认证」这个问题最直接的一个读数。
  int handshakeBytes = 0;

  /// 服务端推回来的数据帧条数。大于零就说明隧道那一侧真的在发数据。
  int dataFrames = 0;

  /// 心跳响应条数。
  int heartbeats = 0;

  bool _handshakeDone = false;
  bool _stopped = false;
  String? _failureReason;

  bool get handshakeDone => _handshakeDone;

  /// 已经停止观察这一条通道（格式不对，或对端已经明确拒绝）。
  bool get stopped => _stopped;

  String? get failureReason => _failureReason;

  /// 喂一段下行字节，返回这一段里解出来的所有通知。
  ///
  /// 返回空列表有两种含义：**还不够**，或者已经停止观察 —— 用 [stopped] 区分。
  List<ShuL3Notice> add(List<int> chunk) {
    if (_stopped) return const <ShuL3Notice>[];
    if (_buffer.length + chunk.length > bufferLimit) {
      return <ShuL3Notice>[_fail('缓冲超过 $bufferLimit B')];
    }
    _buffer.addAll(chunk);

    final notices = <ShuL3Notice>[];
    if (!_handshakeDone) {
      final notice = _readHandshake();
      if (notice == null) return notices;
      notices.add(notice);
      if (_stopped) return notices;
    }
    while (true) {
      final step = _decodeOne();
      final notice = step.notice;
      if (notice != null) notices.add(notice);
      if (notice?.kind == ShuL3NoticeKind.unparsable) break;
      // 「吃掉了一帧但没有什么要上报」—— 数据帧与心跳就是这样 —— 必须与
      // 「数据还不够」分开：混为一谈的话，一条数据帧之后的**所有**帧都再也
      // 解不出来，而且会一直堆在缓冲里直到超上限。
      if (!step.consumed) break;
    }
    return notices;
  }

  /// 停止观察并说一句为什么。
  ShuL3Notice _fail(String why) {
    _stopped = true;
    _failureReason = why;
    _buffer.clear();
    return ShuL3Notice(kind: ShuL3NoticeKind.unparsable, reason: why);
  }

  // ------------------------------------------------------------------ 握手

  /// 解一次握手响应；不够返回 null。
  ShuL3Notice? _readHandshake() {
    final buffer = _buffer;
    if (buffer.length < 2) return null;
    if (buffer[0] != _version || buffer[1] != _authTunnelMethod) {
      return _fail(
        '握手首字节 0x${buffer[0].toRadixString(16)} '
        '0x${buffer[1].toRadixString(16)}，不是 0x05 0xd0',
      );
    }
    if (buffer.length < 6) return null;
    if (buffer[2] != 0x53) {
      return _fail('握手第 3 字节 0x${buffer[2].toRadixString(16)}，不是 0x53');
    }
    final status = buffer[3];
    if (status != 0) {
      // SDK 在这一步 `throw FormatException('L3 tunnel auth status N')`，
      // 后面的字节再没有对齐依据 —— 停止观察是唯一诚实的做法。
      _stopped = true;
      _failureReason = '握手状态 $status';
      _buffer.clear();
      return ShuL3Notice(
        kind: ShuL3NoticeKind.handshakeRejected,
        status: status,
      );
    }

    final authLength = (buffer[4] << 8) | buffer[5];
    if (buffer.length < 6 + authLength) return null;
    final payload = buffer.sublist(6, 6 + authLength);

    final vipOffset = 6 + authLength;
    if (buffer.length < vipOffset + 4) return null;
    if (buffer[vipOffset] != _version) {
      return _fail(
        'VIP 头首字节 0x${buffer[vipOffset].toRadixString(16)}，不是 0x05'
        ' · 认证长度 $authLength',
      );
    }
    if (buffer[vipOffset + 1] != 0) {
      return _fail('VIP 头状态 ${buffer[vipOffset + 1]}');
    }
    final vipLength = switch (buffer[vipOffset + 3]) {
      1 => 6,
      4 => 18,
      5 => 22,
      _ => -1,
    };
    if (vipLength < 0) {
      return _fail('VIP 地址类型 ${buffer[vipOffset + 3]}，不是 1 / 4 / 5');
    }
    if (buffer.length < vipOffset + 4 + vipLength) return null;

    final vipData = buffer.sublist(vipOffset + 4, vipOffset + 4 + vipLength);
    buffer.removeRange(0, vipOffset + 4 + vipLength);
    handshakeBytes = vipOffset + 4 + vipLength;
    _handshakeDone = true;

    final fields = _jsonFields(payload);
    final addresses = _virtualAddresses(vipData);
    final code = fields.code;
    if (code != null && code != 0) {
      // 与 status 非零同理：SDK 抛 `L3 tunnel auth failed`，通道到此为止。
      _stopped = true;
      _failureReason = '认证 code $code';
      return ShuL3Notice(
        kind: ShuL3NoticeKind.handshakeRejected,
        code: code,
        message: fields.message,
        deviceId: fields.deviceId,
        virtualAddresses: addresses,
      );
    }
    return ShuL3Notice(
      kind: ShuL3NoticeKind.handshakeAccepted,
      code: code,
      message: fields.message,
      deviceId: fields.deviceId,
      virtualAddresses: addresses,
    );
  }

  // ---------------------------------------------------------------- 稳态帧

  /// 解一帧稳态帧。
  ///
  /// 返回 `consumed` 与 `notice` 两项而不是一个可空的 `notice`：
  /// **「吃掉了一帧」与「有话要说」是两件事**。数据帧、心跳、以及三个上行
  /// 命令都是前者而非后者 —— 混为一谈会让循环在第一条数据帧处收手，其后
  /// 的帧再也解不出来，还会一直堆到超上限。
  ({bool consumed, ShuL3Notice? notice}) _decodeOne() {
    const stalled = (consumed: false, notice: null);
    final buffer = _buffer;
    if (buffer.length < 4) return stalled;
    if (buffer[0] != _version) {
      return (
        consumed: true,
        notice: _fail('稳态帧首字节 0x${buffer[0].toRadixString(16)}，不是 0x05'),
      );
    }
    final command = buffer[1];
    if (!_knownCommands.contains(command)) {
      return (
        consumed: true,
        notice: _fail('稳态帧命令 0x${command.toRadixString(16)}，不在 SDK 认得的七个里'),
      );
    }
    // 只有这两个命令在长度前多一个状态字节，与 `decodeFrame` 一致。
    final hasStatus = command == _authResponse || command == _secondVipResponse;
    final header = hasStatus ? 5 : 4;
    if (buffer.length < header) return stalled;
    final status = hasStatus ? buffer[2] : 0;
    final offset = hasStatus ? 3 : 2;
    final length = (buffer[offset] << 8) | buffer[offset + 1];
    if (buffer.length < header + length) return stalled;
    final payload = buffer.sublist(header, header + length);
    buffer.removeRange(0, header + length);

    switch (command) {
      case _dataResponse:
        dataFrames++;
        return (consumed: true, notice: null);
      case _heartbeatResponse:
        heartbeats++;
        return (consumed: true, notice: null);
      case _authResponse:
        return (consumed: true, notice: _flowAuth(payload, status));
      case _secondVipResponse:
        return (
          consumed: true,
          notice: ShuL3Notice(
            kind: ShuL3NoticeKind.secondVip,
            status: status,
            virtualAddresses: _extractVipAddresses(payload),
          ),
        );
      default:
        // authRequest / dataRequest / heartbeatRequest 是上行命令，
        // 服务端不会发；认得出所以放过，但不记。
        return (consumed: true, notice: null);
    }
  }

  /// 一条流的 L3 认证结论。
  ShuL3Notice _flowAuth(List<int> payload, int status) {
    final fields = _jsonFields(payload);
    final code = fields.code ?? 0;
    if (status == 0 && code == 0) {
      return const ShuL3Notice(kind: ShuL3NoticeKind.flowAuthAccepted);
    }
    return ShuL3Notice(
      kind: ShuL3NoticeKind.flowAuthRejected,
      status: status,
      code: fields.code,
      message: fields.message,
    );
  }

  // -------------------------------------------------------------------- 工具

  /// 从一帧 JSON 负载里取出那三项。解不出来时三项都是 null。
  ///
  /// 解不出来**不算失败**：`_handleAuthResponse` 遇到解不开的负载是静默
  /// `return`，不是抛异常，所以这里也必须放过。
  static ({int? code, String? message, String? deviceId}) _jsonFields(
    List<int> payload,
  ) {
    const empty = (code: null, message: null, deviceId: null);
    if (payload.isEmpty) return empty;
    try {
      final decoded = jsonDecode(utf8.decode(payload, allowMalformed: true));
      if (decoded is! Map) return empty;
      final map = Map<String, Object?>.from(decoded);
      final rawCode = map['code'];
      final data = map['data'] is Map
          ? Map<String, Object?>.from(map['data'] as Map)
          : const <String, Object?>{};
      return (
        code: rawCode is int ? rawCode : int.tryParse('$rawCode'),
        message: map['message']?.toString(),
        deviceId: data['deviceId']?.toString(),
      );
    } on Object {
      return empty;
    }
  }

  /// 从 VIP 数据段里取地址。长度决定地址族，与 `parseVirtualIPData` 一致。
  ///
  /// 18 与 22 两档的 IPv6 **只有前 16 个字节**（`parseVirtualIPData` 取的是
  /// `sublist(0, 16)`），多出来的一两个字节是留白 —— 把留白也当成一组会
  /// 在地址尾巴上多出一个 `:0`。
  static List<String> _virtualAddresses(List<int> data) =>
      switch (data.length) {
        6 => <String>['${data[0]}.${data[1]}.${data[2]}.${data[3]}'],
        18 => <String>[_ipv6(data.sublist(0, 16))],
        22 => <String>[
          '${data[0]}.${data[1]}.${data[2]}.${data[3]}',
          _ipv6(data.sublist(4, 20)),
        ],
        _ => const <String>[],
      };

  /// `secondVipResponse` 的负载是 JSON，地址在 `vip` / `vip6` 里 ——
  /// 形状与 `extractVIPs` 一致。只收得下能解析成地址的那两个字段。
  static List<String> _extractVipAddresses(List<int> payload) {
    try {
      final decoded = jsonDecode(utf8.decode(payload, allowMalformed: true));
      if (decoded is! Map) return const <String>[];
      final root = Map<String, Object?>.from(decoded);
      final data = root['data'] is Map
          ? Map<String, Object?>.from(root['data'] as Map)
          : const <String, Object?>{};
      var vip = root['vip']?.toString() ?? '';
      var vip6 = root['vip6']?.toString() ?? '';
      if (vip.isEmpty && vip6.isEmpty) {
        vip = data['vip']?.toString() ?? '';
        vip6 = data['vip6']?.toString() ?? '';
      }
      return <String>[if (vip.isNotEmpty) vip, if (vip6.isNotEmpty) vip6];
    } on Object {
      return const <String>[];
    }
  }

  /// 不压缩写法：`0:0:0:0:0:0:0:0`。压缩规则（`::`）会让人去猜被省掉的是
  /// 哪几组，而这里的地址是拿来和别的日志对账的。
  static String _ipv6(List<int> bytes) => <String>[
    for (var index = 0; index + 1 < bytes.length; index += 2)
      ((bytes[index] << 8) | bytes[index + 1]).toRadixString(16),
  ].join(':');
}
