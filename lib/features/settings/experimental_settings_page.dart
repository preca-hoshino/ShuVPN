import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../core/settings/settings_store.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/settings_scaffold.dart';

/// 「实验性选项」。界面上唯一一页**默认什么都不该打开**的设置。
///
/// 单独成页的理由只有一条：这里改的是数据面的基本行为，走不通时会让设备在
/// 连接期间上不了网 —— 不该和「网络连接」里那些日常设置挤在一起。
/// 页首那一行只提醒「不稳定、想清楚再动」，具体后果放在打开时的确认框里 ——
/// 那才是真正要动手的那一刻。
class ShuExperimentalSettingsPage extends StatelessWidget {
  const ShuExperimentalSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();

    return ShuSettingsSubPage(
      title: '实验性选项',
      children: [
        const ShuSettingsWarning('下列实验性选项行为不稳定，请确认你清楚自己在做什么。'),
        SettingsSwitchRow(
          icon: Icons.science_outlined,
          title: 'TCP 走 L3',
          value: settings.vpnTcpOverL3,
          onChanged: (value) => _toggleTcpOverL3(context, settings, value),
        ),
        // 入口，不是开关 —— 按下去立刻离开这一页，所以画着右箭头。
        SettingsRow(
          icon: Icons.tour_outlined,
          title: '新用户引导',
          onTap: () => _replayOnboarding(context),
        ),
      ],
    );
  }

  /// 拨「TCP 走 L3」。
  ///
  /// 开启前把代价说全：这条路走不通时，这台设备在连着的时候会**完全**没有
  /// TCP 联网能力。关闭**不问** —— 那一步永远朝着安全的方向走。
  Future<void> _toggleTcpOverL3(
    BuildContext context,
    SettingsStore settings,
    bool value,
  ) async {
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('开启 TCP 走 L3'),
          content: const Text(
            '开启后，TCP 与 UDP 流量将全部由 VPN 接口转发，系统不再设置代理。\n'
            '若服务端不支持 TCP-over-L3，连接期间浏览器等应用将无法上网。\n'
            '恢复方法：断开连接，关闭此选项，然后重新连接。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('开启'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    settings.vpnTcpOverL3 = value;
  }

  /// 重新走一遍新用户引导。
  ///
  /// 清掉 `welcomeCompleted`，路由的重定向于是把界面锁在引导页上 —— 三页
  /// 走完（含重新登录）之前回不到主页，所以先问一次。
  Future<void> _replayOnboarding(BuildContext context) async {
    final settings = context.read<SettingsStore>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新开始引导'),
        content: const Text('引导完成前无法返回主页，完成后需要重新登录校园账户。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重新开始'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    // 写标记必须在 `go` 之前：路由的重定向会读它。
    settings.welcomeCompleted = false;
    context.go(shuWelcomePath);
  }
}
