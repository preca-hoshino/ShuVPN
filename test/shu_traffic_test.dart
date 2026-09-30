// 代理这一侧的流量账与逐连接日志。
//
// 这一层是连接页那行实时读数的唯一来源（TUN 那一侧的账在 `ShuPacketObserver`
// 上），而它算错的两个方向都不会有人当场发现：少算会让速率看起来偏低，
// 多算会让「这一条连接用了多少」重复报给每一条连接。所以字节数要钉死。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/shu_traffic.dart';
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

  group('ShuTrafficMeter', () {
    test('上行与下行分开累加，且按连接各记一份', () async {
      final meter = ShuTrafficMeter();
      final inner = _FakeStream();
      final stream = meter.wrap(
        inner,
        target: '1.2.3.4:443',
        routeLabel: '128.0.0.0/1/tcp:443',
      );

      await stream.send(Uint8List(100));
      await stream.send(Uint8List(28));
      await _feed(stream, inner, Uint8List(2048));

      expect(meter.upBytes, 128);
      expect(meter.downBytes, 2048);
      expect(meter.connectionsOpened, 0, reason: '建连计数由调用方加，wrap 不加');
    });

    test('多条连接的下行字节不会互相串', () async {
      final meter = ShuTrafficMeter();
      final firstInner = _FakeStream();
      final secondInner = _FakeStream();
      final first = meter.wrap(
        firstInner,
        target: '1.2.3.4:443',
        routeLabel: 'r',
      );
      final second = meter.wrap(
        secondInner,
        target: '5.6.7.8:443',
        routeLabel: 'r',
      );

      await _feed(first, firstInner, Uint8List(1000));
      await _feed(second, secondInner, Uint8List(24));

      expect(meter.downBytes, 1024);
    });

    test('收尾那一行给的是**这一条**的量，不是全局累计', () async {
      final meter = ShuTrafficMeter();
      final firstInner = _FakeStream();
      final first = meter.wrap(
        firstInner,
        target: '1.2.3.4:443',
        routeLabel: '128.0.0.0/1/tcp:443',
      );
      await _feed(first, firstInner, Uint8List(4096));
      await first.close();

      // 第二条只收 8 字节；如果收尾行拿了 meter 上的全局值，它会报 4.1 KB。
      final secondInner = _FakeStream();
      final second = meter.wrap(
        secondInner,
        target: '5.6.7.8:443',
        routeLabel: 'r',
      );
      await _feed(second, secondInner, Uint8List(8));
      await second.close();

      final lines = ShuLog.instance.records
          .where((record) => record.message.contains('closed'))
          .map((record) => record.message)
          .toList();
      expect(lines, hasLength(2));
      expect(lines[0], contains('down 1 pkt 4.0 KB'));
      expect(lines[1], contains('down 1 pkt 8 B'));
    });

    test('同一条连接只写一次收尾行', () async {
      final meter = ShuTrafficMeter();
      final stream = meter.wrap(
        _FakeStream(),
        target: '1.2.3.4:443',
        routeLabel: 'r',
      );
      await stream.close();
      await stream.close();

      expect(
        ShuLog.instance.records.where((r) => r.message.contains('closed')),
        hasLength(1),
      );
    });

    test('建连耗时走滑动平均，不是最后一次', () {
      final meter = ShuTrafficMeter();
      expect(meter.latencyMs, isNull);

      meter.sampleLatency(const Duration(milliseconds: 100));
      expect(meter.latencyMs, 100);

      // 一次难看的样本不该把整格数字拉走。
      meter.sampleLatency(const Duration(milliseconds: 3000));
      expect(meter.latencyMs, closeTo(970, 0.5));
    });
  });
}

/// 把一块数据喂进流的 `incoming`。
///
/// 必须 `await` 到监听真的收到 —— 订阅是异步建立的，发完就走会读到 0。
/// [_FakeStream.controller] 是**单订阅**的，而 [ShuTrafficMeter.wrap] 会在
/// 第一次取 `incoming` 时把它包一层；这里必须拿外层流去听，否则包的那层
/// 计数不会跑。
Future<void> _feed(
  SangforTcpStream stream,
  _FakeStream inner,
  Uint8List chunk,
) async {
  final received = Completer<void>();
  final subscription = stream.incoming.listen((_) {
    if (!received.isCompleted) received.complete();
  });
  inner.controller.add(chunk);
  await received.future;
  await subscription.cancel();
}

/// 最小可用的假流：只实现计数要用到的那几项。
class _FakeStream implements SangforTcpStream {
  final StreamController<Uint8List> controller =
      StreamController<Uint8List>.broadcast();

  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => controller.stream;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> closeWrite() async {}

  @override
  Future<void> close() async {
    _closed = true;
    if (!controller.isClosed) await controller.close();
  }
}
