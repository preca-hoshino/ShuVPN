// `ShuProxyListen` 的离线单测。
//
// 这一层有两个容易出错的转向点，各配一组用例：
//
// 1. **解析**：用户手填之后，坏值必须在对话框那一步就被挡住，而不是留到
//    绑定时抛 `SocketException`（那时用户看到的是「代理起不来」）；
// 2. **回读**：磁盘上可能有早期版本写下的枚举 id，认不出来的值必须退回
//    最保守的 `127.0.0.1` —— 「读不懂就放行」在这条设置上是安全事故。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/proxy_listen.dart';

void main() {
  group('parse', () {
    test('认 IPv4 字面地址', () {
      expect(ShuProxyListen.parse('127.0.0.1')?.address, '127.0.0.1');
      expect(ShuProxyListen.parse('192.168.99.144')?.address, '192.168.99.144');
      expect(ShuProxyListen.parse('0.0.0.0')?.address, '0.0.0.0');
    });

    test('去掉首尾空格', () {
      expect(ShuProxyListen.parse('  10.0.0.2  ')?.address, '10.0.0.2');
    });

    test('认 IPv6', () {
      expect(ShuProxyListen.parse('::1')?.address, '::1');
      expect(ShuProxyListen.parse('::')?.allInterfaces, isTrue);
    });

    test('存下来的字符串与绑定时用的那个逐字一致', () {
      // 这条不变量是「界面显示什么 = 实际绑了什么」的基础。
      for (final raw in <String>['127.0.0.1', '0.0.0.0', '::1', 'fe80::1']) {
        final listen = ShuProxyListen.parse(raw)!;
        expect(listen.address, listen.internetAddress.address);
      }
    });

    test('拒绝主机名 —— 绑定地址不能依赖一次 DNS 查询', () {
      expect(ShuProxyListen.parse('localhost'), isNull);
      expect(ShuProxyListen.parse('example.com'), isNull);
    });

    test('拒绝空值与越界的八位组', () {
      expect(ShuProxyListen.parse(''), isNull);
      expect(ShuProxyListen.parse('   '), isNull);
      expect(ShuProxyListen.parse('999.1.1.1'), isNull);
      expect(ShuProxyListen.parse('127.0.0'), isNull);
      expect(ShuProxyListen.parse('127.0.0.1/24'), isNull);
    });
  });

  group('判性质', () {
    test('只有回环不需要确认', () {
      expect(ShuProxyListen.loopback.isLoopback, isTrue);
      expect(ShuProxyListen.loopback.exposesToNetwork, isFalse);

      for (final value in <ShuProxyListen>[
        ShuProxyListen.anyNetwork,
        ShuProxyListen.anyNetworkV6,
        ShuProxyListen.parse('192.168.99.144')!,
      ]) {
        expect(value.isLoopback, isFalse);
        expect(value.exposesToNetwork, isTrue);
      }
    });

    test('所有网卡的两种写法都认出来', () {
      expect(ShuProxyListen.anyNetwork.allInterfaces, isTrue);
      expect(ShuProxyListen.anyNetworkV6.allInterfaces, isTrue);
      expect(ShuProxyListen.parse('192.168.99.144')!.allInterfaces, isFalse);
    });

    test('绑定对象就是那个地址', () {
      expect(
        ShuProxyListen.parse('192.168.99.144')!.internetAddress,
        InternetAddress('192.168.99.144'),
      );
      // 0.0.0.0 解析出来就是「任意地址」，不需要特判。
      expect(
        ShuProxyListen.anyNetwork.internetAddress,
        InternetAddress.anyIPv4,
      );
    });
  });

  group('显示', () {
    test('预设显示「名字 · 地址」，自定义地址直接显示地址', () {
      expect(ShuProxyListen.loopback.label, '仅本机');
      expect(ShuProxyListen.loopback.display, '仅本机 · 127.0.0.1');
      expect(ShuProxyListen.anyNetwork.display, '所有网卡 · 0.0.0.0');
      expect(ShuProxyListen.parse('192.168.99.144')!.label, '192.168.99.144');
      expect(ShuProxyListen.parse('192.168.99.144')!.display, '192.168.99.144');
    });
  });

  group('fromStored', () {
    test('读回地址本身', () {
      expect(ShuProxyListen.fromStored('10.0.0.2').address, '10.0.0.2');
    });

    test('认下早期版本写过的两个枚举 id', () {
      expect(ShuProxyListen.fromStored('loopback'), ShuProxyListen.loopback);
      expect(ShuProxyListen.fromStored('any'), ShuProxyListen.anyNetwork);
    });

    test('认不出的一律退回回环', () {
      // 白名单语义：坏值不能变成「监听所有网卡」。
      for (final raw in <String?>[null, '', 'all', '0.0.0.0/0', '999.9.9.9']) {
        expect(ShuProxyListen.fromStored(raw), ShuProxyListen.loopback);
      }
    });
  });

  test('相等性看地址', () {
    expect(ShuProxyListen.parse('10.0.0.1'), ShuProxyListen.parse('10.0.0.1'));
    expect(ShuProxyListen.parse('10.0.0.1'), isNot(ShuProxyListen.loopback));
  });
}
