// 「本机 HTTP 代理」的离线单测。
//
// 它为什么值得单独测：Android 的系统代理**只支持 HTTP**，而系统 VPN 的 TCP
// 那一半完全靠这条通道（aTrust 的 L3 数据面只背得动 UDP）。也就是说，
// 这个文件里这几条协议行为错了，用户的浏览器就是「连上了但什么也打不开」。
//
// 全部走 loopback：上游用一个真的 `ServerSocket`，拨号用真的 `SocketTcpStream`
// —— 不 mock `dart:io`，因为被验证的正是「字节有没有被原样搬过去」。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/shu_http_proxy.dart';

/// loopback 上的往返等一会儿。本地回环一次往返远小于它，只是为了让测试
/// 不依赖调度顺序。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

/// 一个最小的上游：连上来先发一句问候，之后把收到的字节原样回送。
Future<ServerSocket> _startEcho(StreamController<List<int>> received) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    socket.add(utf8.encode('HELLO'));
    socket.listen((chunk) {
      received.add(chunk);
      socket.add(chunk);
    }, onError: (Object _) {});
  });
  return server;
}

/// 拨到那个上游去 —— 不管目标是谁，这正是「隧道」在本测试里的替身。
SangforTcpDialer _dialerTo(ServerSocket upstream) =>
    (host, port) async => SocketTcpStream(
      await Socket.connect(InternetAddress.loopbackIPv4, upstream.port),
    );

/// 读侧的一个小收集器：代理是先回协议头、再搬字节的，所以断言看的是累积文本。
class _Reader {
  _Reader(Socket socket) {
    socket.listen(
      (chunk) => text.write(utf8.decode(chunk, allowMalformed: true)),
      onError: (Object _) {},
    );
  }

  final StringBuffer text = StringBuffer();

  @override
  String toString() => text.toString();
}

void main() {
  group('ShuHttpProxy', () {
    test('CONNECT 升级成裸管道，两个方向都原样搬字节', () async {
      final received = StreamController<List<int>>();
      final upstream = await _startEcho(received);
      final proxy = ShuHttpProxy(dialer: _dialerTo(upstream));
      final port = await proxy.start();

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = _Reader(client);
      await _settle();

      client.add(
        utf8.encode(
          'CONNECT example.com:443 HTTP/1.1\r\n'
          'Host: example.com:443\r\n\r\n',
        ),
      );
      await _settle();

      expect(
        reader.toString(),
        startsWith('HTTP/1.1 200 Connection Established'),
      );
      expect(reader.toString(), contains('HELLO'), reason: '下行必须原样搬过来');

      client.add(utf8.encode('PING'));
      await _settle();
      expect(reader.toString(), endsWith('PING'), reason: '上行必须原样送进隧道');

      await client.close();
      await proxy.close();
      await upstream.close();
      // 这个 controller 没有监听者，`close()` 的 Future 不会完成 —— 不该 await。
      unawaited(received.close());
    });

    test('CONNECT 的目标主机与端口按原样交给拨号器', () async {
      String? seenHost;
      int? seenPort;
      final upstream = await _startEcho(StreamController<List<int>>());
      final proxy = ShuHttpProxy(
        dialer: (host, port) async {
          seenHost = host;
          seenPort = port;
          return SocketTcpStream(
            await Socket.connect(InternetAddress.loopbackIPv4, upstream.port),
          );
        },
      );
      final port = await proxy.start();

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      client.add(utf8.encode('CONNECT 10.10.1.5:1688 HTTP/1.1\r\n\r\n'));
      await _settle();

      // 域名不在这里被解析：拨号那一侧要拿原始域名去比资源表
      // （`matchTcpRoute` 是按名字比的），解析了反而判不出来。
      expect(seenHost, '10.10.1.5');
      expect(seenPort, 1688);

      await client.close();
      await proxy.close();
      await upstream.close();
    });

    test('普通 HTTP 的绝对形式被改写成 origin 形式，Proxy-Connection 被丢掉', () async {
      final received = StreamController<List<int>>();
      final upstream = await _startEcho(received);
      final seen = <int>[];
      final firstChunk = Completer<String>();
      received.stream.listen((chunk) {
        seen.addAll(chunk);
        if (!firstChunk.isCompleted) {
          firstChunk.complete(utf8.decode(seen, allowMalformed: true));
        }
      });

      final proxy = ShuHttpProxy(dialer: _dialerTo(upstream));
      final port = await proxy.start();

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      client.add(
        utf8.encode(
          'GET http://example.com/a/b?c=d HTTP/1.1\r\n'
          'Host: example.com\r\n'
          'Proxy-Connection: keep-alive\r\n'
          'Accept: */*\r\n\r\n',
        ),
      );
      await _settle();

      final request = await firstChunk.future.timeout(
        const Duration(seconds: 5),
      );
      expect(request, startsWith('GET /a/b?c=d HTTP/1.1\r\n'));
      expect(request, contains('Host: example.com'));
      expect(request, contains('Accept: */*'));
      expect(
        request.toLowerCase(),
        isNot(contains('proxy-connection')),
        reason: '代理专用的跳接头不该被转发给上游',
      );
      // 没有 CONNECT 就不该有 200 那一行 —— 响应由上游给。
      expect(request, isNot(contains('Connection Established')));

      await client.close();
      await proxy.close();
      await upstream.close();
      unawaited(received.close());
    });

    test('上游拨不通时回 502，而不是 500', () async {
      final proxy = ShuHttpProxy(
        dialer: (host, port) async => throw const SocketException('refused'),
      );
      final port = await proxy.start();

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = _Reader(client);
      client.add(utf8.encode('CONNECT example.com:443 HTTP/1.1\r\n\r\n'));
      await _settle();

      expect(reader.toString(), startsWith('HTTP/1.1 502 Bad Gateway'));

      await client.close();
      await proxy.close();
    });

    test('不是代理请求时回 400', () async {
      final proxy = ShuHttpProxy(
        dialer: (host, port) async => throw StateError('不该被调用'),
      );
      final port = await proxy.start();

      final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final reader = _Reader(client);
      client.add(utf8.encode('GARBAGE\r\n\r\n'));
      await _settle();

      expect(reader.toString(), startsWith('HTTP/1.1 400 Bad Request'));

      await client.close();
      await proxy.close();
    });

    test('首选端口被占用时退到系统分配的端口', () async {
      final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final upstream = await _startEcho(StreamController<List<int>>());
      final proxy = ShuHttpProxy(
        dialer: _dialerTo(upstream),
        port: blocker.port,
      );

      final port = await proxy.start();
      expect(port, isNot(blocker.port));
      expect(port, greaterThan(0));

      await proxy.close();
      await blocker.close();
      await upstream.close();
    });

    test('取消令牌会拆掉监听', () async {
      final upstream = await _startEcho(StreamController<List<int>>());
      final token = SangforCancellationToken();
      final proxy = ShuHttpProxy(
        dialer: _dialerTo(upstream),
        cancellationToken: token,
      );
      final port = await proxy.start();

      token.cancel('test');
      await _settle();

      // 端口不该再有人听：新连接会被拒绝。
      await expectLater(
        Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<SocketException>()),
      );

      await proxy.close();
      await upstream.close();
    });
  });
}
