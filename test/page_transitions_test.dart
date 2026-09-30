// 二级页的转场。
//
// 这一层守的是一件**静默失效过**的事：主题里装着 `pageTransitionsTheme`、
// builder 也对，但 go_router 把每条路由都包成了它自己的 `NoTransitionPage`，
// 于是主题一次都没被读过 —— 页面直接出现在原位，没有任何动画，而且从代码上
// 完全看不出哪里不对（主题对、路由对、页面也对）。
//
// 所以这里**不测「主题里配了什么」**（那会跟着代码一起错），只测屏幕上的
// 位移：转场途中，被推进来的那一页必须还在屏幕右边。
//
// 为什么能做到：`SlideTransition` 底下是 `RenderFractionalTranslation`，它
// 改的是绘制偏移，`tester.getTopLeft` 走 `localToGlobal` 会把它算进来。
//
// 同一个文件里还有第二种「有没有动画」：**页内**换页（账户管理里概览 ⇄ 登录
// 表单，见 `ShuSharedAxisXSwitcher`）。它不需要路由，却同样会静默失效 ——
// `_signingIn ? 表单 : 概览` 这种写法完全编译得过，只是中间什么都没有。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/app/app.dart';
import 'package:shuvpn/core/logging/shu_log.dart';
import 'package:shuvpn/core/settings/settings_store.dart';
import 'package:shuvpn/features/onboarding/welcome_page.dart';
import 'package:shuvpn/shell/floating_dock.dart';
import 'package:shuvpn/widgets/shu_surfaces.dart';

/// 与 `widget_test.dart` 的视口一致：一台高瘦的手机（逻辑 360×1800）。
void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(720, 3600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// 引导**之后**的界面：seed `welcomeCompleted`，落在带 dock 的主页上。
Future<void> _pumpApp(WidgetTester tester) async {
  _viewport(tester);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  settings.welcomeCompleted = true;
  await tester.pumpWidget(ShuVpnApp(settings: settings));
  await tester.pumpAndSettle();
}

/// 全新安装：不 seed `welcomeCompleted`，第一屏就是引导页。
Future<void> _pumpFreshInstall(WidgetTester tester) async {
  _viewport(tester);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(ShuVpnApp(settings: await SettingsStore.load()));
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(FloatingDock), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// 某个文字当前的横坐标。
double _leftOf(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dx;

/// 点下之后只走一小段：这时转场应该走到一半。
///
/// 60ms 是 `MaterialPageRoute` 那 300ms 的五分之一，`easeOutCubic` 下大约
/// 走到三成 —— 足够离开原位、也足够没到终点，两个方向都能断言。
Future<void> _pumpMidTransition(
  WidgetTester tester, {
  bool fromTap = true,
}) async {
  if (fromTap) await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  setUp(ShuLog.instance.clear);

  testWidgets('二级页从右侧滑入，而不是直接出现在原位', (tester) async {
    await _pumpApp(tester);
    await _openTab(tester, '设置');

    await tester.tap(
      find.descendant(of: find.byType(ListTile), matching: find.text('账户管理')),
    );
    await _pumpMidTransition(tester);

    final midway = _leftOf(tester, '上海大学校园账户');
    // 屏幕宽 360（720 物理 ÷ dpr 2）。中途它必须还在很右边 —— 这一条就是
    // 「有没有动画」的全部判据。
    expect(midway, greaterThan(60));

    await tester.pumpAndSettle();
    final settled = _leftOf(tester, '上海大学校园账户');
    // 停在原位：`SectionHeader` 的 4 + 列表的 16。
    expect(settled, lessThan(midway));
    expect(settled, lessThan(60));
  });

  testWidgets('返回时沿原路收回，而不是瞬间消失', (tester) async {
    await _pumpApp(tester);
    await _openTab(tester, '设置');
    await tester.tap(
      find.descendant(of: find.byType(ListTile), matching: find.text('账户管理')),
    );
    await tester.pumpAndSettle();
    expect(find.text('上海大学校园账户'), findsOneWidget);

    // 这一页的返回键（tooltip 是中文的「返回」，`tester.pageBack()` 认不出来）。
    await tester.tap(find.byTooltip('返回'));
    await _pumpMidTransition(tester);

    expect(_leftOf(tester, '上海大学校园账户'), greaterThan(60));

    await tester.pumpAndSettle();
    expect(find.text('上海大学校园账户'), findsNothing);
  });

  testWidgets('顶栏的通知入口同样从右侧推上来', (tester) async {
    await _pumpApp(tester);

    await tester.tap(find.byTooltip('通知'));
    await _pumpMidTransition(tester);

    // ⚠️ 量的是**卡片**而不是卡片里的文字：`EmptyState` 的 `Column` 是居中
    // 对齐的，文字静止时也在 x≈140，拿它当锚点的话这条断言在「完全没动画」
    // 的情况下也会过。卡片的左边界静止时就是页边距 16。
    expect(tester.getTopLeft(find.byType(EmptyState)).dx, greaterThan(60));

    await tester.pumpAndSettle();
    expect(find.text('暂无通知'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(EmptyState)).dx, lessThan(60));
  });

  testWidgets('账户管理的「概览 → 登录表单」也是滑过来的', (tester) async {
    await _pumpApp(tester);
    await _openTab(tester, '设置');
    await tester.tap(
      find.descendant(of: find.byType(ListTile), matching: find.text('账户管理')),
    );
    await tester.pumpAndSettle();

    // 静止时它在哪儿 —— 下面拿它当锚点，而不是写死一个数：这一行的左边距
    // 跟着 `ListTile` 的 leading 走，改一次版式就会变。
    final resting = _leftOf(tester, '未登录');

    // 进登录。以前这里是两个子树一帧之内对调，中间什么都没有。
    await tester.tap(find.byType(ListTile).first);
    await _pumpMidTransition(tester);

    // 新那一块还在**右半边**（屏幕宽 360，中途它离原位还有一百多像素）——
    // 阈值取半屏而不是某个小数：不动的话它就停在原位 76，那是左边。
    final midway = _leftOf(tester, '用户名/学号');
    expect(midway, greaterThan(180));
    // ……旧那一块已经在往左让位。两件事同时发生才是 shared axis —— 只有新页
    // 在动的话，看起来是「一张纸盖上来」。
    expect(_leftOf(tester, '未登录'), lessThan(resting - 8));

    await tester.pumpAndSettle();
    // 停进原位：比中途往左挪了一整段（不是「拍」一下到了一帧之外的某个地方）。
    expect(_leftOf(tester, '用户名/学号'), lessThan(midway - 100));
    // 让完之后那一块连树都不在了 —— 被藏起来的那一份不能被 finder 找到，
    // 否则「登录表单已经退场」这类断言会被它骗过去。
    expect(find.text('未登录'), findsNothing);
  });

  testWidgets('引导页的「说明 → 登录表单」也是滑过来的', (tester) async {
    await _pumpFreshInstall(tester);

    // 走到第 2 页。授权那一步在测试环境里没有内容可做（非 Android 上
    // 权限清单是空的，按钮一上来就可点）。
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('登录校园账户'), findsOneWidget);

    // 静止时按钮上的字在哪儿 —— 下面拿它当「三页那一块」的锚点（当场量，
    // 不写死：按钮整宽，字是居中的，位置跟着版式走）。
    final resting = _leftOf(tester, '去登录');

    await tester.tap(find.text('去登录'));
    await _pumpMidTransition(tester);

    // 表单还在**右半边**（屏幕宽 360）……
    final midway = _leftOf(tester, '用户名/学号');
    expect(midway, greaterThan(180));
    // ……三页那一块已经在往左让位。两件事同时发生才是 shared axis。
    expect(_leftOf(tester, '去登录'), lessThan(resting - 8));

    await tester.pumpAndSettle();
    expect(_leftOf(tester, '用户名/学号'), lessThan(midway - 100));
    // 让完之后三页那一块连 finder 都找不到（`Visibility` 退化成 `Offstage`）。
    expect(find.text('去登录'), findsNothing);
  });

  testWidgets('引导页是根导航器上的第一页 —— 它不该有推入动画', (tester) async {
    await _pumpFreshInstall(tester);
    // 再从第一帧看一遍：`_pumpFreshInstall` 已经 settle 过了，这里只重画。
    await tester.pump();

    // 直接就在原位。给它一个转场，开机第一屏会像「从右边推一张纸进来」，
    // 那读起来像回到了上一页，而不是启动。
    expect(_leftOf(tester, '欢迎使用 ShuVPN'), lessThan(60));
    expect(find.byType(ShuWelcomePage), findsOneWidget);
  });
}
