// 日志设施的离线单测。
//
// 这个单例是**进程级**的，所以每条用例开头都要复位 —— 否则前一条用例
// 留下的开关与记录会漏进下一条，而那种失败看起来像是「等级过滤坏了」。

import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/logging/shu_log.dart';

void main() {
  setUp(() {
    // 出厂态：关着、没有记录。各用例自己按需打开。
    ShuLog.instance.clear();
    ShuLog.instance.configure(enabled: false, level: ShuLogLevel.info);
  });

  group('ShuLogLevel', () {
    test('声明顺序就是严重度', () {
      expect(ShuLogLevel.error.index, lessThan(ShuLogLevel.warn.index));
      expect(ShuLogLevel.warn.index, lessThan(ShuLogLevel.info.index));
      expect(ShuLogLevel.info.index, lessThan(ShuLogLevel.debug.index));
    });

    test('标签就是屏幕上和磁盘上用的大写名', () {
      expect(ShuLogLevel.values.map((level) => level.label), <String>[
        'ERROR',
        'WARN',
        'INFO',
        'DEBUG',
      ]);
    });

    test('fromName 同时认标签与枚举名', () {
      expect(ShuLogLevel.fromName('WARN'), ShuLogLevel.warn);
      expect(ShuLogLevel.fromName('warn'), ShuLogLevel.warn);
      expect(ShuLogLevel.fromName('DEBUG'), ShuLogLevel.debug);
    });

    test('认不出时退回 INFO，而不是「全部记录」', () {
      // 退回 debug 会让一个拼错的设置突然把缓冲区塞满；退回 error 又会
      // 让用户以为日志坏了。中间那一档是唯一安全的默认。
      expect(ShuLogLevel.fromName(null), ShuLogLevel.info);
      expect(ShuLogLevel.fromName('verbose'), ShuLogLevel.info);
      expect(ShuLogLevel.fromName(''), ShuLogLevel.info);
    });
  });

  group('ShuLog', () {
    test('关掉时一条都不记', () {
      ShuLog.instance.configure(enabled: false, level: ShuLogLevel.debug);
      ShuLog.i('conn', '不该出现');
      expect(ShuLog.instance.isEmpty, isTrue);
    });

    test('低于阈值的记录在写入时就被丢掉', () {
      ShuLog.instance.configure(enabled: true, level: ShuLogLevel.info);
      ShuLog.d('conn', '细节');
      ShuLog.i('conn', '流程');
      ShuLog.w('conn', '警告');
      ShuLog.e('conn', '错误');

      expect(
        ShuLog.instance.records.map((record) => record.level),
        <ShuLogLevel>[ShuLogLevel.info, ShuLogLevel.warn, ShuLogLevel.error],
      );
    });

    test('把阈值调低不会回填历史 —— 过滤发生在写入时', () {
      ShuLog.instance.configure(enabled: true, level: ShuLogLevel.error);
      ShuLog.d('conn', '被丢掉的细节');
      ShuLog.instance.configure(level: ShuLogLevel.debug);
      expect(ShuLog.instance.isEmpty, isTrue);
    });

    test('关掉开关不清空已有记录', () {
      ShuLog.instance.configure(enabled: true, level: ShuLogLevel.info);
      ShuLog.i('conn', '先记一条');
      ShuLog.instance.configure(enabled: false);
      expect(ShuLog.instance.length, 1);
    });

    test('缓冲区只留最近 maxRecords 条', () {
      ShuLog.instance.configure(enabled: true, level: ShuLogLevel.info);
      for (var index = 0; index < ShuLog.maxRecords + 25; index++) {
        ShuLog.i('conn', '第 $index 条');
      }
      expect(ShuLog.instance.length, ShuLog.maxRecords);
      // 最旧的被挤掉，最新的还在。
      expect(ShuLog.instance.records.first.message, '第 25 条');
      expect(
        ShuLog.instance.records.last.message,
        '第 ${ShuLog.maxRecords + 24} 条',
      );
    });

    test('clear 清空并且可重复调用', () {
      ShuLog.instance.configure(enabled: true, level: ShuLogLevel.info);
      ShuLog.i('conn', 'x');
      ShuLog.instance.clear();
      expect(ShuLog.instance.isEmpty, isTrue);
      ShuLog.instance.clear();
      expect(ShuLog.instance.isEmpty, isTrue);
    });

    test('lines 把每条记录展平成物理行', () {
      ShuLog.instance.configure(enabled: true, level: ShuLogLevel.info);
      ShuLog.i('conn', 'a\nb');
      expect(ShuLog.instance.lines.length, 2);
    });
  });

  group('ShuLogRecord', () {
    test('格式化：时间 → 等级（补齐 5 位）→ 标签 → 正文', () {
      final record = ShuLogRecord(
        time: DateTime(2026, 9, 29, 8, 5, 3, 42),
        level: ShuLogLevel.warn,
        tag: 'jwxt',
        message: '未解出姓名',
      );
      expect(record.format(), '08:05:03.042 WARN  [jwxt] 未解出姓名');
    });

    test('多行消息的续行缩进到正文那一列', () {
      final record = ShuLogRecord(
        time: DateTime(2026, 9, 29, 8, 5, 3, 42),
        level: ShuLogLevel.error,
        tag: 'conn',
        message: '证书指纹不匹配\n已固定: aa\n本次:   bb',
      );
      final lines = record.formatLines();
      expect(lines, hasLength(3));
      expect(lines.first, '08:05:03.042 ERROR [conn] 证书指纹不匹配');
      // 续行前面是等宽的空白，长度正好等于首行前缀。
      expect(lines[1].trimLeft(), '已固定: aa');
      expect(
        lines[1].length - lines[1].trimLeft().length,
        lines.first.length - '证书指纹不匹配'.length,
      );
    });
  });

  group('mask', () {
    test('太短的值整体打掉', () {
      expect(mask('abc'), '••••');
    });

    test('长的值只留首尾', () {
      final masked = mask('0123456789abcdef');
      expect(masked, startsWith('0123'));
      expect(masked, endsWith('cdef'));
      expect(masked, contains('••••'));
      expect(masked.length, lessThan('0123456789abcdef'.length));
    });
  });
}
