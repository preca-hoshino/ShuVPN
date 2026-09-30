// Smoke tests for the app shell.
//
// They never touch the VPN or the network: the native library is only loaded
// when the orb is pressed with a complete draft, and the account page starts
// signed out, so no request is ever issued.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/app/app.dart';
import 'package:shuvpn/core/auth/auth_constants.dart';
import 'package:shuvpn/core/connection/protocol.dart';
import 'package:shuvpn/core/logging/shu_log.dart';
import 'package:shuvpn/core/settings/settings_store.dart';
import 'package:shuvpn/features/connect/connect_page.dart';
import 'package:shuvpn/features/settings/log_page.dart';
import 'package:shuvpn/shell/floating_dock.dart';
import 'package:shuvpn/widgets/settings_scaffold.dart';
import 'package:shuvpn/widgets/shu_app_bar.dart';
import 'package:shuvpn/widgets/shu_surfaces.dart';

Future<void> _pumpApp(
  WidgetTester tester, {
  Size physical = const Size(720, 3600),
  double dpr = 2,
}) async {
  // A tall phone viewport. The shell is laid out for a phone, and a tall one
  // keeps below-the-fold rows built so assertions do not need scroll
  // choreography.
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  await tester.pumpWidget(ShuVpnApp(settings: settings));
  await tester.pump();
}

/// 一台真手机的视口：1200×2670 @3.25（即 369×821 逻辑像素），上下各留
/// 24 的状态栏与手势条。
///
/// 抽屉里那一列内容是一个固定高度，而抽屉的上限是**比例** —— 两个数在
/// 高瘦的测试视口里永远碰不到一起，只有拿真机尺寸才能撞出「最后一行被切
/// 掉」这种问题。
Future<void> _pumpPhone(WidgetTester tester) async {
  tester.view.padding = const FakeViewPadding(top: 78, bottom: 78);
  await _pumpApp(tester, physical: const Size(1200, 2670), dpr: 3.25);
}

/// Switches the bottom dock.
///
/// The tab is addressed **inside the dock** rather than by bare text: the
/// settings page's AppBar title is literally `设置`, and so is the dock label,
/// so a bare `find.text('设置')` matches two widgets. The dock is also the only
/// one of the two that is always on screen.
Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(FloatingDock), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// Opens a settings sub-page from the catalogue.
///
/// It always goes through the dock first. A sub-page is pushed on the root
/// navigator and therefore covers the dock, so the dock is only reachable once
/// the previous page has been popped — every caller in this file does that.
///
/// The row is addressed **inside a `ListTile`**, for the same reason as
/// [_openTab]: the dock's middle label is also called `连接`.
Future<void> _openSettings(WidgetTester tester, String entry) async {
  await _openTab(tester, '设置');
  await tester.tap(_settingsRow(entry));
  await tester.pumpAndSettle();
}

/// A settings row by its title, scoped to the `ListTile` that carries it.
Finder _settingsRow(String title) =>
    find.descendant(of: find.byType(ListTile), matching: find.text(title));

/// 连接页底部那张抽屉现在停在哪一档 —— 读的是第一行在屏幕上的纵向位置。
///
/// 这一行是唯一可靠的锚点：两种档位下它都在树里（不像下面那几组，未拉开时
/// 可能落在 `ListView` 的缓存区外），而拉开之后整张单子被顶上去，这一行的 y
/// 直接跟着变。比「某个控件在不在树里」稳 —— 缓存区会替我们建出屏幕外的行，
/// `findsNothing` 在这种布局上不可靠。
///
/// 两个取数的包装：`_drawerRowTop` 给「拉开后往上走了多少」，
/// `_drawerRowFromBottom` 给「它是不是还贴着底」——后者不需要先取一次基线。
double _drawerRowTop(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(ConnectPage.statusRowKey)).dy;

double _drawerRowFromBottom(WidgetTester tester) =>
    tester.view.physicalSize.height / tester.view.devicePixelRatio -
    _drawerRowTop(tester);

/// 遮罩有多黑。它是「抽屉拉开了多少」的读数，也是「点一下就收回」那块命中区。
double _scrimAlpha(WidgetTester tester) =>
    tester.widget<ColoredBox>(find.byKey(ConnectPage.scrimKey)).color.a;

/// 点抽屉外面。不能用 `tap` —— 那一下落在遮罩的**中心**，而那里被抽屉
/// 自己盖住了。坐标是逻辑像素（视口 360×1800），120 在 appbar 之下、
/// 抽屉之上。
Future<void> _tapOutside(WidgetTester tester) async {
  await tester.tapAt(const Offset(180, 120));
  await tester.pumpAndSettle();
}

/// Pops a settings sub-page.
///
/// Not `tester.pageBack()`: that looks for a `Back` tooltip, and this app
/// labels the affordance 「返回」.
Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.arrow_back));
  await tester.pumpAndSettle();
}

void main() {
  // 日志缓冲区是**进程级单例**，跨用例留着会把上一条的现场带进来。
  setUp(ShuLog.instance.clear);

  testWidgets('the connect page is an orb plus a two-stage drawer', (
    tester,
  ) async {
    await _pumpApp(tester);

    // 大圆自己带着状态词。
    expect(find.text('未连接'), findsOneWidget);

    // 未拉开时那一行说的是「我要连谁」：协议名 + 服务器地址。
    expect(find.text('atrust.shu.edu.cn'), findsOneWidget);

    // 出厂是**未拉开**那一档：那一行还贴在屏幕底上。
    //
    // 上限 300 不是量出来的一个精确值，而是「不可能属于另一档」的一个界：
    // 未拉开时它离底边只有一个空白高度（视口高度的 6% 与 80 像素取大者，
    // 再加把手的 22 与内边距），而拉开之后光抽屉本身就 480。
    expect(
      _drawerRowFromBottom(tester),
      lessThan(300),
      reason: '抽屉出厂应当停在未拉开那一档',
    );

    // 没拉开时背景是原色 —— 遮罩一点浓度也没有。
    expect(_scrimAlpha(tester), 0);

    expect(find.text('虚拟 IP'), findsNothing);
    expect(find.text('时长'), findsNothing);
    expect(find.textContaining('还没有填完账户信息'), findsNothing);
  });

  testWidgets('the drawer pulls open, then pushes back down', (tester) async {
    await _pumpApp(tester);
    final collapsed = _drawerRowTop(tester);

    // 点把手：抽屉里唯一「点一下就换档」的东西 —— 那一行字自己是只读的，
    // 它没有可点的外观，也不需要点。
    await tester.tap(find.byKey(ConnectPage.grabberKey));
    await tester.pumpAndSettle();

    final opened = _drawerRowTop(tester);
    expect(opened, lessThan(collapsed), reason: '拉开之后整张单子被顶上去');

    // 背景暗下去了 —— 而且暗的正是抽屉没占的那一块。
    expect(_scrimAlpha(tester), greaterThan(0.3));

    // 协议是一组裸行（学设置页），每行带自己的图标。
    expect(find.text('协议'), findsOneWidget);
    for (final protocol in ShuProtocol.values) {
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.byIcon(protocol.icon),
        ),
        findsOneWidget,
        reason: '${protocol.label} 应该带自己的 icon',
      );
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text(protocol.label),
        ),
        findsOneWidget,
      );
    }
    // 当前那条说「使用中」；未接的两条说「未接入」。
    expect(find.text('使用中'), findsOneWidget);
    expect(find.text('未接入'), findsNWidgets(2));

    // 连接方式：三条通道各自监听在哪里，地址后面跟一颗复制按钮。
    // 地址是**设置里那个**（出厂回环 + 两个错开的端口），不是虚拟 IP。
    expect(find.text('连接方式'), findsOneWidget);
    expect(find.text('HTTP 代理'), findsOneWidget);
    expect(
      find.text('127.0.0.1:${SettingsStore.defaultHttpPort}'),
      findsOneWidget,
    );
    expect(find.text('SOCKS5 代理'), findsOneWidget);
    expect(
      find.text('127.0.0.1:${SettingsStore.defaultSocksPort}'),
      findsOneWidget,
    );
    expect(find.text('Android VPN 服务'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy), findsNWidgets(2));

    final drawerTop = tester.getTopLeft(find.byKey(ConnectPage.grabberKey)).dy;
    final lastRowBottom = tester.getBottomLeft(find.text('Android VPN 服务')).dy;
    // 这一列内容（六行 + 两行组标题 + 上面那一行字）比未拉开那一档高得多，
    // 但它必须装得进拉开那一档 —— 真机视口下那一条用例把这件事钉住。
    expect(lastRowBottom - drawerTop, greaterThan(400));

    // 上面那一行已经说过的两件事不再各占一行：服务器地址是那一行的副标题，
    // 协议的当前状态也由「哪一行写着使用中」当场回答了。
    expect(find.text('服务器'), findsNothing);
    expect(find.text('本机代理'), findsNothing);

    // 点抽屉外面：收回去，背景也跟着亮回来。
    await _tapOutside(tester);
    expect(
      _drawerRowTop(tester),
      closeTo(collapsed, 1),
      reason: '点外面应当收回未拉开那一档',
    );
    expect(_scrimAlpha(tester), 0);
  });

  testWidgets('the drawer follows a drag, not only a tap', (tester) async {
    await _pumpApp(tester);
    final collapsed = _drawerRowTop(tester);
    expect(_scrimAlpha(tester), 0);

    // 直接甩上去 —— 不经过任何点击。两段式抽屉的「两段」应当对手势也成立。
    await tester.dragFrom(
      tester.getCenter(find.byKey(ConnectPage.statusRowKey)),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    // 往上走了 200 以上，就不是「抖了一下」而是真的换了一档。
    expect(_drawerRowTop(tester), lessThan(collapsed - 200));
    expect(find.text('连接方式'), findsOneWidget);
  });

  testWidgets('the drawer holds its whole list on a phone viewport', (
    tester,
  ) async {
    await _pumpPhone(tester);
    // 遮罩铺满整层、抽屉压在它上面，所以「遮罩底 − 抓手顶」量到的正是抽屉
    // 露出来的那一档高度 —— 未拉开时它等于 `_ConnectionDrawer.peekHeight`。
    final earlyPeek =
        tester.getRect(find.byKey(ConnectPage.scrimKey)).bottom -
        tester.getTopLeft(find.byKey(ConnectPage.grabberKey)).dy;
    await tester.pumpAndSettle();
    final settledPeek =
        tester.getRect(find.byKey(ConnectPage.scrimKey)).bottom -
        tester.getTopLeft(find.byKey(ConnectPage.grabberKey)).dy;
    expect(settledPeek, closeTo(earlyPeek, 1), reason: '吸附落地不该让抽屉跳一下');
    expect(
      settledPeek,
      inInclusiveRange(48, 160),
      reason: '未拉开那一档只放得下把手与状态行，不该长到把大圆顶走',
    );

    await tester.tap(find.byKey(ConnectPage.grabberKey));
    await tester.pumpAndSettle();

    // 抽屉的下边界就是遮罩的下边界（两者同一个 `Stack`，都是铺满的）。
    final drawerBottom = tester
        .getRect(find.byKey(ConnectPage.scrimKey))
        .bottom;
    final lastRowBottom = tester.getBottomLeft(find.text('Android VPN 服务')).dy;
    expect(
      lastRowBottom,
      lessThanOrEqualTo(drawerBottom),
      reason: '最后一行不能掉出抽屉外 —— 拉到底还得在抽屉里再滑一下才看得到它',
    );
  });

  testWidgets('the dock switches between the three destinations', (
    tester,
  ) async {
    await _pumpApp(tester);

    await _openTab(tester, '服务');
    expect(find.text('还没有服务列表'), findsOneWidget);

    await _openTab(tester, '设置');
    expect(_settingsRow('账户管理'), findsOneWidget);
    // The catalogue is a bare list of destinations: no numeric setting of its
    // own (those live one level down), no switch, no card wrapper.
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(ShuCard), findsNothing);

    await _openTab(tester, '连接');
    expect(find.text('atrust.shu.edu.cn'), findsOneWidget);

    // 「连接」那一栏是地球，不是盾牌：
    // 盾牌已经是大圆按钮「已连接」那一态的图标，两处同一个字形会让
    // 「底栏这一项」与「隧道现在通不通」看起来是同一件事。
    expect(
      find.descendant(
        of: find.byType(FloatingDock),
        matching: find.byIcon(Icons.language),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the settings page is a bare catalogue of nine destinations', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _openTab(tester, '设置');

    // One row per destination. The names carry no 设置 suffix — PiliPlus uses
    // one (隐私设置, 音视频设置), but this app has exactly one settings page, so
    //「连接设置」 would only repeat what the page title already says.
    for (final entry in <String>[
      '账户管理',
      '外观',
      'aTrust 协议',
      'EasyConnect 协议',
      'OpenVPN 协议',
      '网络连接',
      '实验性选项',
      '日志',
      '关于',
    ]) {
      expect(_settingsRow(entry), findsOneWidget, reason: '$entry 应该有一行入口');
    }

    // Every row is a plain ListTile with a leading icon, a **caption** and no
    // value on the right. The caption is what the catalogue is for (it says
    // what is behind the row); the value is what it deliberately does not have
    // (that would make the whole page repaint whenever a setting changed).
    expect(find.text('主题风格、配色切换'), findsOneWidget);
    expect(find.text('HTTP 与 SOCKS5 代理、Android VPN 服务'), findsOneWidget);
    expect(find.text('尚未稳定的行为，默认全部关闭'), findsOneWidget);
    expect(find.byType(ShuCard), findsNothing);
    expect(find.byType(SectionHeader), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);

    // Deleted long ago, and still gone.
    expect(find.text('路由模式'), findsNothing);
    expect(find.text('允许局域网访问代理'), findsNothing);
    expect(find.text('启动时自动连接'), findsNothing);
    expect(find.text('应用锁'), findsNothing);
    expect(find.text('允许未验证的证书'), findsNothing);
  });

  testWidgets('every settings group opens its own page', (tester) async {
    await _pumpApp(tester);

    await _openSettings(tester, '外观');
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    // Theme is a radio list, not a sheet: three options side by side.
    expect(find.byType(ShuChoiceTile<ThemeMode>), findsNWidgets(3));
    await _back(tester);

    await _openSettings(tester, 'aTrust 协议');
    expect(find.text('启用 aTrust'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('登录域'), findsOneWidget);
    expect(find.text('连接超时'), findsOneWidget);
    expect(find.text('设备标识'), findsOneWidget);
    expect(find.text('认证方式'), findsOneWidget);
    expect(find.text('恢复默认值'), findsOneWidget);
    // The per-row captions are gone — the row name and its value say enough.
    expect(find.textContaining('sfDomain'), findsNothing);
    expect(find.textContaining('统一身份认证'), findsNothing);
    expect(find.byType(ShuSettingsNote), findsNothing);
    await _back(tester);

    // The two protocols that are not wired up carry a switch and one short
    // line. No config rows at all: there is no parameter for them to hold.
    for (final entry in <String>['EasyConnect 协议', 'OpenVPN 协议']) {
      await _openSettings(tester, entry);
      expect(
        find.textContaining('启用 '),
        findsOneWidget,
        reason: '$entry 上应该只有一个开关',
      );
      expect(find.text('未来版本接入服务'), findsOneWidget);
      expect(find.text('服务器地址'), findsNothing);
      expect(find.text('登录域'), findsNothing);
      expect(find.text('连接超时'), findsNothing);
      expect(find.byType(SectionHeader), findsNothing);
      await _back(tester);
    }

    await _openSettings(tester, '关于');
    expect(find.text('第三方开源许可'), findsOneWidget);
    expect(find.text('项目仓库'), findsOneWidget);
    // Credits are prose, not four separate rows: they are not settings.
    expect(find.textContaining('zju-connect'), findsOneWidget);
  });

  testWidgets(
    'the network page is HTTP, SOCKS5, Android VPN — and nothing else',
    (tester) async {
      await _pumpApp(tester);
      await _openSettings(tester, '网络连接');

      for (final label in <String>[
        'HTTP 代理',
        '启用 HTTP 代理',
        'HTTP 监听地址',
        'HTTP 代理端口',
        'SOCKS5 代理',
        '启用 SOCKS5 代理',
        'SOCKS5 监听地址',
        'SOCKS5 代理端口',
        'Android VPN 服务',
        '启用 VPN 服务',
        '系统授权状态',
        'MTU',
        'DNS',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '$label 应该在这一页上');
      }

      // 撤掉的东西：没有直连兜底、没有证书固定、没有运行期统计行，
      // 也没有实验开关 —— 它搬去了「实验性选项」。
      for (final gone in <String>[
        '资源外直连',
        '证书固定',
        '已固定的主机',
        '清除全部指纹',
        '运行状态',
        '目标分流',
        'L3 路由',
        '流量计数',
        '连接超时',
        'TCP 走 L3',
      ]) {
        expect(find.text(gone), findsNothing, reason: '$gone 不该在这一页上');
      }

      // The gateway-facing timeout belongs to the aTrust page, not here.
      expect(find.text('连接超时'), findsNothing);
      // No explanatory prose: every row is a setting, not a paragraph.
      expect(find.byType(ShuSettingsNote), findsNothing);
      expect(find.byType(ShuSettingsWarning), findsNothing);

      // Out-of-the-box values: 2233 / 3322, loopback only, MTU 1400, gateway DNS.
      // 两个端口错开是硬要求：它们可以同时开着，撞在一起时第二个绑不上。
      expect(find.text('3322'), findsOneWidget);
      expect(find.text('2233'), findsOneWidget);
      // 监听地址行显示「名字 · 地址」：只写名字看不出它到底是哪一张网卡。
      // 两个通道各一行，所以一共两个。
      expect(find.text('仅本机 · 127.0.0.1'), findsNWidgets(2));
      expect(find.text('1400'), findsOneWidget);
      expect(find.text('跟随系统'), findsOneWidget);

      // Three switches: the two proxies are off by default, the system VPN is on.
      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(switches, hasLength(3));
      expect(switches[0].value, isFalse, reason: 'HTTP 代理出厂关闭');
      expect(switches[1].value, isFalse, reason: 'SOCKS5 代理出厂关闭');
      expect(switches[2].value, isTrue, reason: 'Android VPN 出厂开启');
    },
  );

  testWidgets('the experimental page warns first, then offers one switch', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _openSettings(tester, '实验性选项');

    // 警告排在所有开关前面：这一页上的东西走不通时是真的上不了网，
    // 而不是“可能稍微卡一点”。
    expect(find.byType(ShuSettingsWarning), findsOneWidget);
    expect(find.textContaining('完全上不了网'), findsOneWidget);

    // 这一页只留一个开关，而且出厂是关的。
    expect(find.text('TCP 走 L3'), findsOneWidget);
    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches, hasLength(1));
    expect(switches.single.value, isFalse, reason: '实验开关出厂关闭');

    // 它只在连接时被读一次，所以不在「网络连接」的运行期锁定里 ——
    // 连着的时候也能改，改动下一次连接生效。
    expect(switches.single.onChanged, isNotNull);

    await _back(tester);
  });

  testWidgets('the defaults live in the settings store, not in the widgets', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await SettingsStore.load();

    expect(settings.socksPort, 2233);
    expect(settings.httpPort, 3322);
    expect(settings.socksProxyEnabled, isFalse);
    expect(settings.httpProxyEnabled, isFalse);
    expect(settings.vpnEnabled, isTrue);
    expect(settings.vpnMtu, 1400);
    expect(settings.vpnDns, isEmpty);
    // 监听范围是一条安全边界，出厂值只能是本机。
    expect(settings.socksListen.label, '仅本机');
    expect(settings.httpListen.label, '仅本机');
  });

  testWidgets('the settings sub-pages drop the card wrapper too', (
    tester,
  ) async {
    // The catalogue and every sub-page it opens have to look like the same
    // list. A teardown to 裸列表 that stopped at the catalogue would be worse
    // than not doing it: the first tap would change the page's whole shape.
    //
    // 账户管理 is the one exception: its identity block is not a row of
    // settings, so it is not part of this contract.
    await _pumpApp(tester);

    for (final entry in <String>[
      '外观',
      'aTrust 协议',
      'EasyConnect 协议',
      'OpenVPN 协议',
      '网络连接',
      '日志',
      '关于',
    ]) {
      await _openSettings(tester, entry);
      expect(find.byType(ShuCard), findsNothing, reason: '$entry 页上不该还有卡片包裹');
      await _back(tester);
    }
  });

  testWidgets('the log destination opens a page, not a sheet', (tester) async {
    await _pumpApp(tester);
    await _openSettings(tester, '日志');

    // 它是一页。曾经的底部弹层装不下「两个设置 + 一块常驻输出区」，
    // 也挡不住键盘 —— 所以这里锁住「不许再变回弹层」。
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(ShuLogPage), findsOneWidget);
    expect(find.byType(ShuAppBar), findsOneWidget);

    // 两个选项：开不开、记到哪一档。
    expect(find.text('启用日志'), findsOneWidget);
    expect(find.text('日志等级'), findsOneWidget);
    // 等级那一行右侧写着当前值。
    expect(find.text('INFO'), findsOneWidget);

    // AppBar 上两个动作：复制全部、清除日志。
    expect(find.byTooltip('复制全部'), findsOneWidget);
    expect(find.byTooltip('清除日志'), findsOneWidget);

    // 一条记录都没有时两个按钮都是灰的 —— 画成可点的样子是骗人。
    final copy = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.copy_all_outlined),
    );
    final clear = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_sweep_outlined),
    );
    expect(copy.onPressed, isNull);
    expect(clear.onPressed, isNull);

    expect(find.text('暂无日志。'), findsOneWidget);
  });

  testWidgets('the log page renders records and the clear button empties it', (
    tester,
  ) async {
    await _pumpApp(tester);
    ShuLog.instance.configure(enabled: true, level: ShuLogLevel.debug);
    ShuLog.i(ShuLogTag.conn, '隧道已建立');

    await _openSettings(tester, '日志');
    // 记录按「时间 等级 [标签] 正文」渲染成一行。
    expect(find.textContaining('隧道已建立'), findsOneWidget);
    expect(find.textContaining('[conn]'), findsOneWidget);
    expect(find.text('暂无日志。'), findsNothing);

    await tester.tap(find.byTooltip('清除日志'));
    await tester.pumpAndSettle();
    expect(find.textContaining('隧道已建立'), findsNothing);
    expect(find.text('暂无日志。'), findsOneWidget);
  });

  testWidgets('the account page lists the account and the visible systems', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _openSettings(tester, '账户管理');

    // It is a pushed sub-page, not a sheet: this app draws its own bar rather
    // than Material's `AppBar`, and there is no drag handle anywhere.
    expect(find.byType(ShuAppBar), findsOneWidget);
    expect(find.text('账户管理'), findsWidgets);
    expect(find.byType(BottomSheet), findsNothing);

    // Two sections, each opened by a small caption.
    expect(find.text('上海大学校园账户'), findsOneWidget);
    expect(find.text('上海大学 OAuth 系统'), findsOneWidget);

    // One account row, signed out. Its right-hand side is reserved for the
    // progress spinner only: 已登录 was a second way of saying what the account
    // block's own lines already say, so 未登录 appears exactly once.
    expect(find.text('未登录'), findsOneWidget);

    // The logout row is gone — signing out is now what tapping the account
    // row does while signed in.
    expect(find.text('退出上海大学校园账户'), findsNothing);

    // Every registered system gets a row, academic first: it is the one that
    // answers "who am I", so it should report before the tunnel does.
    for (final name in <String>['教务系统', 'aTrust 隧道', 'OTP 令牌']) {
      expect(
        find.descendant(of: find.byType(ListTile), matching: find.text(name)),
        findsOneWidget,
        reason: '$name 应该有且只有一条凭据行',
      );
    }

    // Statuses sit right-aligned on a shared column and the icons keep the
    // theme colour — a coloured icon meant two things at once.
    //
    // Four `未连接` in total are in the tree, one of which is the connect
    // page's own button — but that page is offstage while this one is shown,
    // and finders skip offstage widgets.
    expect(find.text('未连接'), findsNWidgets(3));
    expect(
      find.descendant(of: find.byType(ListTile), matching: find.text('已连接')),
      findsNothing,
    );

    // Endpoints are not part of the account page — that was diagnostic noise.
    expect(find.textContaining('shu.edu.cn/'), findsNothing);

    // No WebVPN section — that system is out of scope.
    expect(find.textContaining('WebVPN'), findsNothing);

    // Two captions. Gaps between rows carry the grouping now, not a divider.
    expect(find.byType(SectionHeader), findsNWidgets(2));
  });

  testWidgets('the academic system leads the exchange and the page', (
    tester,
  ) async {
    // The list order *is* the exchange order, and the page follows it, so
    // jwxt — the system that answers "who am I" — comes first.
    expect(
      ShuOAuthTargets.all.map((target) => target.kind.id).toList(),
      <String>['jwxt', 'atrust', 'otp'],
    );
    expect(
      ShuOAuthTargets.visible.map((target) => target.kind.id).toList(),
      <String>['jwxt', 'atrust', 'otp'],
    );
    // Everything registered must be reachable from the page, otherwise a
    // system could end up exchanged yet invisible.
    for (final target in ShuOAuthTargets.all) {
      expect(
        ShuOAuthTargets.visible.contains(target),
        isTrue,
        reason: '${target.kind.id} 交换了但在页面上看不到',
      );
    }
  });

  testWidgets('the account page has a two-step sign-in flow', (tester) async {
    await _pumpApp(tester);
    await _openSettings(tester, '账户管理');

    // Tapping anywhere on the signed-out account row swaps the page body for
    // the login form.
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    expect(find.text('用户名/学号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('使用上海大学统一认证系统'), findsOneWidget);

    // The AppBar keeps the page name while the form supplies its own heading,
    // exactly like ShuYo's NativeLoginPage.
    expect(find.text('账户管理'), findsOneWidget);
    expect(find.text('登录校园账户'), findsOneWidget);

    // 企业微信 is offered as an alternative sign-in path, and the submit button
    // lives inside the form (not in a separate bottom bar).
    expect(find.text('使用企业微信登录'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    // Back returns to the overview.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('继续'), findsNothing);
    expect(find.text('用户名/学号'), findsNothing);
  });
}
