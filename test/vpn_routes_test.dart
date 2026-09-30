// 「网关资源表 → 系统 VPN 路由表」的离线单测。
//
// 这一段是这条数据面能不能工作的分水岭：路由表错了，VPN 就会把流量引向
// 一个只会丢弃的黑洞（详见 `vpn_routes.dart` 的说明）。全部是纯函数，
// 不需要真机也不需要网络。

import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/vpn_routes.dart';

ATrustRoute _route(
  String host, {
  String protocol = 'all',
  int portMin = 1,
  int portMax = 65535,
  bool l3 = false,
}) => ATrustRoute(
  host: host,
  protocol: protocol,
  portMin: portMin,
  portMax: portMax,
  appId: 'app',
  nodeGroupId: 'group',
  addrPretend: false,
  enableTcpPrefL3: l3,
);

void main() {
  group('shuVpnRoutePlanFor', () {
    test('单个地址变成 /32', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[_route('10.1.2.3')]);
      expect(plan.tunRoutes, <String>['10.1.2.3/32']);
    });

    test('CIDR 原样保留，按数值排序', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.0/8'),
        _route('192.168.5.0/24'),
      ]);
      expect(plan.tunRoutes, <String>['10.0.0.0/8', '192.168.5.0/24']);
    });

    test('CIDR 会被按掩码对齐', () {
      // 网关偶尔下发主机位不为 0 的写法，交给 addRoute 之前先归位。
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[_route('10.1.2.3/8')]);
      expect(plan.tunRoutes, <String>['10.0.0.0/8']);
    });

    test('区间拆成最少的若干网段', () {
      // 10.0.0.0 ~ 10.0.0.255 恰好是一整个 /24。
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.0~10.0.0.255'),
      ]);
      expect(plan.tunRoutes, <String>['10.0.0.0/24']);
    });

    test('不对齐的区间也能拆全', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.1~10.0.0.6'),
      ]);
      // 1/32 + 2/31 + 4/31 = .1 与 .2-.3 与 .4-.5 与 .6 —— 展开后必须
      // 精确覆盖，不能多也不能少。
      expect(plan.tunRoutes, <String>[
        '10.0.0.1/32',
        '10.0.0.2/31',
        '10.0.0.4/31',
        '10.0.0.6/32',
      ]);
      expect(plan.covers('10.0.0.0'), isFalse);
      expect(plan.covers('10.0.0.7'), isFalse);
      for (final host in <String>[
        '10.0.0.1',
        '10.0.0.2',
        '10.0.0.3',
        '10.0.0.4',
        '10.0.0.5',
        '10.0.0.6',
      ]) {
        expect(plan.covers(host), isTrue, reason: '$host 应该被覆盖');
      }
    });

    test('被更大网段包含的会被折叠掉', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.0/8'),
        _route('10.1.0.0/16'),
        _route('10.1.2.3'),
      ]);
      expect(plan.tunRoutes, <String>['10.0.0.0/8']);
    });

    test('完全重复的条目只留一条', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.0/8'),
        _route('10.0.0.0/8', protocol: 'tcp'),
        _route('10.0.0.0/8', protocol: 'udp'),
      ]);
      expect(plan.tunRoutes, <String>['10.0.0.0/8']);
      expect(plan.resourceRoutes, 3);
    });

    test('域名型的进不了路由表，但会被数出来、也会被列出来', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('*.shu.edu.cn'),
        _route('jwxt.shu.edu.cn'),
        _route('*.shu.edu.cn'),
        _route('10.0.0.0/8'),
      ]);
      expect(plan.tunRoutes, <String>['10.0.0.0/8']);
      expect(plan.domainRoutes, 3);
      // 域名清单是代理那一侧唯一能吃到的资源，日志要能把它列出来。
      // 重复的写法只留一条 —— 网关常常把同一个域名给多个应用各列一遍。
      expect(plan.domainHosts, <String>['*.shu.edu.cn', 'jwxt.shu.edu.cn']);
    });

    test('describe 同时给出网段与域名', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.0/8'),
        _route('*.shu.edu.cn'),
      ]);
      final text = plan.describe();
      expect(text, contains('资源表 2 条'));
      expect(text, contains('网段 10.0.0.0/8'));
      expect(text, contains('域名 *.shu.edu.cn'));
      // 行内只用 ` · ` 一种分隔符：这一行会和别的日志排在一起看，
      // 符号越单一越好扫。
      expect(text, isNot(contains('；')));
      expect(text, isNot(contains('——')));
      expect(text, isNot(contains('（')));
    });

    test('全是域名时路由表为空 —— 调用方据此明确报错', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[_route('*.shu.edu.cn')]);
      expect(plan.isEmpty, isTrue);
      expect(plan.describe(), contains('接管'));
    });

    test('数出 TCP 走 L3 的条数', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.0/8', protocol: 'tcp', l3: true),
        _route('10.1.0.0/16', protocol: 'tcp'),
        _route('10.2.0.0/16', protocol: 'udp'),
      ]);
      expect(plan.tcpL3Routes, 1);
    });

    test('跳过写坏的条目而不是抛异常', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route(''),
        _route('10.0.0.0/99'),
        _route('999.1.1.1'),
        _route('10.0.0.5~10.0.0.1'),
        _route('10.0.0.0/8'),
      ]);
      expect(plan.tunRoutes, <String>['10.0.0.0/8']);
      expect(plan.resourceRoutes, 5);
    });

    test('网关真的声明全路由时会保留 /0', () {
      // 这一条**只**可能来自网关（我们自己永远不会造它）。
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[_route('0.0.0.0/0')]);
      expect(plan.tunRoutes, <String>['0.0.0.0/0']);
      expect(plan.covers('8.8.8.8'), isTrue);
    });

    test('covers 按网段判断包含关系', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[_route('10.0.0.0/24')]);
      expect(plan.covers('10.0.0.1'), isTrue);
      expect(plan.covers('10.0.0.255'), isTrue);
      expect(plan.covers('10.0.1.1'), isFalse);
      expect(plan.covers('不是地址'), isFalse);
    });

    // 这一条是「VPN 开着但一个包都不进 TUN」的真因所在：
    // `VpnService.Builder` 会**封掉**没有配置过的地址族，而本应用只配了 IPv4。
    // 原生侧据此决定要不要 `allowFamily(AF_INET6)`。
    test('IPv4 专用的资源表不会声称接管 IPv6', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.0/8'),
        _route('192.168.5.1'),
        _route('*.shu.edu.cn'),
      ]);
      expect(plan.hasIpv6Routes, isFalse);
      expect(plan.describe(), contains('只接管 IPv4'));
      expect(plan.describe(), contains('IPv6 已放行'));
    });

    test('网关真的下发 IPv6 网段时才算「配置过」那一族', () {
      // `_parseCidr` 只认 IPv4，所以这类写法会被当成域名型 —— 但即便如此，
      // 「有没有 IPv6 网段」这个判断也必须有一个确定答案（现在是「没有」）。
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[_route('2001:db8::/32')]);
      expect(plan.hasIpv6Routes, isFalse);
      expect(plan.tunRoutes, isEmpty);
    });
  });

  group('shuTunnelDnsFor', () {
    test('只留下落在路由表内的 DNS', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[_route('10.0.0.0/8')]);
      expect(
        shuTunnelDnsFor(plan, <String>['10.9.9.9', '8.8.8.8', '10.1.1.1']),
        <String>['10.9.9.9', '10.1.1.1'],
      );
    });

    test('一个都不在路由表内时返回空表（由底层 DNS 兜底）', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[_route('10.0.0.0/8')]);
      expect(shuTunnelDnsFor(plan, <String>['8.8.8.8', '1.1.1.1']), isEmpty);
    });

    test('空路由表不会留下任何 DNS', () {
      const plan = ShuVpnRoutePlan(
        tunRoutes: <String>[],
        l3Routes: <String>[],
        resourceRoutes: 0,
        domainRoutes: 0,
        tcpL3Routes: 0,
      );
      expect(shuTunnelDnsFor(plan, <String>['10.9.9.9']), isEmpty);
    });
  });

  // 这一组是「浏览器指向代理之后什么都打不开」的那个问题在代码里的落点：
  // 代理按**域名**拨号，判定必须与隧道内部用的那一份完全一致。
  group('shuProxyRouteFor', () {
    test('域名命中域名型资源', () {
      final routes = <ATrustRoute>[_route('*.shu.edu.cn')];
      expect(shuProxyRouteFor(routes, 'jwxt.shu.edu.cn', 443), isNotNull);
    });

    test('域名不匹配时返回 null —— 调用方据此走直连兜底', () {
      final routes = <ATrustRoute>[_route('*.shu.edu.cn')];
      expect(shuProxyRouteFor(routes, 'api.ipify.org', 443), isNull);
    });

    test('字面地址走网段匹配', () {
      final routes = <ATrustRoute>[_route('10.0.0.0/8')];
      expect(shuProxyRouteFor(routes, '10.1.2.3', 443), isNotNull);
      expect(shuProxyRouteFor(routes, '192.168.99.1', 80), isNull);
    });

    test('端口区间照旧是一条门', () {
      final routes = <ATrustRoute>[
        _route('10.0.0.0/8', portMin: 443, portMax: 443),
      ];
      expect(shuProxyRouteFor(routes, '10.1.2.3', 443), isNotNull);
      expect(shuProxyRouteFor(routes, '10.1.2.3', 80), isNull);
    });

    test('标了 L3 优先的资源也算命中 —— 与本应用的拨号参数一致', () {
      // `ATrustConnector.dialTcp` 丢掉了 `includeL3Preferred`，本应用自己
      // 传了 true（见 `_dialerFor`）。预检必须用同一个值，否则会在隧道
      // 本来连得上的目标上错误地改走直连。
      final routes = <ATrustRoute>[
        _route('10.0.0.0/8', protocol: 'tcp', l3: true),
      ];
      expect(shuProxyRouteFor(routes, '10.1.2.3', 443), isNotNull);
    });

    test('UDP 资源不会让 TCP 代理请求命中', () {
      final routes = <ATrustRoute>[_route('10.0.0.0/8', protocol: 'udp')];
      expect(shuProxyRouteFor(routes, '10.1.2.3', 443), isNull);
    });
  });

  group('shuRouteLabel', () {
    test('带上协议与端口区间，以及 app / 节点组', () {
      expect(
        shuRouteLabel(_route('10.0.0.0/8')),
        '10.0.0.0/8 app=app gid=group',
      );
      expect(
        shuRouteLabel(
          _route('10.0.0.0/8', protocol: 'tcp', portMin: 443, portMax: 443),
        ),
        '10.0.0.0/8/tcp:443 app=app gid=group',
      );
      expect(
        shuRouteLabel(_route('10.0.0.0/8', portMin: 80, portMax: 8080)),
        '10.0.0.0/8:80-8080 app=app gid=group',
      );
    });

    test('没有 app / 节点组时不写那两段', () {
      expect(
        shuRouteLabel(
          const ATrustRoute(
            host: '10.0.0.0/8',
            protocol: 'all',
            portMin: 0,
            portMax: 65535,
            appId: '',
            nodeGroupId: '',
            addrPretend: false,
          ),
        ),
        '10.0.0.0/8',
      );
    });
  });

  // 这一组是「学校明明把整张网都授权了，客户端却说什么都不在资源表内」
  // 那个问题的落点。网关用**破折号**写地址区间，而 SDK 的匹配器只认 `/`、`~`
  // 和单个地址 —— 一条都不认，于是最大的那几条授权静默消失。
  group('破折号区间', () {
    test('`起始-结束` 与 `~` 一样能拆成网段', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.0.0.0-10.0.0.255'),
      ]);
      expect(plan.tunRoutes, <String>['10.0.0.0/24']);
    });

    test('不对齐的破折号区间精确覆盖，不多不少', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('49.52.105.0-49.52.111.255'),
      ]);
      expect(plan.domainRoutes, 0);
      expect(plan.covers('49.52.105.0'), isTrue);
      expect(plan.covers('49.52.111.255'), isTrue);
      expect(plan.covers('49.52.104.255'), isFalse);
      expect(plan.covers('49.52.112.0'), isFalse);
    });

    test('整张 IPv4 表（`1.0.0.0-255.255.255.255`）真的是整张表', () {
      // SHU 的网关就是这么授权 Web 端口的，它等价于「上网全走学校出口」。
      // 0.x 段不在区间里 —— 这一点也要对，否则就是多接管了一段。
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('1.0.0.0-255.255.255.255', protocol: 'tcp'),
      ]);
      expect(plan.covers('1.0.0.1'), isTrue);
      expect(plan.covers('202.120.127.37'), isTrue);
      expect(plan.covers('255.255.255.255'), isTrue);
      expect(plan.covers('0.1.2.3'), isFalse);
    });

    test('SDK 的匹配器原本认不出区间，展开之后就认得了', () {
      final routes = <ATrustRoute>[
        _route(
          '1.0.0.0-255.255.255.255',
          protocol: 'tcp',
          portMin: 443,
          portMax: 443,
        ),
      ];
      // 展开之前：网关说「整张网的 443 都给你」，SDK 说「不在资源表内」。
      expect(shuProxyRouteFor(routes, '202.120.127.37', 443), isNull);
      expect(shuProxyRouteFor(routes, 'www.shu.edu.cn', 443), isNull);

      expect(shuExpandATrustRouteRanges(routes), isTrue);

      // 展开之后：按**地址**拨号才命中 —— 这正是拨号那一侧要先解析域名的
      // 原因（见 `ConnectionController._dialATrust`）。
      expect(shuProxyRouteFor(routes, '202.120.127.37', 443), isNotNull);
      // 域名本身仍然匹配不上：区间是按地址写的，没有名字可比。
      expect(shuProxyRouteFor(routes, 'www.shu.edu.cn', 443), isNull);
      // 端口仍然是门。
      expect(shuProxyRouteFor(routes, '202.120.127.37', 80), isNull);
    });

    test('展开是幂等的 —— 同一条资源表只会追加一次', () {
      final routes = <ATrustRoute>[_route('10.0.0.0-10.0.0.255')];
      final before = routes.length;
      expect(shuExpandATrustRouteRanges(routes), isTrue);
      final after = routes.length;
      expect(after, greaterThan(before));
      expect(shuExpandATrustRouteRanges(routes), isFalse);
      expect(routes.length, after);
    });

    test('没有区间时什么都不做', () {
      final routes = <ATrustRoute>[
        _route('10.0.0.0/8'),
        _route('*.shu.edu.cn'),
      ];
      expect(shuExpandATrustRouteRanges(routes), isFalse);
      expect(routes.length, 2);
    });
  });

  // TUN 只能背得动 UDP：`matchL3Route` 对 TCP 有 `enableTcpPrefL3` 那道硬门，
  // 而路由是按**目的地址**下发的，认不出协议。把 TCP 也能到达的网段交出去，
  // 那些地址上的 TCP 就会进一个不报错的黑洞。
  group('l3Routes（交给 TUN 的那一批）', () {
    test('只有 UDP 资源占用的网段才进得去', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.10.0.116', protocol: 'udp', portMin: 53, portMax: 53),
      ]);
      expect(plan.l3Routes, <String>['10.10.0.116/32']);
    });

    test('同一段上还有 TCP 资源时被摘掉', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        // `10.0.1.116` 落在 `10.0.0.0/16` 里面。
        _route('10.0.1.116', protocol: 'udp', portMin: 53, portMax: 53),
        _route('10.0.0.0/16', protocol: 'all'),
      ]);
      // `10.0.0.0/16` 是 `all`，能到 TCP —— 它一出现，落在里面的 DNS 段
      // 就不该再进 TUN。
      expect(plan.l3Routes, isEmpty);
      // 但资源表本身仍然覆盖它（`covers` 回答的是「网关给了我什么」）。
      expect(plan.covers('10.0.1.116'), isTrue);
    });

    test('SHU 网关那 21 条资源下 l3Routes 是空的 —— 那不是 bug', () {
      // 这一段是照抄实测日志里那一整张表的形状（`04:54:02 DEBUG [conn] 资源[N]`）。
      // 结论很反直觉但很重要：只要网关给了 `1.0.0.0-255.255.255.255/tcp:*`
      // 这种整表 Web 授权，**任何**内部网段都会被那道 TCP 门压住，TUN 因此
      // 一条路由都不该接。TCP 全部走本机代理，L3 只服务少数 UDP。
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.10.0.209', protocol: 'tcp'),
        _route('10.10.10.196', protocol: 'tcp'),
        _route('10.10.22.152-10.10.22.154'),
        _route('10.0.0.0/16'),
        _route(
          '202.120.119.224-202.120.119.254',
          protocol: 'udp',
          portMin: 0,
          portMax: 65535,
        ),
        _route(
          '1.0.0.0-255.255.255.255',
          protocol: 'tcp',
          portMin: 80,
          portMax: 90,
        ),
        _route(
          '1.0.0.0-255.255.255.255',
          protocol: 'tcp',
          portMin: 8000,
          portMax: 9001,
        ),
        _route(
          '1.0.0.0-255.255.255.255',
          protocol: 'tcp',
          portMin: 443,
          portMax: 443,
        ),
        _route('10.3.1.0/24'),
        _route('58.199.128.0/18'),
        _route('49.52.105.0-49.52.111.255'),
        _route('10.10.0.116', protocol: 'udp', portMin: 53, portMax: 53),
        _route('10.10.22.141', protocol: 'udp', portMin: 22, portMax: 22),
        _route('10.10.22.141', protocol: 'tcp', portMin: 22, portMax: 22),
      ]);
      expect(plan.l3Routes, isEmpty);
      // 整张表折叠之后就是那三条 `1.0.0.0-255.255.255.255/tcp:*` 授权本身 ——
      // 其余每一条内部网段都落在它们里面，会被折叠掉。这 8 条合起来覆盖
      // 1.0.0.0 ~ 255.255.255.255。
      expect(plan.tunRoutes, <String>[
        '1.0.0.0/8',
        '2.0.0.0/7',
        '4.0.0.0/6',
        '8.0.0.0/5',
        '16.0.0.0/4',
        '32.0.0.0/3',
        '64.0.0.0/2',
        '128.0.0.0/1',
      ]);
      expect(plan.covers('10.10.0.116'), isTrue);
      expect(plan.covers('202.120.119.240'), isTrue);
      expect(plan.covers('49.52.110.1'), isTrue);
      expect(plan.covers('202.120.127.37'), isTrue);
      expect(plan.covers('0.1.2.3'), isFalse);
    });

    test('同一条网段上既有 TCP 又有 UDP 时按「有 TCP」处理', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route('10.10.22.141', protocol: 'udp', portMin: 22, portMax: 22),
        _route('10.10.22.141', protocol: 'tcp', portMin: 22, portMax: 22),
      ]);
      expect(plan.l3Routes, isEmpty);
      expect(plan.tunRoutes, <String>['10.10.22.141/32']);
    });

    test('破折号区间里的 UDP 也算数', () {
      final plan = shuVpnRoutePlanFor(<ATrustRoute>[
        _route(
          '202.120.119.224-202.120.119.254',
          protocol: 'udp',
          portMin: 0,
          portMax: 65535,
        ),
      ]);
      expect(plan.l3Routes, isNotEmpty);
      expect(
        plan.l3Routes.every((route) => route.startsWith('202.120.119.')),
        isTrue,
      );
    });
  });

  // 实验开关：本地把网关的 `enableTCPPrefL3` 翻成打开，验证服务端到底接不
  // 接受 TCP-over-L3。它改的是客户端的信念，所以「改了哪些、没改哪些」必须
  // 钉死 —— 翻错一类（比如把 UDP 也翻了）会让实验的结论失去意义。
  group('shuForceTcpOverL3', () {
    test('翻转 TCP 与 all，保留 UDP', () {
      final routes = <ATrustRoute>[
        _route('10.0.0.0/8', protocol: 'tcp'),
        _route('10.1.0.0/16'),
        _route('10.2.0.0/16', protocol: 'udp'),
      ];

      expect(shuForceTcpOverL3(routes), 2);
      expect(routes[0].enableTcpPrefL3, isTrue);
      expect(routes[1].enableTcpPrefL3, isTrue);
      // `matchL3Route` 对 UDP 本来就没有那道门，翻它只会让
      // `matchTcpRoute` 开始排除它 —— 那是引入新 bug。
      expect(routes[2].enableTcpPrefL3, isFalse);
    });

    test('已经打开的不重复计数', () {
      final routes = <ATrustRoute>[
        _route('10.0.0.0/8', protocol: 'tcp', l3: true),
      ];
      expect(shuForceTcpOverL3(routes), 0);
      expect(routes.single.enableTcpPrefL3, isTrue);
    });

    test('除标志外其余字段一字不动', () {
      final routes = <ATrustRoute>[
        ATrustRoute(
          host: '1.0.0.0-255.255.255.255',
          protocol: 'tcp',
          portMin: 443,
          portMax: 443,
          appId: 'app-1',
          nodeGroupId: 'group-9',
          addrPretend: true,
        ),
      ];
      shuForceTcpOverL3(routes);
      final route = routes.single;
      expect(route.host, '1.0.0.0-255.255.255.255');
      expect(route.portMin, 443);
      expect(route.portMax, 443);
      expect(route.appId, 'app-1');
      expect(route.nodeGroupId, 'group-9');
      expect(route.addrPretend, isTrue);
    });

    test('翻转之后 l3Routes 从空变成整张表 —— 那正是实验要的', () {
      final routes = <ATrustRoute>[
        _route(
          '1.0.0.0-255.255.255.255',
          protocol: 'tcp',
          portMin: 443,
          portMax: 443,
        ),
        _route('10.10.0.116', protocol: 'udp', portMin: 53, portMax: 53),
      ];
      final before = shuVpnRoutePlanFor(routes);
      // 常态：TCP 那几条把同段内的 UDP 顶掉，一片都不进 TUN。
      expect(before.l3Routes, isEmpty);
      expect(before.tcpL3Routes, 0);

      shuForceTcpOverL3(routes);
      final after = shuVpnRoutePlanFor(routes);
      expect(after.tcpL3Routes, 1);
      // 整张 IPv4 表（`10.10.0.116` 落在 `8.0.0.0/5` 里面，被并掉了）。
      expect(after.l3Routes, <String>[
        '1.0.0.0/8',
        '2.0.0.0/7',
        '4.0.0.0/6',
        '8.0.0.0/5',
        '16.0.0.0/4',
        '32.0.0.0/3',
        '64.0.0.0/2',
        '128.0.0.0/1',
      ]);
      // 两种模式交出去的东西在这一次恰好相同 —— 因为这张表本来就是整表授权。
      expect(after.tunRoutes, before.tunRoutes);
    });

    test('只翻转「走不了 L3 的 TCP」，已经是 L3 的资源不参与压制', () {
      // 网关自己就把 TCP 开在 L3 上的话，那一段交给 TUN 是**对的** ——
      // `tcpTouched` 不该把它算进去，否则 UDP 段会被平白顶掉。
      final routes = <ATrustRoute>[
        _route('10.0.0.0/16', protocol: 'tcp', l3: true),
        _route('10.10.0.116', protocol: 'udp', portMin: 53, portMax: 53),
      ];
      final plan = shuVpnRoutePlanFor(routes);
      expect(plan.l3Routes, contains('10.10.0.116/32'));
      expect(plan.l3Routes, contains('10.0.0.0/16'));
    });
  });
}
