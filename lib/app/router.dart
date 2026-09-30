import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/account/account_center.dart';
import '../features/account/account_page.dart';
import '../features/connect/connect_page.dart';
import '../features/notifications/notifications_page.dart';
import '../features/services/services_page.dart';
import '../features/settings/about_page.dart';
import '../features/settings/appearance_settings_page.dart';
import '../features/settings/connection_settings_page.dart';
import '../features/settings/experimental_settings_page.dart';
import '../features/settings/log_page.dart';
import '../features/settings/protocol_settings_page.dart';
import '../features/settings/settings_page.dart';
import '../shell/dock_shell.dart';

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
GoRouter createShuRouter() {
  final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'shuvpn-root');

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/connect',
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
                  GoRoute(
                    path: 'account',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const AccountPage(),
                  ),
                  GoRoute(
                    path: 'appearance',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) =>
                        const ShuAppearanceSettingsPage(),
                  ),
                  GoRoute(
                    path: 'connection',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) =>
                        const ShuConnectionSettingsPage(),
                  ),
                  GoRoute(
                    path: 'experimental',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) =>
                        const ShuExperimentalSettingsPage(),
                  ),
                  GoRoute(
                    path: 'protocol/atrust',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const ShuATrustSettingsPage(),
                  ),
                  GoRoute(
                    path: 'protocol/easyconnect',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) =>
                        const ShuEasyConnectSettingsPage(),
                  ),
                  GoRoute(
                    path: 'protocol/openvpn',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const ShuOpenVpnSettingsPage(),
                  ),
                  GoRoute(
                    path: 'about',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const AboutPage(),
                  ),
                  GoRoute(
                    path: 'log',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const ShuLogPage(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/notifications',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const NotificationsPage(),
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
