import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/atrust_device_id.dart';
import '../../core/connection/connection_controller.dart';
import '../../core/connection/protocol.dart';
import '../../core/settings/settings_store.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/shu_surfaces.dart';

/// 「aTrust 协议」。
///
/// 这一页回答的问题是「**用哪条路连出去，那条路怎么配**」。三段：
///
/// 1. 一个总开关 —— 关掉之后连接页上那一段就变灰、选不中；
/// 2. **基础配置** —— 决定「连到谁」：服务器地址、登录域；
/// 3. **高级配置** —— 决定「这次握手怎么算完」：超时，加两项只看的身份。
///
/// 分组用的是账户页那两行小字（[SectionHeader]），不是卡片、不是分隔线 ——
/// 那点边界感靠小字和行距就够了，再套一层框反而把「一个设置一行」说成了
/// 「一组设置一框」。
///
/// ## 配置项是怎么挑出来的
///
/// 它们**一一对应到 SDK 真的收下的那几个参数**，而不是照着别的客户端抄一份
/// 表单出来。协议核心收的是一个 `SangforConnectOptions`，里面可配的只有
/// 服务器、`loginDomain`、`deviceId`、`timeout`（用户名密码在 OAuth2 链路上
/// 根本不发，`authType` 只有密码一种被实现）。所以这一页就是这几项，
/// 每项都能直接用 —— 不改也能连上，想改的地方都摆在这里。
///
/// 服务器地址与登录域不是「空着待填」的：它们出厂就有值（[SettingsStore]
/// 的默认就是上大那台网关），点进去是**改**而不是**填**。
class ShuATrustSettingsPage extends StatelessWidget {
  const ShuATrustSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final deviceId = ShuATrustDeviceId(settings.preferences);
    // 隧道在跑时这一页的每一项都改不动。判据是 `tunnelUp` 而不是 `busy`：
    // 这些值全是下一次握手才会被读的参数，正握手中改一下同样只会得到
    // 「界面上写着新值、实际还是旧值」。
    final locked = context.watch<ConnectionController>().tunnelUp;

    return ShuSettingsSubPage(
      title: 'aTrust 协议',
      banner: locked ? const ShuNoticeBar(shuSettingsLockedNotice) : null,
      children: [
        SettingsSwitchRow(
          icon: ShuProtocol.atrust.icon,
          title: '启用 aTrust',
          value: settings.isProtocolEnabled(ShuProtocol.atrust),
          enabled: !locked,
          onChanged: (value) =>
              settings.setProtocolEnabled(ShuProtocol.atrust, value),
        ),

        const SectionHeader(title: '基础配置'),
        SettingsRow(
          icon: Icons.dns_outlined,
          title: '服务器地址',
          value: settings.server,
          enabled: !locked,
          onTap: () => _editServer(context, settings),
        ),
        SettingsRow(
          icon: Icons.domain_outlined,
          title: '登录域',
          value: settings.loginDomain,
          enabled: !locked,
          onTap: () => _editLoginDomain(context, settings),
        ),

        const SectionHeader(title: '高级配置'),
        SettingsRow(
          icon: Icons.timer_outlined,
          title: '连接超时',
          value: '${settings.timeout.inSeconds} 秒',
          enabled: !locked,
          onTap: () => _pickTimeout(context, settings),
        ),
        // 设备标识是**只读**的：它由应用生成并持久化，网关用它把会话绑在机器上 ——
        // 这里既不该让用户编一个，也不该让用户把它清掉（清了等于换了台手机）。
        // 之所以还是摆出来：排障时「这台机器在网关眼里是谁」是第一个要看的东西。
        SettingsRow(
          icon: Icons.fingerprint,
          title: '设备标识',
          value: deviceId.masked,
        ),
        // 协议栈同理：没有第二个选项的选择不叫选择。写在这里是为了让人知道
        // 走的是 OAuth2 而不是网关的本地密码分支。
        SettingsRow(
          icon: Icons.vpn_key_outlined,
          title: '认证方式',
          value: 'OAuth2',
        ),
        SettingsRow(
          icon: Icons.restart_alt,
          title: '恢复默认值',
          danger: true,
          enabled: !locked,
          onTap: () => _restoreDefaults(context, settings),
        ),
      ],
    );
  }

  /// 服务器地址。空值被挡在这里 —— 后面 `_serverUri` 还要再挡一次，
  /// 但用户在对话框里当场知道答案，比按了保存才知道要好。
  Future<void> _editServer(BuildContext context, SettingsStore settings) async {
    final value = await showShuTextPrompt(
      context: context,
      title: '服务器地址',
      label: '域名或 IP',
      initial: settings.server,
      helper: '不需要写 https://，协议固定为 HTTPS',
      validate: (value) {
        if (value.isEmpty) return '不能为空';
        if (value.contains(' ')) return '不能包含空格';
        return null;
      },
    );
    if (value == null) return;
    settings.server = value;
  }

  Future<void> _editLoginDomain(
    BuildContext context,
    SettingsStore settings,
  ) async {
    final value = await showShuTextPrompt(
      context: context,
      title: '登录域',
      label: 'sfDomain',
      initial: settings.loginDomain,
      helper: '由网关的 authConfig 下发，改错了会连不上',
      validate: (value) => value.isEmpty ? '不能为空' : null,
    );
    if (value == null) return;
    settings.loginDomain = value;
  }

  Future<void> _pickTimeout(
    BuildContext context,
    SettingsStore settings,
  ) async {
    final next = await showShuChoiceSheet<int>(
      context: context,
      title: '连接超时',
      current: settings.timeout.inSeconds,
      options: const [
        ShuChoice(30, '30 秒'),
        ShuChoice(60, '60 秒', '默认'),
        ShuChoice(120, '120 秒'),
        ShuChoice(180, '180 秒'),
      ],
    );
    if (next != null) settings.timeout = Duration(seconds: next);
  }

  /// 恢复出厂值。它**删掉**协议相关的设置键，而不是写一份常量进去 ——
  /// 出厂值本来就是「读不到时用哪个」，写进磁盘只会让「用户没改过」与
  /// 「用户改成了恰好等于出厂值」从此分不清。
  ///
  /// 确认框里把要动的东西全列出来：这一步撤销不了，得先知道代价。
  Future<void> _restoreDefaults(
    BuildContext context,
    SettingsStore settings,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复默认值'),
        content: const Text(
          '服务器地址、登录域、连接超时都会回到出厂值，协议开关也会重置'
          '（只有 aTrust 是打开的）。\n设备标识不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await settings.restoreConnectionDefaults();
    if (!context.mounted) return;
    showShuSnack(context, '已恢复默认值');
  }
}

/// 「EasyConnect 协议」。
///
/// 只有一行灰开关加一句小字。
///
/// 曾经这里摆过「基础配置 / 高级配置」两段与三项只读值（服务器地址 / 登录域 /
/// 连接超时）—— 那三项本来就是 aTrust 的配置，在这一页只读地重列一遍，
/// 等于把同一份数据在两个地方各说一次。**未接入的协议没有任何参数**，
/// 摆空的分组标题反而让人以为下面漏了内容。
///
/// 为什么封住而不是把这一页删掉：协议核心就在包里
/// （`flutter_sangfor_easy_connect`），把它接上就是把这一行的 `enabled`
/// 换掉，不是从零开始。把入口留着，用户能看见「这个位置有东西」（它是一个
/// 真的入口，目录页也有它一行），只是现在还不提供服务。
class ShuEasyConnectSettingsPage extends StatelessWidget {
  const ShuEasyConnectSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 这一页的开关本来就点不动（协议未实现），这一条说的是它为什么会多
    // 一层锁：连着的时候它同样属于「运行期不可改」的那一类。
    return ShuSettingsSubPage(
      title: 'EasyConnect 协议',
      banner: context.watch<ConnectionController>().tunnelUp
          ? const ShuNoticeBar(shuSettingsLockedNotice)
          : null,
      children: const [
        _SealedSwitchRow(protocol: ShuProtocol.easyConnect),
        ShuSettingsNote('未来版本接入服务'),
      ],
    );
  }
}

/// 「OpenVPN 协议」。
///
/// 与 EasyConnect 不同，OpenVPN 是**完全另一套协议**：它不是 Sangfor 家族的
/// 东西，也不在包里那三个依赖的范围内，这个应用里一行实现都没有。
/// 但页面形态一致 —— 它同样是「现在没有可配的东西」，所以也不摆配置项。
class ShuOpenVpnSettingsPage extends StatelessWidget {
  const ShuOpenVpnSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ShuSettingsSubPage(
      title: 'OpenVPN 协议',
      banner: context.watch<ConnectionController>().tunnelUp
          ? const ShuNoticeBar(shuSettingsLockedNotice)
          : null,
      children: const [
        _SealedSwitchRow(protocol: ShuProtocol.openVpn),
        ShuSettingsNote('未来版本接入服务'),
      ],
    );
  }
}

/// 封住的开关行：显示成「关、且点不动」。
///
/// 灰着而不是藏起来 —— 藏起来的话，用户没法判断「这里本来有东西」还是
/// 「这个应用不做这件事」，而这两种结论会引向完全不同的下一步。
///
/// 不写副标题：为什么点不动由开关下面那句「未来版本接入服务」回答，
/// 同一件事不需要在行内再说一遍。
class _SealedSwitchRow extends StatelessWidget {
  const _SealedSwitchRow({required this.protocol});

  final ShuProtocol protocol;

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchRow(
      icon: protocol.icon,
      title: '启用 ${protocol.label}',
      value: false,
      enabled: false,
    );
  }
}
