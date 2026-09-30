// Smoke tests for the app shell.
//
// They never touch the VPN or the network: the native library is only loaded
// when the orb is pressed with a complete draft, and the account page starts
// signed out, so no request is ever issued.

import 'package:flutter/material.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/app/app.dart';
import 'package:shuvpn/app/theme.dart';
import 'package:shuvpn/core/auth/auth_constants.dart';
import 'package:shuvpn/core/connection/connection_controller.dart';
import 'package:shuvpn/core/connection/protocol.dart';
import 'package:shuvpn/core/logging/shu_log.dart';
import 'package:shuvpn/core/settings/settings_store.dart';
import 'package:shuvpn/features/connect/connect_page.dart';
import 'package:shuvpn/features/settings/connection_settings_page.dart';
import 'package:shuvpn/features/settings/log_page.dart';
import 'package:shuvpn/features/settings/protocol_settings_page.dart';
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
  // 首启门默认是关着的（全新安装要看到引导），而这一整个文件测的是引导
  // **之后**的界面。模拟一位已经走完引导的用户，比在每个用例里绕过重定向
  // 干净：这层判断正好也是引导唯一的长期痕迹。
  settings.welcomeCompleted = true;
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

/// 抽屉里那一格协议现在能不能按。
///
/// 读的是它身上那个水波纹响应器 —— 手写的按钮没有 `SegmentedButton.enabled`
/// 那样的字段可查，而「按不动」这件事的**唯一**实现点就在那里（`onTap` 为
/// null 时 `InkResponse` 连手势都不接）。
///
/// 不能只用「点下去没反应」当判据：`ConnectionController.selectProtocol`
/// 自己也会把设置里没开的协议挡回去，所以那条断言在界面层放宽之后照样会
/// 通过 —— 它查的是控制器的纪律，不是这一排的执行。
bool _protocolButtonAcceptsTap(WidgetTester tester, ShuProtocol protocol) {
  final ink = tester.widget<ShuIndicatorInkResponse>(
    find.descendant(
      of: find.byKey(ConnectPage.protocolButtonKey(protocol)),
      matching: find.byType(ShuIndicatorInkResponse),
    ),
  );
  return ink.onTap != null;
}

/// 抽屉此刻露出来的高度（从把手顶上量到底边）。
double _drawerHeight(WidgetTester tester) =>
    tester.getRect(find.byKey(ConnectPage.scrimKey)).bottom -
    tester.getTopLeft(find.byKey(ConnectPage.grabberKey)).dy;

/// 抽屉里那一列内容**需要**多少高度。
///
/// 这是「拉开」那一档应当停的地方 —— 抽屉的高度是量出来的，不是写死的，
/// 所以测试也必须自己量一遍再比，而不是抄一个常量。`contentKey` 挂在内容
/// 那一列上（`SingleChildScrollView` 的孩子），所以 `getSize` 拿到的是它的
/// 自然高度；底部那 16 是那一列的 `padding`，也算在抽屉要露出来的高度里。
double _drawerContentHeight(WidgetTester tester) =>
    tester.getSize(find.byKey(ConnectPage.contentKey)).height + ShuSpacing.page;

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

/// 一个可以摆布的控制器替身。
///
/// `ConnectionController` 的状态只有真跑一趟原生隧道才会变，而这一整个文件
/// 不碰网络 —— 所以这里把连接页**读到**的那几个 getter 换成测试要的答案，
/// 其余（`draft` / `selectProtocol` / `hasEnabledProtocol` / 两个代理地址）
/// 留着基类的真实实现。基类里没有一个 getter 是 `final`，覆盖得到的。
///
/// [switchTo] 是「真机上会自己发生的那件事」的手动版：`ConnectionController`
/// 自己靠私有的 `_state` 与 `notifyListeners()` 做这件事，测试没有那条路。
class _FakeConnectionController extends ConnectionController {
  _FakeConnectionController(
    super.settings, {
    this.vpnRunning = false,
    this.tunnelUp = false,
  });

  /// 「系统 VPN 接口建起来了没有」—— 它同时是那一行的状态词与它出不出
  /// 现的半个条件。
  @override
  final bool vpnRunning;

  /// 「隧道在跑」—— 四个设置页的运行期锁定读的是它。
  ///
  /// 基类那一份是 `_dialer != null`（私有字段，测试摆不动），所以只能在这
  /// 儿换掉：没有它，「运行期不可改」这一整类断言在测试里一行都跑不到。
  @override
  final bool tunnelUp;

  SangforConnectionState _state = SangforConnectionState.disconnected;

  @override
  SangforConnectionState get state => _state;

  @override
  String? get virtualAddress =>
      _state == SangforConnectionState.connected ? '10.95.178.77' : null;

  void switchTo(SangforConnectionState value) {
    _state = value;
    notifyListeners();
  }

  /// 只通知、不改任何东西 —— 真机上每秒一次的速率刷新走的就是这条路
  /// （`ConnectionController._tickStats` 里的 `notifyListeners()`）。
  ///
  /// 它同时是「无关的重建」的最小模型：状态一样、内容一样，只有一次
  /// 通知。
  void tick() => notifyListeners();
}

/// 单独搭一页连接页 —— 真机视口 + 一个摆好的替身控制器。
///
/// 不走 `ShuVpnApp`：路由那一层与这一页无关，而这里要换掉的是 provider
/// 里的控制器。
///
/// `open` 决定搭好之后要不要把那抽屉拉开：多数用例要的是拉开的那一态，
/// 而「未拉开时它有多高」本身也要先量一次基线的用例就不该拉。
Future<void> _pumpDrawer(
  WidgetTester tester, {
  required SettingsStore settings,
  required ConnectionController controller,
  bool open = true,
}) async {
  // 真手机的视口（1200×2670 @3.25）。抽屉那一列内容的实际高度与抽屉上限
  // 都是**像素**，只有拿真机尺寸才撞得出「最后一行被切掉」这种问题。
  tester.view.physicalSize = const Size(1200, 2670);
  tester.view.devicePixelRatio = 3.25;
  tester.view.padding = const FakeViewPadding(top: 78, bottom: 78);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsStore>.value(value: settings),
        ChangeNotifierProvider<ConnectionController>.value(value: controller),
      ],
      child: MaterialApp(
        theme: buildShuTheme(Brightness.light),
        home: const ConnectPage(),
      ),
    ),
  );
  await tester.pump();

  if (!open) return;
  await tester.tap(find.byKey(ConnectPage.grabberKey));
  await tester.pumpAndSettle();
}

/// 单独搭一个二级设置页 —— 手机视口 + 一个摆好的控制器替身。
///
/// 不走 `ShuVpnApp`：那一条会自己造一个真控制器，而它的 `tunnelUp` 是
/// `_dialer != null`，测试里永远是假 —— 而这一组用例要的正是「隧道在跑时
/// 的那一页」。
Future<void> _pumpSettingsSubPage(
  WidgetTester tester, {
  required Widget page,
  required SettingsStore settings,
  required ConnectionController controller,
}) async {
  tester.view.physicalSize = const Size(720, 3600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsStore>.value(value: settings),
        ChangeNotifierProvider<ConnectionController>.value(value: controller),
      ],
      child: MaterialApp(theme: buildShuTheme(Brightness.light), home: page),
    ),
  );
  await tester.pump();
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

    // 协议是一排按钮：三段并排，每段带自己的图标与自己的名字。
    //
    // 断言限定在**那一个按钮**里（`protocolButtonKey`）：抽屉里还有第二处
    // 会出现协议图标的地方 —— 上面那一行状态行的左圆。不限定范围的话
    // `find.byIcon(aTrust 的图标)` 会数出两个。
    expect(find.text('协议'), findsOneWidget);
    for (final protocol in ShuProtocol.values) {
      final button = find.byKey(ConnectPage.protocolButtonKey(protocol));
      expect(button, findsOneWidget, reason: '${protocol.label} 应该有一格');
      expect(
        find.descendant(of: button, matching: find.byIcon(protocol.icon)),
        findsOneWidget,
        reason: '${protocol.label} 应该带自己的 icon',
      );
      expect(
        find.descendant(of: button, matching: find.text(protocol.label)),
        findsOneWidget,
      );
    }

    // 三格**平分**一条横条，而不是各占自己内容那么宽 —— 那样三格会宽窄
    // 不一，看起来像三个不相干的控件。
    final widths = <double>[
      for (final protocol in ShuProtocol.values)
        tester
            .getSize(find.byKey(ConnectPage.protocolButtonKey(protocol)))
            .width,
    ];
    expect(widths[0], closeTo(widths[1], 0.5));
    expect(widths[1], closeTo(widths[2], 0.5));

    // 设置里只有 aTrust 是开的：只有它接得住点击。另外两条仍然占一格，
    // 但按不动（`isProtocolEnabled` 对没有实现的协议一律返回 false）。
    expect(_protocolButtonAcceptsTap(tester, ShuProtocol.atrust), isTrue);
    expect(
      _protocolButtonAcceptsTap(tester, ShuProtocol.easyConnect),
      isFalse,
      reason: '设置里没开的协议该按不动',
    );
    expect(
      _protocolButtonAcceptsTap(tester, ShuProtocol.openVpn),
      isFalse,
      reason: '设置里没开的协议该按不动',
    );

    // 而且真的按不动：当前选择由状态行那一行的标题说出来（未连接时它就是
    // 协议名）。
    expect(
      find.descendant(
        of: find.byKey(ConnectPage.statusRowKey),
        matching: find.text('aTrust'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(ConnectPage.protocolButtonKey(ShuProtocol.easyConnect)),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(ConnectPage.statusRowKey),
        matching: find.text('aTrust'),
      ),
      findsOneWidget,
      reason: '设置里没开的协议点不动，当前选择不该变',
    );

    // 开着的 aTrust 点它自己也不该有任何变化 —— 它已经是选中的那个。
    await tester.tap(
      find.byKey(ConnectPage.protocolButtonKey(ShuProtocol.atrust)),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(ConnectPage.statusRowKey),
        matching: find.text('aTrust'),
      ),
      findsOneWidget,
    );

    // 「连接方式」**只在连上之后出现**：它是连接的结果，不是选择。断着的
    // 时候一条通道都没在跑，三行「已关闭」只是噪声。
    expect(find.text('连接方式'), findsNothing);
    expect(find.text('HTTP 代理'), findsNothing);
    expect(find.text('SOCKS5 代理'), findsNothing);
    expect(find.text('Android VPN 服务'), findsNothing);

    // 上面那一行已经说过的不再各占一行：服务器地址是那一行的副标题，
    // 当前走的哪条协议由那一排按钮的选中医当场回答了。
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

    // 往上走了不少，就不是「抖了一下」而是真的换了一档。
    //
    // 这里**不**断言「走了 200 以上」：拉开那一档现在就是内容的真实高度
    // （未连接时不到 200 像素），所以上移量本来就该是那么多 —— 拿一个
    // 比它大的数字当门槛，等于要求抽屉比内容还高。
    expect(_drawerRowTop(tester), lessThan(collapsed - 60));

    // 而且它甩到的正是「拉开」那一档：抽屉露出来的高度与内容需要的高度一致。
    expect(_drawerHeight(tester), closeTo(_drawerContentHeight(tester), 1));
  });

  testWidgets('the drawer opens to exactly the height its content needs', (
    tester,
  ) async {
    await _pumpPhone(tester);
    // 遮罩铺满整层、抽屉压在它上面，所以「遮罩底 − 抓手顶」量到的正是抽屉
    // 露出来的那一档高度 —— 未拉开时它等于 `_ConnectionDrawer.peekHeight`。
    final earlyPeek = _drawerHeight(tester);
    await tester.pumpAndSettle();
    final settledPeek = _drawerHeight(tester);
    expect(settledPeek, closeTo(earlyPeek, 1), reason: '吸附落地不该让抽屉跳一下');
    expect(
      settledPeek,
      inInclusiveRange(48, 160),
      reason: '未拉开那一档只放得下把手与状态行，不该长到把大圆顶走',
    );

    await tester.tap(find.byKey(ConnectPage.grabberKey));
    await tester.pumpAndSettle();

    // 拉开那一档的高度就是内容的真实高度 —— 不多也不少。
    //
    // 这条断言是这一整个改动的**唯一的证据**：换成写死一个数（曾经是 500，
    // 后来 420），这里立刻会红 —— 内容矮时抽屉会多出一片空白。
    expect(
      _drawerHeight(tester),
      closeTo(_drawerContentHeight(tester), 1),
      reason: '拉开那一档应当刚好装下内容，既不多也少不了',
    );
  });

  testWidgets('connection methods appear only once the tunnel is up', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await SettingsStore.load();
    // 保护出厂值：三条通道里只有系统 VPN 出厂是开的（安卓上），
    // 那一条恰好是这里要验的「真正在跑的那条」。
    settings.vpnEnabled = true;
    expect(settings.httpProxyEnabled, isFalse, reason: 'HTTP 代理出厂关闭');
    expect(settings.socksProxyEnabled, isFalse, reason: 'SOCKS5 代理出厂关闭');

    // 先摆成「已连接」再搭页 —— 抽屉必须在**内容已经长成最终那个样子**之后
    // 才拉开：开着的时候容量变一下，它就会被兜底收回去（下一条用例）。
    final controller = _FakeConnectionController(settings, vpnRunning: true)
      ..switchTo(SangforConnectionState.connected);
    await _pumpDrawer(tester, settings: settings, controller: controller);

    // 连上了：虚拟地址取代了协议名那一行，连接方式整组这才出现。
    expect(find.text('10.95.178.77'), findsOneWidget);
    expect(find.text('连接方式'), findsOneWidget);

    // 只列**设置里开着**的那一条。没开的两条不是画成灰的，是根本不画 ——
    // 那两条路本来就不会走。
    expect(find.text('Android VPN 服务'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.text('HTTP 代理'), findsNothing);
    expect(find.text('SOCKS5 代理'), findsNothing);
    expect(find.byIcon(Icons.content_copy), findsNothing);

    // 协议那一排在这个状态下按不动 —— 换协议只改 `draft`，而隧道已经
    // 按旧的 `state` 跑着了，改了就分叉。**三格全锁**，包括那一条开着的。
    expect(find.text('连接期间不可改'), findsOneWidget);
    for (final protocol in ShuProtocol.values) {
      expect(
        _protocolButtonAcceptsTap(tester, protocol),
        isFalse,
        reason: '连上之后 ${protocol.label} 不该还能换',
      );
    }

    // 而且拉开那一档仍然刚好装下内容 —— 连接方式让内容长了一截，抽屉
    // 应该跟着长，而不是把最后一行切掉。
    expect(_drawerHeight(tester), closeTo(_drawerContentHeight(tester), 1));
  });

  testWidgets(
    'every open channel gets a row, and its address, once connected',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = await SettingsStore.load();
      // 三路全开 —— 内容最长的那一态。
      settings.vpnEnabled = true;
      settings.httpProxyEnabled = true;
      settings.socksProxyEnabled = true;

      await _pumpDrawer(
        tester,
        settings: settings,
        controller: _FakeConnectionController(settings, vpnRunning: true)
          ..switchTo(SangforConnectionState.connected),
      );

      expect(find.text('连接方式'), findsOneWidget);
      for (final row in <String>['HTTP 代理', 'SOCKS5 代理', 'Android VPN 服务']) {
        expect(find.text(row), findsOneWidget, reason: '$row 开着就应该有一行');
      }

      // 两个代理地址是**设置里那个**（出厂回环 + 两个错开的端口），各带一颗
      // 复制按钮 —— 这两行存在的理由就是把地址抄走。
      expect(
        find.text('127.0.0.1:${SettingsStore.defaultHttpPort}'),
        findsOneWidget,
      );
      expect(
        find.text('127.0.0.1:${SettingsStore.defaultSocksPort}'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.content_copy), findsNWidgets(2));

      // 内容最多的一态下，抽屉仍然刚好装下它 —— 三行通道全在抽屉里，
      // 而且抽屉没有高到留出一片空白。
      expect(_drawerHeight(tester), closeTo(_drawerContentHeight(tester), 1));
      final drawerBottom = tester
          .getRect(find.byKey(ConnectPage.scrimKey))
          .bottom;
      expect(
        tester.getBottomLeft(find.text('Android VPN 服务')).dy,
        lessThanOrEqualTo(drawerBottom),
        reason: '最后一行不能掉出抽屉外',
      );
    },
  );

  testWidgets('an open drawer falls back shut when its size changes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await SettingsStore.load();
    settings.vpnEnabled = true;
    // 从「未连接」开始 —— 抽屉的内容只有协议那一段，容量是最小的那一档。
    final controller = _FakeConnectionController(settings);

    // 先量下未拉开那一档到底多高，当基线。
    await _pumpDrawer(
      tester,
      settings: settings,
      controller: controller,
      open: false,
    );
    final collapsed = _drawerHeight(tester);

    await tester.tap(find.byKey(ConnectPage.grabberKey));
    await tester.pumpAndSettle();
    expect(
      _drawerHeight(tester),
      greaterThan(collapsed + 40),
      reason: '先确认它真的拉开了',
    );

    // 隧道连上：抽屉里多出「连接方式」那几行 —— 它的**容量**变了。
    controller.switchTo(SangforConnectionState.connected);
    await tester.pumpAndSettle();

    expect(find.text('连接方式'), findsOneWidget, reason: '内容确实变了');
    expect(
      _drawerHeight(tester),
      closeTo(collapsed, 1),
      reason: '容量在它开着的时候变了，就该收回去到未拉开那一档',
    );
    expect(_scrimAlpha(tester), 0, reason: '收回去了背景也该亮回来');

    // 再拉一次是好的 —— 那时候量到的已经是新的容量。
    await tester.tap(find.byKey(ConnectPage.grabberKey));
    await tester.pumpAndSettle();
    expect(_drawerHeight(tester), closeTo(_drawerContentHeight(tester), 1));

    // 容量**没有**变的时候不该收回去。抽屉里正在读的东西被一次无关的重建
    // 赶走，是「兜底」最容易滑向的那种烦人 —— 而这一页上每秒钟就有一次
    // 这样的重建（速率刷新会 `notifyListeners()`），所以判据必须是「尺寸
    // 变了」，而不是「这一帧重建了」。
    controller.tick();
    await tester.pumpAndSettle();
    expect(
      _drawerHeight(tester),
      closeTo(_drawerContentHeight(tester), 1),
      reason: '尺寸没变就不该动它',
    );

    // 反方向也一样。断开让内容变短：不收回去的话，控制器会把当前位置直接
    // 夹到新的（更小的）上限，抽屉当着用户的面往下跳一格。
    controller.switchTo(SangforConnectionState.disconnected);
    await tester.pumpAndSettle();
    expect(find.text('连接方式'), findsNothing, reason: '内容确实变短了');
    expect(_drawerHeight(tester), closeTo(collapsed, 1), reason: '容量变小同样要收回去');
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

  testWidgets('the four runtime-locked pages freeze while the tunnel is up', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await SettingsStore.load();
    final pages = <String, Widget>{
      'aTrust 协议': const ShuATrustSettingsPage(),
      'EasyConnect 协议': const ShuEasyConnectSettingsPage(),
      'OpenVPN 协议': const ShuOpenVpnSettingsPage(),
      '网络连接': const ShuConnectionSettingsPage(),
    };

    // ① 隧道没跑：四个页面上都没有这一条 —— 它描述的是「此刻不能改」，
    // 不是一个常驻说明。
    for (final entry in pages.entries) {
      await _pumpSettingsSubPage(
        tester,
        page: entry.value,
        settings: settings,
        controller: _FakeConnectionController(settings),
      );
      expect(
        find.byType(ShuNoticeBar),
        findsNothing,
        reason: '隧道没跑时「${entry.key}」不该有运行期提示',
      );
    }

    // ② 隧道在跑：四个页面各挂一条，且每一项都点不动。
    for (final entry in pages.entries) {
      await _pumpSettingsSubPage(
        tester,
        page: entry.value,
        settings: settings,
        controller: _FakeConnectionController(settings, tunnelUp: true),
      );
      expect(
        find.text(shuSettingsLockedNotice),
        findsOneWidget,
        reason: '「${entry.key}」在隧道跑着的时候要说清楚为什么点不动',
      );
      // 它是一条**通栏**提示：挂在 `Column` 里时若忘了撑开宽度，会缩成
      // 「图标 + 这一句话」那么宽的一小条贴在左边。量的是里面那块 `Material`
      // 本身（外面的 `Padding` 永远是整屏宽，量它看不出问题）。
      expect(
        tester
            .getSize(
              find.descendant(
                of: find.byType(ShuNoticeBar),
                matching: find.byType(Material),
              ),
            )
            .width,
        moreOrLessEquals(360 - ShuSpacing.page * 2, epsilon: 1),
        reason: '「${entry.key}」上的提示条该与下面的列表同宽',
      );
      // 底色取自 MD3 的 `inverseSurface` 角色，不是写死的深色：深色主题下
      // 它会自己反成浅色。写死颜色的话这一条会红。
      final scheme = Theme.of(tester.element(find.byType(ShuNoticeBar)))
          .colorScheme;
      expect(
        tester
            .widget<Material>(
              find.descendant(
                of: find.byType(ShuNoticeBar),
                matching: find.byType(Material),
              ),
            )
            .color,
        scheme.inverseSurface,
      );
      // 判据是控件自己接不接手势，不是「点下去没反应」：`SettingsStore`
      // 的 setter 与 `ConnectionController` 都不会挡写，界面层放宽之后
      // 那样断言照样会通过。
      //
      // `SwitchListTile` 内部也是一个 `ListTile`，所以这一个循环同时管住了
      // 开关行与普通行。
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
        expect(tile.onTap, isNull, reason: '「${entry.key}」上的行不该能点');
      }
      for (final row in tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      )) {
        expect(row.onChanged, isNull, reason: '「${entry.key}」上的开关不该能拨');
      }
    }
  });

  testWidgets('a sealed switch shows it is sealed, even when it is on', (
    tester,
  ) async {
    // 运行期锁定会封住**开着**的开关（「启用 VPN 服务」出厂就是开的）。
    // 主题里若只判 `selected`，这一颗会拿到 accent 色 —— 一颗看着完全能拨
    // 的滑块。这一条锁的是「封住的开关不许用可用的那套颜色」。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await SettingsStore.load();
    settings.vpnEnabled = true;
    await _pumpSettingsSubPage(
      tester,
      page: const ShuConnectionSettingsPage(),
      settings: settings,
      controller: _FakeConnectionController(settings, tunnelUp: true),
    );

    final theme = Theme.of(tester.element(find.byType(SwitchListTile).first));
    final colors = theme.extension<ShuYoColors>()!;
    final track = theme.switchTheme.trackColor!.resolve(const <WidgetState>{
      WidgetState.disabled,
      WidgetState.selected,
    });
    expect(track, isNot(colors.accent), reason: '封住的开关不该画成可用的颜色');
    expect(track, colors.textMuted, reason: '封住但开着，要能与封住且关着区分');

    // 顺带把「它确实是开着的」也钉住：否则这一条可能只是碰上了出厂关闭。
    final vpnSwitch = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .last;
    expect(vpnSwitch.value, isTrue);
    expect(vpnSwitch.onChanged, isNull);
  });

  testWidgets('the experimental page warns first, then offers one switch', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _openSettings(tester, '实验性选项');

    // 警告排在所有开关前面：这一页上的东西走不通时是真的上不了网，
    // 而不是“可能稍微卡一点”。断言整句 —— 它不能被改淡。
    expect(find.byType(ShuSettingsWarning), findsOneWidget);
    expect(find.text('下列实验性选项行为不稳定，请确认你清楚自己在做什么。'), findsOneWidget);

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

    // 页内解释性小字已清空：只剩一行警告。
    expect(find.byType(ShuSettingsNote), findsNothing);

    await _back(tester);
  });

  testWidgets('the experimental page can send you back through onboarding', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _openSettings(tester, '实验性选项');

    // 入口不是开关：整页仍然只有一个开关。
    expect(find.text('新用户引导'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);

    await tester.tap(_settingsRow('新用户引导'));
    await tester.pumpAndSettle();
    // 先问一次：引导走完之前回不到主页。
    expect(find.text('重新开始引导'), findsOneWidget);
    await tester.tap(find.text('重新开始'));
    await tester.pumpAndSettle();

    // 落到引导页本身就证明完成标记被清掉了：标记还在的话，这一次 `go`
    // 会被首启门改写回主页。
    expect(find.text('欢迎使用 ShuVPN'), findsOneWidget);
    // 引导页盖住了 dock —— 门是关着的。
    expect(find.byType(FloatingDock), findsNothing);
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
    for (final name in <String>['教务系统', 'aTrust 网关', 'OTP 令牌']) {
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
    // The host alone is a caption now (every row carries one); what stays out
    // is the path half of an endpoint, which is what made that list useful
    // only to whoever was debugging.
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
