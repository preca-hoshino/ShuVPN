// 新用户引导（`/welcome`）与首启门。
//
// 这一层测的是三件事，每一件都对应一个「错了就没人发现」的地方：
//
//   1. **首启门**：全新安装的第一屏必须是引导，而不是带着 dock 的主页。
//      它靠路由的重定向实现，不是页面里的判断 —— 重定向写错了，深链接就会
//      从引导底下穿过去。
//   2. **翻页的门禁**：第 1 页（权限清单）上，底部按钮在清单全绿之前必须
//      是灰的。它是三页里唯一「有外部结论」的一步 —— 按钮放早了，用户就
//      带着一张没授权的设备走进登录页。
//   3. **登录复用**：第 2 页按下去之后出现的是账户管理那一套表单本身，
//      不是另写的一份。
//
// 第 1 页的真授权路径要弹出系统对话框，测不了；但授权那一层的接口
// （`ShuVpnPermission`）是可以换掉的，最后一组用例走的就是它。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/app/app.dart';
import 'package:shuvpn/app/router.dart';
import 'package:shuvpn/app/theme.dart';
import 'package:shuvpn/core/account/account_center.dart';
import 'package:shuvpn/core/connection/connection_controller.dart';
import 'package:shuvpn/core/connection/protocol.dart';
import 'package:shuvpn/core/connection/vpn_permission.dart';
import 'package:shuvpn/core/logging/shu_log.dart';
import 'package:shuvpn/core/settings/settings_store.dart';
import 'package:shuvpn/features/onboarding/welcome_page.dart';
import 'package:shuvpn/shell/floating_dock.dart';

/// 一台真手机的视口，与 `widget_test.dart` 的 `_pumpApp` 同一套数字。
Future<void> _viewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(720, 3600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// 整个应用，**不**写 `welcomeCompleted` —— 也就是全新安装的样子。
Future<void> _pumpFreshInstall(WidgetTester tester) async {
  await _viewport(tester);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  await tester.pumpWidget(ShuVpnApp(settings: settings));
  await tester.pumpAndSettle();
}

/// 替掉系统 VPN 授权那一层。
///
/// 缺了它整组用例都长不出来：测试跑在桌面宿主上 —— `Platform.isAndroid`
/// 是 false、`shuvpn/vpn` 这条 channel 也不在，授权状态永远落在「未授权」
/// 上，第 1 页只会是一张**空清单**。这个替身把 [isSupported] 报成 true，
/// 清单才真的出现；页面与 `ConnectionController` 两条路都不用知道。
class _FakeVpnPermission extends ShuVpnPermission {
  /// 系统现在的授权状态 —— 进页时查出来的就是它。
  bool prepared = false;

  /// 下一次 [request] 会不会答应。
  bool grants = false;

  /// 被弹了几次对话框。
  int requested = 0;

  @override
  bool get isSupported => true;

  @override
  Future<bool> isPrepared() async => prepared;

  @override
  Future<bool> request() async {
    requested++;
    // 真的系统也是这样：答应了就一直是答应着的，下一次查就是 true。
    if (grants) prepared = true;
    return prepared;
  }
}

/// 只把引导页拎出来跑，并替掉系统 VPN 授权那一层。
///
/// 为什么能这么测：引导页对外的依赖只有三个 provider，而「点了但没授权」
/// 这条路径里它们**一个都不会被真的用到**（除了 `ConnectionController`
/// 自己）—— 页面停在第 1 页，既不写设置也不跳转。
Future<void> _pumpStandalone(
  WidgetTester tester, {
  required _FakeVpnPermission vpn,
}) async {
  await _viewport(tester);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsStore>.value(value: settings),
        ChangeNotifierProvider<ConnectionController>(
          create: (_) => ConnectionController(
            settings,
            draft: ConnectionDraft(
              protocol: ShuProtocol.atrust,
              server: settings.server,
              loginDomain: settings.loginDomain,
            ),
            vpnPermission: vpn,
          ),
        ),
        ChangeNotifierProvider<AccountCenter>(
          create: (_) => createAccountCenter(preferences: settings.preferences),
        ),
      ],
      child: MaterialApp(
        theme: buildShuTheme(Brightness.light),
        home: const ShuWelcomePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// 底部那颗主按钮。置灰是拿它自己的 `onPressed` 判的，不是颜色 —— 颜色
/// 断言不到，而「点了没反应」才是这件事的真行为。
FilledButton _footerButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton));

void main() {
  setUp(ShuLog.instance.clear);

  test('副标题分平台：Android 列清单，别的平台说不用', () {
    expect(
      ShuWelcomePage.permissionSubtitle(isAndroid: true),
      '当前使用 Android 系统，需要申请以下权限',
    );
    expect(ShuWelcomePage.permissionSubtitle(isAndroid: false), '无需系统 VPN 授权');
  });

  group('首启门', () {
    testWidgets('全新安装的第一屏是引导，dock 还没有出现', (tester) async {
      await _pumpFreshInstall(tester);

      expect(find.text('欢迎使用 ShuVPN'), findsOneWidget);
      // 三页的按钮都要在，而底栏不能 —— 引导挡在主界面之前，这是它存在的
      // 全部意义。
      expect(find.byType(FloatingDock), findsNothing);
    });

    testWidgets('走完引导之前翻不进主页', (tester) async {
      await _pumpFreshInstall(tester);

      // 第 2 页的按钮只是进入登录，不会绕过最后一步把人放进主页。
      // 桌面上没有权限要申请（清单是空的），第 1 页的按钮直接就是可点的。
      await _tap(tester, '继续');
      await _tap(tester, '继续');
      await _tap(tester, '去登录');

      expect(find.byType(FloatingDock), findsNothing);
      // 落到的是账户管理那一套表单本身（`ShuLoginForm` 的第一屏）。
      expect(find.text('用户名/学号'), findsOneWidget);
      expect(find.text('密码'), findsOneWidget);
      expect(find.text('使用企业微信登录'), findsOneWidget);
    });
  });

  group('三页的顺序', () {
    testWidgets('欢迎 → 授权 → 登录，且每一步只有一个主题', (tester) async {
      await _pumpFreshInstall(tester);
      expect(find.text('欢迎使用 ShuVPN'), findsOneWidget);

      await _tap(tester, '继续');
      expect(find.text('无需系统 VPN 授权'), findsOneWidget);
      expect(find.text('欢迎使用 ShuVPN'), findsNothing);

      // 桌面上没有系统 VPN 可授权 —— 权限清单是空的，「全部申请到」因此
      // 一开始就成立，按钮一上来就可点。真机上是同一条代码路径，只是
      // 清单里多出一项、得先点它弹出系统对话框。
      await _tap(tester, '继续');
      expect(find.text('登录校园账户'), findsOneWidget);
      expect(find.text('无需系统 VPN 授权'), findsNothing);
    });

    testWidgets('返回键按原路退回上一页', (tester) async {
      await _pumpFreshInstall(tester);
      await _tap(tester, '继续');
      expect(find.text('无需系统 VPN 授权'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(find.text('欢迎使用 ShuVPN'), findsOneWidget);
      // 第一页没有上一页，所以返回键整个不画（槽位仍占着，标题不横跳）。
      expect(find.byTooltip('返回'), findsNothing);
    });

    testWidgets('登录页的返回键退回说明页，而不是退出引导', (tester) async {
      await _pumpFreshInstall(tester);
      await _tap(tester, '继续');
      await _tap(tester, '继续');
      await _tap(tester, '去登录');
      expect(find.text('用户名/学号'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      // 回到的是第 2 页的说明（标题 + 底部的「去登录」），不是主页。
      expect(find.text('登录校园账户'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(find.byType(FloatingDock), findsNothing);
    });

    testWidgets('登录页列将要连上的系统，承诺停在按钮上方', (tester) async {
      await _pumpFreshInstall(tester);
      await _tap(tester, '继续');
      await _tap(tester, '继续');

      // 三个系统逐条列出，每条带自己的域名。行是 `ShuSystemTile` —— 与
      // 账户管理那三行同一个组件，所以这里查得到的东西那边也一定查得到。
      for (final host in <String>[
        'jwxt.shu.edu.cn',
        'atrust.shu.edu.cn',
        'otp.shu.edu.cn',
      ]) {
        expect(
          find.descendant(of: find.byType(ListTile), matching: find.text(host)),
          findsOneWidget,
          reason: '$host 应该有且只有一条系统行',
        );
      }

      // 承诺那一行在按钮**上方**，而且是**贴着**按钮的那一格 ——
      // `_layout` 的 `pageFooter`，与它里面那段可滚动的正文分开。
      //
      // ⚠️ 只断言「y 在按钮上方」是没有分辨力的：正文里随便哪一行都在按钮
      // 上方。所以先拆开结构（它不在 `SingleChildScrollView` 里），再量它
      // 离按钮有多近（贴住时差值是底距 8 + 行高，放进正文末尾会变成几百）。
      final note = find.textContaining('不保存您的校园账户信息');
      expect(
        find.descendant(of: find.byType(SingleChildScrollView), matching: note),
        findsNothing,
      );
      final gap =
          tester.getTopLeft(find.text('去登录')).dy - tester.getTopLeft(note).dy;
      expect(gap, greaterThan(0));
      expect(gap, lessThan(120));
    });
  });

  group('VPN 授权这一步', () {
    testWidgets('清单里点一下就是申请，被拒就停在原地、按钮保持置灰', (tester) async {
      final vpn = _FakeVpnPermission();
      await _pumpStandalone(tester, vpn: vpn);

      await _tap(tester, '继续');
      expect(find.text('当前使用 Android 系统，需要申请以下权限'), findsOneWidget);
      expect(find.text('VPN 服务'), findsOneWidget);
      expect(find.text('可以随时撤销已授予权限'), findsOneWidget);
      // 状态词抄的是账号管理里那几行凭据 —— 「未授权」是它自己查出来的。
      expect(find.text('未授权'), findsOneWidget);

      // 一项都没申请到，按钮就是灰的。
      expect(_footerButton(tester).onPressed, isNull);
      await _tap(tester, '继续');
      expect(find.text('登录校园账户'), findsNothing);

      await _tap(tester, 'VPN 服务');
      expect(vpn.requested, 1);
      // 补救的办法留在页面上（不是 SnackBar —— 那玩意几秒后自己就走了，而
      // 用户此刻正卡在这一页）。
      expect(find.textContaining('可以再点一次这一项'), findsOneWidget);
      // 没有变成「已授权」，按钮仍然置灰。
      expect(find.text('已授权'), findsNothing);
      expect(_footerButton(tester).onPressed, isNull);

      // 再点一次会再问一次：拒绝不是终局。
      await _tap(tester, 'VPN 服务');
      expect(vpn.requested, 2);
    });

    testWidgets('进页先问一次系统：本来就授权过的设备不用再点', (tester) async {
      final vpn = _FakeVpnPermission()..prepared = true;
      await _pumpStandalone(tester, vpn: vpn);

      await _tap(tester, '继续');

      // 一次都没点过，状态却已经是「已授权」—— 这就是「状态存在控制器里、
      // 进页时问一次系统」与「页面自己记『我点过』」的区别。
      expect(find.text('已授权'), findsOneWidget);
      expect(find.text('未授权'), findsNothing);
      expect(_footerButton(tester).onPressed, isNotNull);
      expect(vpn.requested, 0);
    });

    testWidgets('全部拿到之后按钮才解禁，警示也一并清掉', (tester) async {
      final vpn = _FakeVpnPermission();
      await _pumpStandalone(tester, vpn: vpn);

      await _tap(tester, '继续');
      await _tap(tester, 'VPN 服务');
      expect(find.textContaining('可以再点一次这一项'), findsOneWidget);
      expect(_footerButton(tester).onPressed, isNull);

      vpn.grants = true;
      await _tap(tester, 'VPN 服务');

      expect(find.textContaining('可以再点一次这一项'), findsNothing);
      expect(find.text('已授权'), findsOneWidget);
      expect(_footerButton(tester).onPressed, isNotNull);

      // 这一下才翻得到登录页。
      await _tap(tester, '继续');
      expect(find.text('登录校园账户'), findsOneWidget);
    });
  });
}
