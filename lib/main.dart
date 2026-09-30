// ShuVPN — Sangfor aTrust RVPN client for Android.
//
// Architecture: `lib/app` owns the theme, the router and the provider scope;
// `lib/core` owns the state that outlives a screen (connection, account,
// settings); `lib/features` owns the screens; `lib/shell` owns the floating
// dock that ties the three top-level destinations together.
//
// Data plane: two of them, sharing one tunnel. On Android the default is the
// system `VpnService` (`AndroidVpnDevice` fed by `SangforTunnelRouter`), which
// takes over all traffic with a single permission prompt. The userspace SOCKS5
// frontend is the opt-in alternative for letting just a few apps through; it
// binds loopback by default and needs no permission at all.
//
// Error handling: every failure path throws a typed `SangforException`. Nothing
// is swallowed — a cancelled prompt, an unreachable server and a certificate
// mismatch all surface with a distinct `SangforErrorCode` in the UI.

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/settings/settings_schema.dart';
import 'core/settings/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loaded before the first frame so the theme mode and the restored endpoint
  // are already correct when the shell paints.
  final settings = await SettingsStore.load();
  // 设置的模式版本迁移必须在**任何设置被读取之前**跑完，否则读到的是
  // 上一个版本的语义。它只碰 `settings.` 与 `app.` 开头的键 ——
  // 统一身份认证的会话（`auth.`）不在其中，升级版本不会把人登出。
  await ShuSettingsStore(settings.preferences).migrateIfNeeded();
  runApp(ShuVpnApp(settings: settings));
}
