// L3 通道的帧切分单测。
//
// 这一段被一次错位咬过，而且咬得很隐蔽：握手之后还跟着 **4 字节 VIP 头 +
// 6/18/22 字节 VIP 数据**，漏掉它不会报「少解析一点」，而是从握手结束起
// **整条通道全部错位** —— `05 00 00 01` 被当成 `command = 0x0` 的一帧吃掉
// 五个字节，于是下一个「首字节」落在 VIP 地址的第二个字节上。
//
// 真机上的读数就是 62 条通道全部报 `稳态帧首字节 0x5f`：VIP 是 `10.95.x.x`，
// 第二个字节正好是 95。所以下面第二条断言的那个 VIP 要一直是 `10.95.178.77`。
//
// 全部是纯函数，不需要真机也不需要网络。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/atrust_l3_framing.dart';

List<int> _be16(int value) => <int>[(value >> 8) & 0xff, value & 0xff];

/// 握手响应：`05 D0 53 <状态> <长度:2> <JSON> <VIP 头:4> <VIP 数据>`。
List<int> _handshake({
  String json =
      '{"code":0,"message":"success","data":{"deviceId":"31e7-008f"}}',
  int status = 0,
  int addressType = 1,
  List<int> vip = const <int>[10, 95, 178, 77, 0, 0],
}) {
  final payload = utf8.encode(json);
  return <int>[
    0x05,
    0xd0,
    0x53,
    status,
    ..._be16(payload.length),
    ...payload,
    0x05,
    0x00,
    0x00,
    addressType,
    ...vip,
  ];
}

/// 稳态帧：`05 <命令> [状态] <长度:2> <负载>`。
List<int> _frame(int command, String json, {int? status}) {
  final payload = utf8.encode(json);
  return <int>[0x05, command, ?status, ..._be16(payload.length), ...payload];
}

const _authOk = '{"code":0,"message":"success","data":{"conntrackHash":8123}}';
const _authDenied = '{"code":10000004,"message":"permission denied","data":{}}';

/// 把一段字节按 [size] 切片喂进去，收集全部通知。
List<ShuL3Notice> _feed(ShuL3Framer framer, List<int> bytes, {int? size}) {
  if (size == null) return framer.add(bytes);
  final notices = <ShuL3Notice>[];
  var index = 0;
  while (index < bytes.length) {
    final end = index + size < bytes.length ? index + size : bytes.length;
    notices.addAll(framer.add(bytes.sublist(index, end)));
    index = end;
  }
  return notices;
}

void main() {
  group('ShuL3Framer 握手', () {
    test('整段吃掉，虚拟地址解出来', () {
      final framer = ShuL3Framer();
      final notices = _feed(framer, _handshake());

      expect(notices, hasLength(1));
      expect(notices.single.kind, ShuL3NoticeKind.handshakeAccepted);
      expect(notices.single.deviceId, '31e7-008f');
      expect(notices.single.virtualAddresses, <String>['10.95.178.77']);
      expect(framer.handshakeDone, isTrue);
      expect(framer.stopped, isFalse);
      // 6 字节帧头 + JSON + 4 字节 VIP 头 + 6 字节 VIP 数据。
      expect(
        framer.handshakeBytes,
        6 +
            '{"code":0,"message":"success","data":{"deviceId":"31e7-008f"}}'
                .length +
            10,
      );
    });

    test('逐字节喂进来，结论与一次喂完全一样', () {
      final all = _handshake();
      expect(
        _feed(
          ShuL3Framer(),
          all,
          size: 1,
        ).map((notice) => notice.kind).toList(),
        <ShuL3NoticeKind>[ShuL3NoticeKind.handshakeAccepted],
      );
    });

    test('认证长度为零不算失败', () {
      final notices = _feed(ShuL3Framer(), _handshake(json: ''));

      expect(notices.single.kind, ShuL3NoticeKind.handshakeAccepted);
      expect(notices.single.deviceId, isNull);
    });

    test('状态非零判为被拒，并且不再往后解', () {
      final framer = ShuL3Framer();
      final notices = _feed(framer, _handshake(status: 0x1f));

      expect(notices.single.kind, ShuL3NoticeKind.handshakeRejected);
      expect(notices.single.status, 0x1f);
      expect(framer.stopped, isTrue);
      expect(framer.handshakeDone, isFalse);
    });

    test('认证 code 非零判为被拒，带上服务端的原话', () {
      final framer = ShuL3Framer();
      final notices = _feed(
        framer,
        _handshake(
          json: '{"code":10000004,"message":"device not allowed","data":{}}',
        ),
      );

      expect(notices.single.kind, ShuL3NoticeKind.handshakeRejected);
      expect(notices.single.code, 10000004);
      expect(notices.single.message, 'device not allowed');
      // 被拒的那一条仍然解出了 VIP，因为它排在认证负载之后。
      expect(notices.single.virtualAddresses, <String>['10.95.178.77']);
      expect(framer.stopped, isTrue);
    });

    test('VIP 类型 4 解出 IPv6', () {
      final notices = _feed(
        ShuL3Framer(),
        _handshake(
          addressType: 4,
          // 18 字节：前 16 个是地址，后面两个是留白。
          vip: <int>[
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, //
            0, 0, 0, 0, 0, 0, 0, 1,
            0, 0,
          ],
        ),
      );

      expect(notices.single.virtualAddresses, <String>['2001:db8:0:0:0:0:0:1']);
    });

    test('VIP 类型 5 解出 IPv4 与 IPv6 两个', () {
      final notices = _feed(
        ShuL3Framer(),
        _handshake(
          addressType: 5,
          vip: <int>[
            10, 95, 178, 77, //
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            0, 0,
          ],
        ),
      );

      expect(notices.single.virtualAddresses, <String>[
        '10.95.178.77',
        '2001:db8:0:0:0:0:0:1',
      ]);
    });

    test('VIP 地址类型不认识时判失败，并点出那个类型', () {
      final notices = _feed(ShuL3Framer(), _handshake(addressType: 9));

      expect(notices.single.kind, ShuL3NoticeKind.unparsable);
      expect(notices.single.reason, contains('地址类型 9'));
    });
  });

  group('ShuL3Framer 稳态帧', () {
    test('回归：漏掉 VIP 块的那个错位不再发生', () {
      // 旧解析器吃掉 6 + 认证长度就收工，于是 `05 00 00 01` 被当成
      // `command = 0x0` 的一帧吃掉，紧接着报 `稳态帧首字节 0x5f`
      // —— 0x5f 是 `10.95.178.77` 的第二个字节。这条断言盯的就是那件事。
      final framer = ShuL3Framer();
      final notices = _feed(framer, <int>[
        ..._handshake(),
        ..._frame(0x93, _authOk, status: 0),
      ]);

      expect(notices.map((notice) => notice.kind).toList(), <ShuL3NoticeKind>[
        ShuL3NoticeKind.handshakeAccepted,
        ShuL3NoticeKind.flowAuthAccepted,
      ]);
      expect(framer.stopped, isFalse);
      expect(
        notices.where((notice) => notice.reason != null),
        isEmpty,
        reason: 'VIP 块是握手的一部分，不该被当成一帧',
      );
    });

    test('流认证被拒时带上状态、code 与服务端的原话', () {
      final notices = _feed(ShuL3Framer(), <int>[
        ..._handshake(),
        ..._frame(0x93, _authDenied, status: 0x95),
      ]);

      final denial = notices.last;
      expect(denial.kind, ShuL3NoticeKind.flowAuthRejected);
      expect(denial.status, 0x95);
      expect(denial.code, 10000004);
      expect(denial.message, 'permission denied');
    });

    test('重试状态原样带出来，判定留给调用方', () {
      // 0x84 与 0x85..0x87 在 SDK 里是「重试」而不是终局；解析器只负责
      // 把状态如实交出去，怎么措辞是日志那一层的事。
      for (final status in <int>[0x84, 0x85, 0x87]) {
        final notices = _feed(ShuL3Framer(), <int>[
          ..._handshake(),
          ..._frame(0x93, _authDenied, status: status),
        ]);
        expect(notices.last.kind, ShuL3NoticeKind.flowAuthRejected);
        expect(notices.last.status, status);
      }
    });

    test('数据帧与心跳只计数，不返回通知', () {
      final framer = ShuL3Framer();
      final notices = _feed(framer, <int>[
        ..._handshake(),
        ..._frame(0x94, 'something the server pushed'),
        ..._frame(0x95, ''),
        ..._frame(0x94, 'more'),
      ]);

      expect(notices, hasLength(1));
      expect(framer.dataFrames, 2);
      expect(framer.heartbeats, 1);
    });

    test('未知命令立刻判失败，并点出是哪一个', () {
      // 这一条是防下一次错位的闸门：宽松地「跳过看不懂的」正是上次那个
      // bug 的成因 —— `0x0` 不在 SDK 认得的七个命令里，早说一句就够。
      final framer = ShuL3Framer();
      final notices = _feed(framer, <int>[
        ..._handshake(),
        0x05,
        0x00,
        0x00,
        0x01,
      ]);

      expect(notices.last.kind, ShuL3NoticeKind.unparsable);
      expect(notices.last.reason, contains('命令 0x0'));
      expect(framer.stopped, isTrue);
    });

    test('帧跨切片边界时按片喂也对', () {
      final bytes = <int>[
        ..._handshake(),
        ..._frame(0x94, 'pushed payload'),
        ..._frame(0x93, _authOk, status: 0),
        ..._frame(0x93, _authDenied, status: 0x84),
      ];

      for (final size in <int>[1, 3, 7, 64]) {
        final framer = ShuL3Framer();
        final notices = _feed(framer, bytes, size: size);
        expect(notices.map((notice) => notice.kind).toList(), <ShuL3NoticeKind>[
          ShuL3NoticeKind.handshakeAccepted,
          ShuL3NoticeKind.flowAuthAccepted,
          ShuL3NoticeKind.flowAuthRejected,
        ], reason: '切片大小 $size');
        expect(framer.dataFrames, 1, reason: '切片大小 $size');
      }
    });

    test('二次 VIP 下发解出地址', () {
      final notices = _feed(ShuL3Framer(), <int>[
        ..._handshake(),
        ..._frame(
          0x96,
          '{"code":0,"data":{"vip":"10.95.178.78","vip6":"2001:db8::1"}}',
          status: 0,
        ),
      ]);

      expect(notices.last.kind, ShuL3NoticeKind.secondVip);
      expect(notices.last.virtualAddresses, <String>[
        '10.95.178.78',
        '2001:db8::1',
      ]);
    });
  });

  group('ShuL3Framer 缓冲', () {
    test('超过上限时停止观察，并把上限写进原因', () {
      final framer = ShuL3Framer(bufferLimit: 8);
      final notice = _feed(framer, List<int>.filled(9, 0x05)).single;

      expect(notice.kind, ShuL3NoticeKind.unparsable);
      expect(notice.reason, contains('8 B'));
      expect(framer.stopped, isTrue);
    });

    test('停止之后一个字节也不再解', () {
      final framer = ShuL3Framer();
      _feed(framer, <int>[..._handshake(), 0x05, 0x00, 0x00, 0x01]);
      expect(framer.stopped, isTrue);

      expect(_feed(framer, _frame(0x93, _authOk, status: 0)), isEmpty);
    });
  });
}
