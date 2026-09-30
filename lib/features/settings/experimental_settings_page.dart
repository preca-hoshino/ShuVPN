import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_store.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/settings_scaffold.dart';

/// 「实验性选项」。出厂界面上唯一一页**默认什么都不该打开**的设置。
///
/// ## 为什么单开一页
///
/// 这一页上的开关有一个共同点：它们改变的是**数据面的基本行为**，而不是
/// 调一个参数。放在「网络连接」那一页里有两个具体问题：
///
/// * 那一页整页在运行期封住 —— 端口与监听地址是**绑定参数**，中途改只会
///   得到「界面写着新值、实际绑在旧值」这种查不出来的不一致。实验开关不是
///   绑定参数：它只在连接时被读一次，改了下次连接就生效。两种时机的东西
///   放在同一页上，「这里为什么点不动」就没有道理了；
/// * 那一页每一行都是「日常要用的」，而这一页每一项**默认都不该被打开**。
///   出厂值本身就是一道护栏，混在常用设置里会让它看起来像个普通开关。
///
/// ## 页首那段警告是说给谁听的
///
/// 说给「打算打开它的人」。这里的每一项在走不通时都会让设备在连接期间
/// 上不了网，而且这不是一个理论上的风险：把 TCP 交给 L3 这条路依赖服务端
/// 接受，而上大的网关一条资源都没有开过 `enableTCPPrefL3`。先看清楚再打开，
/// 才知道什么时候该断开、什么时候该关掉。
///
/// 语气刻意克制 —— 陈述后果，不喊，不加感叹号。吓人的写法只会让人跳过这
/// 一段，而跳过的人正好是最该看见它的那一个。
class ShuExperimentalSettingsPage extends StatelessWidget {
  const ShuExperimentalSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();

    return ShuSettingsSubPage(
      title: '实验性选项',
      children: [
        const ShuSettingsWarning(
          '这一页里的行为尚未稳定，走不通时可能让设备在连接期间完全上不了网。'
          '它们默认全部关闭。打开之前先看清楚每一项的后果。',
        ),
        SettingsSwitchRow(
          icon: Icons.science_outlined,
          title: 'TCP 走 L3',
          subtitle: '本地把网关的 enableTCPPrefL3 翻成打开，TCP 与 UDP 全部交给 TUN',
          value: settings.vpnTcpOverL3,
          onChanged: (value) => _toggle(context, settings, value),
        ),
        const ShuSettingsNote(
          '打开之后不再设置系统代理，本机 HTTP 代理也不会被拉起，'
          'TCP 走 TUN 那条路。\n'
          '结论写在日志里，看 [L3] 开头的那几行：握手之后有没有流认证的答复。\n'
          '改动在下一次连接时生效，不需要先断开。',
        ),
      ],
    );
  }

  /// 拨开关。
  ///
  /// 打开前把代价说全：这条路走不通时，这台设备在连着的时候会**完全**没有
  /// TCP 联网能力 —— 系统代理一个字都不设，而 TUN 里的 TCP 会被服务端丢掉。
  /// 知道这一点再打开，才知道什么时候该断开。
  ///
  /// 关掉**不问**：那一步永远朝着安全的方向走，多一道确认只会让「连不上网、
  /// 想赶快关掉」的人多按一次。
  Future<void> _toggle(
    BuildContext context,
    SettingsStore settings,
    bool value,
  ) async {
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('这会改变数据面'),
          content: const Text(
            '打开后 TCP 与 UDP 全部交给 TUN，不再设置系统代理。\n'
            '如果服务端不接受 TCP-over-L3，连接期间浏览器等应用会完全连不上网。\n'
            '要恢复：断开连接，把这一项关掉，再连一次。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('打开'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    settings.vpnTcpOverL3 = value;
  }
}
