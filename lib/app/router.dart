import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/account/account_center.dart';
import '../core/settings/settings_store.dart';
import '../features/account/account_page.dart';
import '../features/connect/connect_page.dart';
import '../features/notifications/notifications_page.dart';
import '../features/onboarding/welcome_page.dart';
import '../features/services/services_page.dart';
import '../features/settings/about_page.dart';
import '../features/settings/appearance_settings_page.dart';
import '../features/settings/connection_settings_page.dart';
import '../features/settings/experimental_settings_page.dart';
import '../features/settings/log_page.dart';
import '../features/settings/protocol_settings_page.dart';
import '../features/settings/settings_page.dart';
import '../shell/dock_shell.dart';

/// 新用户引导所在的路径。
const String shuWelcomePath = '/welcome';

/// 主页 —— 连接页，也是引导做完之后落回的地方。
const String shuHomePath = '/connect';

/// 一条**被推上来**的路由：显式包一层 `flutter/material.dart` 的
/// [MaterialPage]。
///
/// ## 为什么必须显式给
///
/// go_router 在没有 `pageBuilder` 的时候会**猜**用什么页：`isMaterialApp`
/// 为真就用 `MaterialPage`，为假就用 `NoTransitionPage`。而它判的是
/// `package:material_ui` 里那一个 `MaterialApp` —— 本工程用的是
/// `package:flutter/material.dart` 的。这个 Flutter 版本里 material 正在被拆成
/// 独立包，SDK 里那份仍然在，两者是**两个互不相干的类**（`findAncestorWidgetOfExactType`
/// 比的是 exact runtime type）。
///
/// 于是猜的结果**永远是错的**：每条路由都被包成 `NoTransitionPage`，它的
/// `transitionsBuilder` 直接返回 child，主题里的 `pageTransitionsTheme`
/// 一次都不会被跑到 —— 表现出来就是「页面切换完全没有动画」，而且看不出是
/// 哪里没生效（主题里的 builder 确实对、确实被装上了）。
///
/// 这里给的 [MaterialPage] 是 `flutter/material.dart` 那一个，它建出的
/// `_PageBasedMaterialPageRoute` 会在 `buildTransitions` 里读**同一个**
/// `Theme.of(context).pageTransitionsTheme`，所以
/// [ShuSharedAxisXPageTransitionsBuilder] 才真的用得上。
///
/// ⚠️ 不要图省事把 `MaterialPage` 换成 `material_ui` 的：那一个会去找
/// `material_ui` 的 `Theme`，而本应用的 `Theme` 是 SDK 那一份，`Theme.of`
/// 当场就找不到。两边必须是同一套。
///
/// ⚠️ dock 的三个根（`/services` `/connect` `/settings`）**不用**这个。
/// 它们在分支导航器里各自是唯一的页面（`isFirst`），出来就没有转场；
/// 而且切 tab 走的是 `IndexedStack` 换索引，本来也不该动。
GoRoute _subPage({
  required GlobalKey<NavigatorState> parentNavigatorKey,
  required String path,
  required Widget Function(BuildContext context, GoRouterState state) builder,
  List<RouteBase> routes = const <RouteBase>[],
}) => GoRoute(
  path: path,
  parentNavigatorKey: parentNavigatorKey,
  routes: routes,
  pageBuilder: (context, state) =>
      MaterialPage<void>(key: state.pageKey, child: builder(context, state)),
);

/// Builds the app's route table.
///
/// A fresh instance per app — rather than a process-wide global — keeps the
/// navigator key and the current location private to that app, which is what
/// makes building several apps in one test process safe.
///
/// Top level stays at three destinations (the dock). Sub-pages — the account
/// page and the about page — are pushed on the root navigator so they cover the
/// dock, which is what makes them read as "one level deeper" rather than as a
/// fourth destination.
///
/// ## 首启门
///
/// [settings] 的 `welcomeCompleted` 决定第一屏是主页还是引导页：[redirect]
/// 在它还是 false 时把**所有**路径都改写成 [shuWelcomePath]。用重定向而不是
/// 「在页面里判断要不要盖一层」，是因为后者挡不住深链接与 `go('/settings/...')`
/// 这类跳转 —— 那些路径会从引导底下穿过去，而引导页是「没做完就用不了」的
/// 三件事，它必须挡在所有入口前面。
///
/// 引导完成的那一刻由 [ShuWelcomePage] 写标记，随后 `go(shuHomePath)`；
/// 这次跳转会再跑一遍 [redirect]，那时读到的已经是 true，于是放行。
GoRouter createShuRouter({required SettingsStore settings}) {
  final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'shuvpn-root');

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: shuHomePath,
    redirect: (context, state) {
      final done = settings.welcomeCompleted;
      final atWelcome = state.matchedLocation == shuWelcomePath;
      if (!done) return atWelcome ? null : shuWelcomePath;
      return atWelcome ? shuHomePath : null;
    },
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            DockShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/services',
                builder: (context, state) => const ServicesPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/connect',
                builder: (context, state) => const ConnectPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsPage(),
                routes: <RouteBase>[
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'account',
                    builder: (context, state) => const AccountPage(),
                  ),
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'appearance',
                    builder: (context, state) =>
                        const ShuAppearanceSettingsPage(),
                  ),
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'connection',
                    builder: (context, state) =>
                        const ShuConnectionSettingsPage(),
                  ),
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'experimental',
                    builder: (context, state) =>
                        const ShuExperimentalSettingsPage(),
                  ),
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'protocol/atrust',
                    builder: (context, state) => const ShuATrustSettingsPage(),
                  ),
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'protocol/easyconnect',
                    builder: (context, state) =>
                        const ShuEasyConnectSettingsPage(),
                  ),
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'protocol/openvpn',
                    builder: (context, state) => const ShuOpenVpnSettingsPage(),
                  ),
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'about',
                    builder: (context, state) => const AboutPage(),
                  ),
                  _subPage(
                    parentNavigatorKey: rootNavigatorKey,
                    path: 'log',
                    builder: (context, state) => const ShuLogPage(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      _subPage(
        parentNavigatorKey: rootNavigatorKey,
        path: '/notifications',
        builder: (context, state) => const NotificationsPage(),
      ),
      // 引导页挂在**根导航器的最外层**：它要盖住 dock，也不能被任何一条
      // 二级路由当作「上一页」推回去。
      _subPage(
        parentNavigatorKey: rootNavigatorKey,
        path: shuWelcomePath,
        builder: (context, state) => const ShuWelcomePage(),
      ),
    ],
  );
}

/// The account surface currently in use.
///
/// Backed by the real Shanghai University unified-identity flow: one login, then
/// a credential exchange per registered system (see `lib/core/auth`).
///
/// [preferences] is threaded in so the aTrust device id is the same one the
/// tunnel uses — the gateway binds a session to a device — and so the account
/// snapshot (last verified identity and system states) survives a restart.
AccountCenter createAccountCenter({SharedPreferences? preferences}) =>
    ShuAccountCenter(preferences: preferences);
