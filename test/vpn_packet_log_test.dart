// VPN 数据面逐包日志的离线单测。
//
// 这一层全部是纯逻辑：喂进去的是自己拼的 IPv4 包，出来的是 `ShuLog` 里
// 的记录。不需要隧道、不需要设备、不需要 Android —— 而它要回答的问题
// （「这个包为什么没出去」）恰恰只在真机上才难查，所以放在这里先把判定
// 与四个等级的粒度钉死。
//
// `ShuLog` 是**进程级单例**，每条用例开头都要复位，否则上一条的阈值与
// 记录会漏进来，失败看起来像「等级过滤坏了」。

import 'dart:typed_data';

import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/vpn_packet_log.dart';
import 'package:shuvpn/core/logging/shu_log.dart';

void main() {
  setUp(() {
    ShuLog.instance.clear();
    ShuLog.instance.configure(enabled: true, level: ShuLogLevel.debug);
  });

  tearDown(() {
    ShuLog.instance.clear();
    ShuLog.instance.configure(enabled: false, level: ShuLogLevel.info);
  });

  group('结论判定', () {
    test('命中资源的 TCP 走 L3：一上来就是 match', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      final routed = await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );

      expect(routed, isTrue);
      expect(observer.unroutablePackets, 0);
      expect(observer.failedPackets, 0);
      expect(observer.flowsSeen, 1);
      final line = _lines().first;
      expect(line.level, ShuLogLevel.info);
      expect(line.message, contains('192.168.5.2:51234 --> 10.1.2.3:443'));
      expect(line.message, contains('match 10.1.0.0/16/tcp app=af gid=10'));
      expect(line.message, contains('via tunnel'));
    });

    test('TCP 命中资源但网关没开 enableTcpPrefL3 —— 单独说出来', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: false)],
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => false,
      );

      final warn = _lines().first;
      expect(warn.level, ShuLogLevel.warn);
      // 这一句是整条链路上最值钱的诊断：现象和「没权限」一样，原因不同。
      expect(warn.message, contains('enableTcpPrefL3'));
      expect(warn.message, contains('本机代理'));
      // 算进丢弃计数 —— 它确实会被隧道丢掉。
      expect(observer.unroutablePackets, 1);
    });

    test('目的地址压根不在资源表里', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '8.8.8.8', destinationPort: 443),
        () async => false,
      );

      final warn = _lines().first;
      expect(warn.level, ShuLogLevel.warn);
      expect(warn.message, contains('no match'));
      expect(observer.unroutablePackets, 1);
    });

    test('UDP 不受 L3 开关影响，但受端口区间约束', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[
          _udpRoute(host: '10.1.0.0/16', portMin: 53, portMax: 53),
        ],
      );

      await observer.observeEgress(
        _udp(destination: '10.1.2.3', destinationPort: 53),
        () async => true,
      );
      await observer.observeEgress(
        _udp(destination: '10.1.2.3', destinationPort: 5353),
        () async => false,
      );

      expect(observer.flowsSeen, 2);
      expect(observer.unroutablePackets, 1);
      final announced = _lines()
          .where((record) => record.level != ShuLogLevel.debug)
          .map((record) => record.message)
          .toList();
      expect(announced[0], contains('10.1.2.3:53'));
      expect(announced[1], contains('no match'));
      // 端口区间是 `matchL3Route` 的一条门，日志里必须能看出来。
      expect(announced[1], contains('10.1.2.3:5353'));
    });

    test('区间写法（a~b）按 SDK 的语义匹配', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.2.1~10.1.2.9', l3: true)],
      );
      expect(
        await observer.observeEgress(
          _tcp(destination: '10.1.2.5', destinationPort: 80),
          () async => true,
        ),
        isTrue,
      );
      expect(observer.unroutablePackets, 0);
    });
  });

  group('四个等级各自的粒度', () {
    test('INFO 档：同一条流只报一次「建立」', () async {
      ShuLog.instance.configure(level: ShuLogLevel.info);
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      for (var index = 0; index < 5; index++) {
        await observer.observeEgress(
          _tcp(destination: '10.1.2.3', destinationPort: 443),
          () async => true,
        );
      }

      expect(observer.egressPackets, 5);
      expect(_lines(), hasLength(1));
    });

    test('DEBUG 档：逐个包一行，带上序号、字节数与结果', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );
      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443, flags: _tcpAck),
        () async => true,
      );

      final lines = _lines();
      expect(lines, hasLength(3)); // 1 条建立 + 2 条明细
      expect(lines[1].level, ShuLogLevel.debug);
      expect(
        lines[1].message,
        '[TCP] 192.168.5.2:51234 --> 10.1.2.3:443 up#1 SYN 40 B forwarded',
      );
      expect(lines[2].message, contains('up#2 ACK 40 B'));
    });

    test('WARN 档：看不到逐包明细，但看得到被丢的流', () async {
      ShuLog.instance.configure(level: ShuLogLevel.warn);
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '8.8.8.8', destinationPort: 443),
        () async => false,
      );

      final lines = _lines();
      expect(lines, hasLength(1));
      expect(lines.single.message, isNot(contains('B [')));
    });

    test('ERROR 档：连「建立」都不记，只剩发不出去的包', () async {
      ShuLog.instance.configure(level: ShuLogLevel.error);
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );
      expect(_lines(), isEmpty);

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => throw StateError('boom'),
      );
      expect(_lines().single.level, ShuLogLevel.error);
    });

    test('关掉开关时一封都不记，但计数照旧', () async {
      ShuLog.instance.configure(enabled: false);
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );
      expect(_lines(), isEmpty);
      expect(observer.egressPackets, 1);
    });
  });

  group('结果', () {
    test('sendPacket 抛异常：记 ERROR 且不向外抛', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      final routed = await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => throw StateError('socket closed'),
      );

      expect(routed, isFalse);
      expect(observer.failedPackets, 1);
      final error = _lines().last;
      expect(error.level, ShuLogLevel.error);
      expect(error.message, contains('10.1.2.3:443'));
    });

    test('命中资源却返回 false：这是「隧道已关闭」的信号', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => false,
      );

      expect(observer.failedPackets, 1);
      expect(_lines().last.message, contains('send failed'));
    });

    test('资源表外的包被丢不算「失败」—— 那是判定出来的结果', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '8.8.8.8', destinationPort: 443),
        () async => false,
      );

      expect(observer.failedPackets, 0);
      expect(observer.unroutablePackets, 1);
    });
  });

  group('流的归属与收尾', () {
    test('下行包靠规范化五元组算回同一条流', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );
      final echo = _tcp(
        source: '10.1.2.3',
        sourcePort: 443,
        destination: '192.168.5.2',
        destinationPort: 51234,
        flags: _tcpAck,
        payload: 1000,
      );
      expect(identical(observer.observeIngress(echo), echo), isTrue);

      // 一条流，而不是两条。
      expect(observer.flowCount, 1);
      expect(observer.egressPackets, 1);
      expect(observer.ingressPackets, 1);
      final ingress = _lines().last;
      expect(ingress.message, contains('down#1 ACK 1040 B'));
      expect(ingress.message, contains('10.1.2.3:443 --> 192.168.5.2:51234'));
      expect(ingress.message, contains('forwarded'));
    });

    test('FIN 收尾：报一行这条流的上下行合计', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );
      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443, flags: _tcpFin),
        () async => true,
      );

      final closing = _lines().last;
      expect(closing.level, ShuLogLevel.info);
      expect(closing.message, contains('closed'));
      expect(closing.message, contains('up 2 pkt 80 B'));
      expect(closing.message, contains('down 0 pkt 0 B'));
    });

    test('流表到顶后按最久没用过的淘汰', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      for (var index = 0; index < ShuPacketObserver.maxFlows + 10; index++) {
        await observer.observeEgress(
          _tcp(
            destination: '10.1.2.3',
            destinationPort: 443,
            sourcePort: 1024 + index,
          ),
          () async => true,
        );
      }

      expect(observer.flowsSeen, ShuPacketObserver.maxFlows + 10);
      expect(observer.flowCount, ShuPacketObserver.maxFlows);
    });
  });

  group('畸形包', () {
    test('IPv6 单独成一档，不归进「无法解析」', () async {
      // 这一档是「VPN 开着但一个包都不进 TUN」的现场证据：包本身是好的，
      // 只是没人答应处理它。归进「无法解析」会让人去查包是不是坏了。
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      final v6 = Uint8List(76)..[0] = 0x60;
      await observer.observeEgress(v6, () async => false);

      expect(observer.ipv6Packets, 1);
      expect(observer.malformedPackets, 0);
      expect(observer.egressPackets, 1);
      expect(observer.flowsSeen, 0);
      final warn = _lines().single;
      expect(warn.level, ShuLogLevel.warn);
      expect(warn.message, contains('76 B'));
      expect(warn.message, contains('ipv6'));
    });

    test('截断的 IPv4 头被判成畸形，且不打印字节转储', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      // IHL 声明 60 字节，实际只有 20 —— `buildPacketMeta` 在这里会抛
      // `RangeError`，必须先被自己挡住。
      final truncated = Uint8List(20)..[0] = 0x4f;
      await observer.observeEgress(truncated, () async => false);

      expect(observer.malformedPackets, 1);
      expect(observer.ipv6Packets, 0);
      expect(observer.flowsSeen, 0);
      final warn = _lines().single;
      expect(warn.level, ShuLogLevel.warn);
      expect(warn.message, contains('20 B'));
      expect(warn.message, contains('malformed'));
      // 不打字节：畸形包已经没有任何结构可言，十六进制转储只会把缓冲区的
      // 容量按几十倍的比例换成噪音。
      expect(warn.message, isNot(contains('4f 00')));
    });

    test('下行畸形包原样还回去，不会把流打断', () {
      final observer = ShuPacketObserver(routes: const <ATrustRoute>[]);
      final garbage = Uint8List.fromList(<int>[0x60, 1, 2, 3]);

      expect(identical(observer.observeIngress(garbage), garbage), isTrue);
      expect(observer.malformedPackets, 0); // 下行不重复报
      expect(observer.ingressPackets, 1);
      expect(_lines(), isEmpty);
    });
  });

  group('DEBUG 档的每秒预算', () {
    test('超出预算只计数，跨秒时补一行汇总', () async {
      var now = DateTime(2026, 9, 29, 12);
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
        clock: () => now,
      );

      final extra = 50;
      final total = ShuPacketObserver.debugBudgetPerSecond + extra;
      for (var index = 0; index < total; index++) {
        await observer.observeEgress(
          _tcp(destination: '10.1.2.3', destinationPort: 443),
          () async => true,
        );
      }

      // 1 条建立 + 一整份预算的明细，多出来的只计数。
      expect(_lines(), hasLength(1 + ShuPacketObserver.debugBudgetPerSecond));
      expect(observer.egressPackets, total);

      // 下一秒：先补汇总，再记这个包自己。
      now = now.add(const Duration(seconds: 1));
      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );

      final tail = _lines().sublist(_lines().length - 2);
      expect(tail.first.message, contains('上一秒另有 $extra 个包未逐条记录'));
      expect(tail.last.message, contains('up#${total + 1}'));
    });

    test('没超预算时不出现任何「省略」字样', () async {
      var now = DateTime(2026, 9, 29, 12);
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
        clock: () => now,
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );
      now = now.add(const Duration(seconds: 1));
      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );

      for (final record in _lines()) {
        expect(record.message, isNot(contains('未逐条记录')));
      }
    });
  });

  group('会话小结', () {
    test('finish 把上下行、丢弃、失败一次说清', () async {
      final observer = ShuPacketObserver(
        routes: <ATrustRoute>[_tcpRoute(host: '10.1.0.0/16', l3: true)],
      );

      await observer.observeEgress(
        _tcp(destination: '10.1.2.3', destinationPort: 443),
        () async => true,
      );
      await observer.observeEgress(
        _tcp(destination: '8.8.8.8', destinationPort: 443),
        () async => false,
      );
      observer.observeIngress(
        _tcp(
          source: '10.1.2.3',
          sourcePort: 443,
          destination: '192.168.5.2',
          destinationPort: 51234,
          flags: _tcpAck,
        ),
      );

      observer.finish();

      final summary = _lines().last;
      expect(summary.message, contains('summary'));
      expect(summary.message, contains('up 2 pkt'));
      expect(summary.message, contains('down 1 pkt'));
      expect(summary.message, contains('2 条流'));
      expect(summary.message, contains('no match 1'));
    });

    test('一个包都没有时不写小结', () {
      ShuPacketObserver(routes: const <ATrustRoute>[]).finish();
      expect(_lines(), isEmpty);
    });

    test('小结会带上 IPv6 的计数（它非零就是 bug）', () async {
      final observer = ShuPacketObserver(routes: const <ATrustRoute>[]);
      await observer.observeEgress(
        Uint8List(48)..[0] = 0x60,
        () async => false,
      );
      observer.finish();

      expect(_lines().last.message, contains('ipv6 1'));
    });
  });

  group('formatRate', () {
    test('速率与累计量共用同一套量纲，只是带上 /s', () {
      expect(formatRate(0), '0 B/s');
      expect(formatRate(-1), '0 B/s');
      expect(formatRate(double.nan), '0 B/s');
      expect(formatRate(812), '812 B/s');
      expect(formatRate(2048), '2.0 KB/s');
      expect(formatRate(3 * 1024 * 1024), '3.0 MB/s');
    });

    test('四舍五入到整字节，不出现 0.4 B/s 这种数', () {
      expect(formatRate(0.4), '0 B/s');
      expect(formatRate(0.6), '1 B/s');
    });
  });

  group('formatDuration', () {
    test('毫秒 / 秒 / 分三档', () {
      expect(formatDuration(const Duration(milliseconds: 0)), '0ms');
      expect(formatDuration(const Duration(milliseconds: 820)), '820ms');
      expect(formatDuration(const Duration(milliseconds: 3120)), '3.1s');
      expect(formatDuration(const Duration(seconds: 72)), '1m12s');
    });
  });

  group('formatByteCount', () {
    test('按 1024 进制换档，且和系统流量统计能对上', () {
      expect(formatByteCount(0), '0 B');
      expect(formatByteCount(812), '812 B');
      expect(formatByteCount(1024), '1.0 KB');
      expect(formatByteCount(20 * 1024), '20 KB');
      expect(formatByteCount(1024 * 1024), '1.0 MB');
      expect(formatByteCount(30 * 1024 * 1024), '30 MB');
      expect(formatByteCount(2 * 1024 * 1024 * 1024), '2.0 GB');
    });
  });
}

// ------------------------------------------------------------- 断言辅助

/// 缓冲区里现在的记录。
List<ShuLogRecord> _lines() => ShuLog.instance.records;

// ------------------------------------------------------------- 造包工具

const int _tcpSyn = 0x02;
const int _tcpFin = 0x01;
const int _tcpAck = 0x10;

ATrustRoute _tcpRoute({required String host, required bool l3}) => ATrustRoute(
  host: host,
  protocol: 'tcp',
  portMin: 0,
  portMax: 65535,
  appId: 'af',
  nodeGroupId: '10',
  addrPretend: false,
  enableTcpPrefL3: l3,
);

ATrustRoute _udpRoute({
  required String host,
  required int portMin,
  required int portMax,
}) => ATrustRoute(
  host: host,
  protocol: 'udp',
  portMin: portMin,
  portMax: portMax,
  appId: 'af',
  nodeGroupId: '10',
  addrPretend: false,
);

/// 一个 IPv4 + TCP 包。默认就是「手机连 10.1.2.3:443 的 SYN」。
Uint8List _tcp({
  String source = '192.168.5.2',
  int sourcePort = 51234,
  required String destination,
  required int destinationPort,
  int flags = _tcpSyn,
  int payload = 0,
}) => _packet(
  source: source,
  sourcePort: sourcePort,
  destination: destination,
  destinationPort: destinationPort,
  protocol: 6,
  headerTail: flags,
  payload: payload,
);

Uint8List _udp({
  String source = '192.168.5.2',
  int sourcePort = 51234,
  required String destination,
  required int destinationPort,
  int payload = 0,
}) => _packet(
  source: source,
  sourcePort: sourcePort,
  destination: destination,
  destinationPort: destinationPort,
  protocol: 17,
  // UDP 头是 8 字节，没有标志位。
  headerTail: null,
  payload: payload,
  transportHeaderLength: 8,
  flagOffset: null,
);

/// 拼一个 IPv4 包：20 字节 IP 头 + 传输层头 + 载荷。
Uint8List _packet({
  required String source,
  required int sourcePort,
  required String destination,
  required int destinationPort,
  required int protocol,
  required int? headerTail,
  required int payload,
  int transportHeaderLength = 20,
  int? flagOffset = 13,
}) {
  final total = 20 + transportHeaderLength + payload;
  final bytes = Uint8List(total);
  final view = ByteData.sublistView(bytes);

  bytes[0] = 0x45; // IPv4，IHL = 5
  view.setUint16(2, total);
  bytes[8] = 64; // TTL
  bytes[9] = protocol;
  _writeAddress(bytes, 12, source);
  _writeAddress(bytes, 16, destination);

  final transport = 20;
  view.setUint16(transport, sourcePort);
  view.setUint16(transport + 2, destinationPort);
  if (flagOffset != null) {
    // 只有 TCP 头有「数据偏移」与标志位；UDP 头就 8 字节，写过去会越界。
    bytes[transport + 12] = (transportHeaderLength ~/ 4) << 4;
    if (headerTail != null) bytes[transport + flagOffset] = headerTail;
  }
  return bytes;
}

void _writeAddress(Uint8List target, int offset, String address) {
  final parts = address.split('.');
  for (var index = 0; index < 4; index++) {
    target[offset + index] = int.parse(parts[index]);
  }
}
