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

import 'app/bootstrap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 这里**故意不 await**：设置要等读完，而等待期间屏幕上应该有东西。
  // 读取与模式迁移都挪进了 `ShuVpnBootstrap` —— 它加载时显示启动图，加载完
  // 才建出真正的应用。顺序上的要求（迁移必须在任何设置被读取之前跑完）没有
  // 变，变的只是等待发生在哪一帧。
  runApp(const ShuVpnBootstrap());
}
