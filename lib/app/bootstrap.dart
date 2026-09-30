import 'package:flutter/material.dart';

import '../core/settings/settings_schema.dart';
import '../core/settings/settings_store.dart';
import 'app.dart';
import 'shu_launch_surface.dart';
import 'theme.dart';

/// 启动外壳：**先把第一帧画出来，再去读设置**。
///
/// 顺序与 [`main`] 里的做法相反是有原因的。以前是
/// `await SettingsStore.load()` → `await migrateIfNeeded()` → `runApp(...)`，
/// 于是从原生启动图消失到 Flutter 画出第一个像素之间是一段**纯等待**：
/// 屏幕上什么都没有，用户看到的是启动图直接跳成主页。现在 `runApp` 是第一
/// 件事，等待期间屏幕上已经是 [ShuLaunchSurface]，读完了再换成真正的应用。
///
/// 设置仍然在**任何一行代码读它之前**读完 —— `ShuVpnApp` 是读完才被建出来的，
/// 所以「迁移必须在读取之前跑完」这条约束没有被破坏，只是等待的位置从
/// `main()` 挪到了这里。
///
/// ## 最短展示时长
///
/// 只按真实耗时显示的话，`SharedPreferences` 在多数机器上几十毫秒就好了 ——
/// 图标会**闪一下**，比完全不显示更难看（闪一下读起来像闪屏故障）。所以给它
/// 一个下限：短的补到 [minimumSplash]，长的就等它。这不是「故意拖延启动」，
/// 补的那一段本来也留着给原生那边的首帧渲染。
class ShuVpnBootstrap extends StatefulWidget {
  const ShuVpnBootstrap({
    super.key,
    this.minimumSplash = const Duration(milliseconds: 700),
  });

  /// 启动页至少停留多久。
  final Duration minimumSplash;

  @override
  State<ShuVpnBootstrap> createState() => _ShuVpnBootstrapState();
}

class _ShuVpnBootstrapState extends State<ShuVpnBootstrap> {
  SettingsStore? _settings;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final startedAt = DateTime.now();
    try {
      final settings = await SettingsStore.load();
      // 模式迁移必须在任何设置被读取之前跑完，否则读到的是上一个版本的语义。
      // 它只碰 `settings.` 与 `app.` 开头的键 —— 统一身份认证的会话
      // （`auth.`）不在其中，升级版本不会把人登出。
      await ShuSettingsStore(settings.preferences).migrateIfNeeded();
      final remaining =
          widget.minimumSplash - DateTime.now().difference(startedAt);
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
      if (!mounted) return;
      setState(() => _settings = settings);
    } on Object catch (error) {
      // 起不来的原因只剩「读不到设置」这一种。它是致命的：没有设置就没有
      // 主题、没有端点、也没有 `welcomeCompleted`，硬往下走只会到处报错。
      // 所以这里停下来说清楚，而不是带着一堆 null 继续。
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings != null) return ShuVpnApp(settings: settings);

    // 启动页也要有主题：`ShuLaunchSurface` 的底色与图标取自
    // [ShuYoColors]，而 `themeMode: system` 让它在系统深色下自动换成深色
    // 那一套 —— 与 Android 原生启动图的 `-night` 资源对得上。
    return MaterialApp(
      title: 'ShuVPN',
      debugShowCheckedModeBanner: false,
      theme: buildShuTheme(Brightness.light),
      darkTheme: buildShuTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: _error == null
          ? const ShuLaunchSurface()
          : _BootstrapError(error: '$_error'),
    );
  }
}

/// 「设置读不出来」那一屏。
///
/// 语气与日志一致（见 `shu_log.dart`）：陈述发生了什么，不喊，也不给一个
/// 点了没用的「重试」按钮 —— 这里能重试的动作用户本来就做不了（要重开应用）。
class _BootstrapError extends StatelessWidget {
  const _BootstrapError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(ShuSpacing.page * 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '无法读取设置',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '重开应用再试一次。\n\n$error',
              style: TextStyle(color: colors.textTertiary, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
