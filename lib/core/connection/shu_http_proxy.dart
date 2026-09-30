import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sangfor/flutter_sangfor.dart';

import '../logging/shu_log.dart';

/// 本机 HTTP 代理，把所有请求转发进 aTrust 隧道。
///
/// ## 为什么除了 SOCKS5 还要这一个
///
/// Android 的**系统代理只支持 HTTP**：设置里的「WLAN → 代理」只有 HTTP 一个
/// 选项，`VpnService.Builder.setHttpProxy` 收的也是 `ProxyInfo`（HTTP）。
/// 没有任何系统开关能把「所有应用都用 SOCKS5」这件事表达出来 ——
/// 于是把浏览器指向一个 SOCKS5 端口，结果就是**一个连接都不会进来**：
/// 那一侧从来不知道要去连它。这不是 SOCKS5 实现的问题，是平台的表达力问题。
///
/// 所以两条通道并存，各自对着不同的消费者：
///
/// | 通道 | 谁在用 |
/// | :--- | :--- |
/// | HTTP（本文件） | 系统/`setHttpProxy` 注入 → 绝大多数应用、浏览器 |
/// | SOCKS5 | 自己支持 SOCKS5 的应用（Firefox、Telegram、部分命令行工具） |
///
/// 两者**共用同一个 [SangforTcpDialer]**，也就是共用同一条隧道、同一套
/// 分流判定（`_dialATrust`），所以「哪个目标走隧道、哪个直连」在两边的答案
/// 一定一样。
///
/// ## 支持哪些请求
///
/// * `CONNECT host:port` —— HTTPS 与一切需要隧道的 TCP，直接升级成裸字节管道；
/// * 绝对形式的普通 HTTP（`GET http://host/path`）—— 改写请求行成 origin
///   形式后转发，请求体与后续字节原样透传。
///
/// 不缓存、不改写正文、不看响应 —— 它是一个管道，不是中间人。
class ShuHttpProxy {
  ShuHttpProxy({
    required this.dialer,
    this.listenAddress,
    this.port = 0,
    this.dialTimeout = const Duration(seconds: 30),
    this.onDialError,
    this.cancellationToken,
  }) : assert(port >= 0 && port <= 65535);

  final SangforTcpDialer dialer;
  final InternetAddress? listenAddress;
  final int port;
  final Duration dialTimeout;
  final void Function(String host, int port, Object error)? onDialError;

  /// 取消时停止接受连接，并拆掉所有在途会话（含正在拨号的那些）。
  final SangforCancellationToken? cancellationToken;

  ServerSocket? _server;
  final Set<_HttpProxySession> _sessions = <_HttpProxySession>{};

  bool get isRunning => _server != null;

  int? get boundPort => _server?.port;

  /// 绑定监听，返回真正绑上的端口。
  ///
  /// 首选 [port]，被占用时**退到系统分配的端口**。退一步是故意的：这条
  /// HTTP 通道是系统 VPN 里 TCP 的唯一出口（见类文档），「相邻端口恰好被
  /// 别的程序占着」不该是整条代理起不来的理由。
  Future<int> start() async {
    if (_server != null) throw StateError('HTTP proxy is already running');
    final address = listenAddress ?? InternetAddress.loopbackIPv4;
    ServerSocket server;
    try {
      server = await ServerSocket.bind(address, port);
    } on SocketException catch (error) {
      if (port == 0) rethrow;
      ShuLog.w(
        ShuLogTag.proxy,
        'HTTP 代理端口 $port 被占用 · ${error.osError?.message ?? error.message}'
        ' · 改用系统分配的端口',
      );
      server = await ServerSocket.bind(address, 0);
    }
    server.listen(
      _accept,
      onError: (Object error) {
        // 监听套接字自己的错误通过会话关闭体现，这里没有可做的事。
      },
    );
    _server = server;
    final token = cancellationToken;
    if (token != null) {
      unawaited(token.whenCancelled.then((_) => close()));
    }
    return server.port;
  }

  void _accept(Socket socket) {
    // 代理的每一次转发都是「小请求、等响应」的形态，Nagle 会平白加上
    // 几十毫秒 —— 浏览器开一堆连接时这个延迟非常明显。
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // 个别平台不允许在 accept 出来的套接字上设它，不影响正确性。
    }
    final session = _HttpProxySession(
      socket: socket,
      dialer: dialer,
      dialTimeout: dialTimeout,
      onDialError: onDialError,
      onFinished: _sessions.remove,
      cancellationToken: cancellationToken,
    );
    _sessions.add(session);
    session.start();
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close();
    final sessions = List<_HttpProxySession>.of(_sessions);
    _sessions.clear();
    for (final session in sessions) {
      await session.close();
    }
  }
}

/// 一条来自应用的 HTTP 代理连接。
class _HttpProxySession {
  _HttpProxySession({
    required this.socket,
    required this.dialer,
    required this.dialTimeout,
    required this.onDialError,
    required this.onFinished,
    this.cancellationToken,
  });

  /// 请求头上限。超过它说明对面根本不是 HTTP 代理客户端（或者有人往里灌
  /// 垃圾），直接拒掉，别把内存交出去。
  static const int maxHeaderBytes = 16 * 1024;

  final Socket socket;
  final SangforTcpDialer dialer;
  final Duration dialTimeout;
  final void Function(String host, int port, Object error)? onDialError;
  final void Function(_HttpProxySession session) onFinished;
  final SangforCancellationToken? cancellationToken;

  final BytesBuilder _head = BytesBuilder(copy: false);
  SangforTcpStream? _upstream;
  Future<void> _sendChain = Future<void>.value();
  StreamSubscription<Uint8List>? _upstreamSubscription;
  StreamSubscription<List<int>>? _clientSubscription;
  bool _tunnelling = false;
  bool _closed = false;

  void start() {
    _clientSubscription = socket.listen(
      (chunk) => _onClientData(Uint8List.fromList(chunk)),
      onDone: _onClientDone,
      onError: (Object _) => close(),
    );
  }

  void _onClientData(Uint8List chunk) {
    if (_closed) return;
    if (_tunnelling) {
      _enqueueSend(chunk);
      return;
    }
    _head.add(chunk);
    if (_head.length > maxHeaderBytes) {
      unawaited(_fail(431, 'Request Header Fields Too Large'));
      return;
    }
    _parseRequest();
  }

  void _parseRequest() {
    final bytes = _head.toBytes();
    final end = _headerEnd(bytes);
    if (end < 0) return;

    final lines = ascii
        .decode(bytes.sublist(0, end), allowInvalid: true)
        .split('\r\n');
    if (lines.isEmpty) {
      unawaited(_fail(400, 'Bad Request'));
      return;
    }
    final parts = lines.first.split(' ');
    if (parts.length < 3) {
      unawaited(_fail(400, 'Bad Request'));
      return;
    }

    // 头之后的字节属于正文/管道，一个都不能丢 —— 客户端常常把请求体
    // 和请求头一起写出来（Pipelining）。
    final carried = Uint8List.fromList(bytes.sublist(end + 4));
    final method = parts[0].toUpperCase();
    final target = parts[1];

    if (method == 'CONNECT') {
      final authority = _splitAuthority(target, 443);
      if (authority == null) {
        unawaited(_fail(400, 'Bad Request'));
        return;
      }
      unawaited(
        _openTunnel(
          authority.$1,
          authority.$2,
          carried,
          replyTunnelEstablished: true,
        ),
      );
      return;
    }

    // `GET http://host/path HTTP/1.1`：把请求行改写成 origin 形式。
    final uri = Uri.tryParse(target);
    if (uri == null || uri.host.isEmpty) {
      unawaited(_fail(400, 'Bad Request'));
      return;
    }
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final rewritten = StringBuffer()
      ..write(method)
      ..write(' ')
      ..write(uri.path.isEmpty ? '/' : uri.path);
    if (uri.hasQuery) rewritten.write('?${uri.query}');
    rewritten.write(' ${parts[2]}');
    for (final header in lines.skip(1)) {
      // `Proxy-Connection` 是代理专用的跳接头，转发出去只会让对面困惑。
      if (header.toLowerCase().startsWith('proxy-connection:')) continue;
      rewritten
        ..write('\r\n')
        ..write(header);
    }
    rewritten.write('\r\n\r\n');

    unawaited(
      _openTunnel(
        uri.host,
        port,
        Uint8List.fromList(<int>[
          ...ascii.encode(rewritten.toString()),
          ...carried,
        ]),
        replyTunnelEstablished: false,
      ),
    );
  }

  Future<void> _openTunnel(
    String host,
    int port,
    Uint8List carried, {
    required bool replyTunnelEstablished,
  }) async {
    SangforTcpStream stream;
    try {
      final token = cancellationToken;
      final dial = token == null
          ? dialer(host, port)
          : token.race(dialer(host, port));
      stream = await dial.timeout(dialTimeout);
    } on Object catch (error) {
      onDialError?.call(host, port, error);
      // 502 是代理的标准答复：**代理**连不上上游，不是客户端请求有错。
      // 用它而不是 500，用户与工具都能立刻分清是谁的问题。
      await _fail(502, 'Bad Gateway');
      return;
    }
    if (_closed) {
      await stream.close();
      return;
    }
    _upstream = stream;
    _tunnelling = true;
    if (replyTunnelEstablished) {
      socket.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
    }
    _upstreamSubscription = stream.incoming.listen(
      socket.add,
      onDone: () async {
        try {
          await socket.flush();
          await socket.close();
        } on Object {
          // 客户端可能已经走了。
        }
      },
      onError: (Object _) => close(),
    );
    if (carried.isNotEmpty) _enqueueSend(carried);
  }

  /// 串行化上行写入：分块必须保序，每块写完再写下一块。
  void _enqueueSend(Uint8List chunk) {
    final stream = _upstream;
    if (stream == null) return;
    _sendChain = _sendChain
        .then((_) async {
          if (_closed || stream.isClosed) return;
          await stream.send(chunk);
        })
        .catchError((Object _) {
          // 发送失败会经由流的错误路径把会话拆掉。
        });
  }

  Future<void> _onClientDone() async {
    final stream = _upstream;
    if (stream == null) {
      await close();
      return;
    }
    try {
      await _sendChain;
      await stream.closeWrite();
    } on Object {
      await close();
    }
  }

  Future<void> _fail(int status, String reason) async {
    if (_closed) return;
    try {
      socket.add(
        ascii.encode(
          'HTTP/1.1 $status $reason\r\n'
          'Content-Length: 0\r\n'
          'Connection: close\r\n\r\n',
        ),
      );
      await socket.flush();
    } on Object {
      // 对面已经断了，那就只是关掉而已。
    }
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _clientSubscription?.cancel();
    await _upstreamSubscription?.cancel();
    socket.destroy();
    await _upstream?.close();
    onFinished(this);
  }

  /// `\r\n\r\n` 里第一个 `\r` 的下标；没找到返回 `-1`。
  static int _headerEnd(Uint8List bytes) {
    for (var index = 3; index < bytes.length; index++) {
      if (bytes[index] == 0x0a &&
          bytes[index - 1] == 0x0d &&
          bytes[index - 2] == 0x0a &&
          bytes[index - 3] == 0x0d) {
        return index - 3;
      }
    }
    return -1;
  }

  /// `host:port` / `[v6]:port` / 裸主机名（用 [fallbackPort]）→ `(host, port)`。
  static (String, int)? _splitAuthority(String value, int fallbackPort) {
    var host = value;
    var port = fallbackPort;
    if (value.startsWith('[')) {
      final close = value.indexOf(']');
      if (close < 0) return null;
      host = value.substring(1, close);
      final rest = value.substring(close + 1);
      if (rest.startsWith(':')) {
        port = int.tryParse(rest.substring(1)) ?? fallbackPort;
      }
    } else {
      final colon = value.lastIndexOf(':');
      if (colon > 0) {
        host = value.substring(0, colon);
        port = int.tryParse(value.substring(colon + 1)) ?? fallbackPort;
      }
    }
    if (host.isEmpty || port <= 0 || port > 65535) return null;
    return (host, port);
  }
}
