import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/connection/connection_controller.dart';
import '../../core/connection/proxy_listen.dart';
import '../../core/settings/settings_store.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/shu_surfaces.dart';

/// 「网络连接」。
///
/// 这一页回答的是「本机把流量交给谁」—— 与「连哪台网关」无关，后者在
/// aTrust 协议那一页。两者分开是因为它们改变的时机不同：网关是登录时就
/// 定下来、很少动的东西；下面这三条数据面则是接上隧道之后马上要用的。
///
/// ## 三条数据面
///
/// | 数据面 | 消费者 | 平台 |
/// | :--- | :--- | :--- |
/// | 本机 HTTP 代理 | 系统代理 / 绝大多数应用 | 全平台 |
/// | 本机 SOCKS5 代理 | 自己支持 SOCKS5 的应用 | 全平台 |
/// | Android VPN 服务 | 系统 `VpnService`，接管整机 | 仅 Android |
///
/// 前两条是用户态的，不向系统要任何权限；第三条要一次系统授权。
///
/// ## 为什么 HTTP 与 SOCKS5 各有一套开关和监听地址
///
/// Android 的系统代理**只支持 HTTP**：设置里的「WLAN → 代理」只有 HTTP
/// 一个选项，`VpnService.Builder.setHttpProxy` 收的也是 HTTP。没有任何
/// 系统开关能表达「所有应用都用 SOCKS5」—— 把一个应用指向 SOCKS5 端口，
/// 得到的往往是零个连接：那一侧从来不知道要去连它。
///
/// 两个通道的服务对象不同，所以监听范围也是**两条独立的安全边界**：
/// 把 HTTP 开给同网络的设备，不等于也想把 SOCKS5 开出去。合成一套设置会让
/// 其中一个被迫跟着另一个走。
///
/// ## VPN 那一层的分工：L3 管 UDP，HTTP 代理管 TCP
///
/// 这一层由**本应用自己**建立（`ShuVpnService`）。它同时做两件事：
///
/// 1. 把网关资源表里**L3 背得动**的网段交给 TUN；
/// 2. 用 `setHttpProxy` 把系统代理指到本机的 HTTP 端口上。
///
/// 分开是不得已的：aTrust 的 L3 数据面在 `matchL3Route` 里对 TCP 有一道
/// `if (protocol == 'tcp' && !route.enableTcpPrefL3) continue;` —— 网关没有
/// 逐资源打开这个开关时（SHU 一条都没开），**任何 TCP 包都会被静默丢弃**
/// （`sendPacket` 返回 false，而 `SangforTunnelRouter` 不看返回值）。
///
/// 而 TUN 的路由是按目的**地址**分流的，认不出协议。把一条 TCP 也能到达
/// 的网段交给 TUN，那些地址上的 TCP 就会全部进一个不报错的黑洞。所以
/// TUN 只拿「同一条网段上没有任何非 UDP 资源」的那一小部分，TCP 全部
/// 交给本机 HTTP 代理 —— 它把每条连接挖进隧道的 TCP 通道。
///
/// 这也是为什么「启用 HTTP 代理」关着、而「启用 VPN 服务」开着时 HTTP
/// 通道照样会起来：它不是可选的数据面，是系统 VPN 的依赖。那个开关管的是
/// 「不接 VPN 时要不要也起一个 HTTP 代理」。
///
/// 本应用自己被排除在 VPN 之外（否则隧道传输会自环），所以应用内的
/// WebView 不经过隧道 —— 那本来也只用来登录公网 SSO。
///
/// ## 所有目标都走隧道
///
/// 代理**没有**「资源外直连」这种兜底：目标不在网关资源表内就是一次明确的
/// 失败，不会私下从底层网络出去。一个会偷偷直连的代理，在用户看来与
/// 「隧道坏了但还能上网」完全一样 —— 那是最难发现的一类故障。
///
/// ## 为什么开关自己会干活
///
/// 「启用 HTTP 代理」这类开关不是一个「下次连接时生效」的标记 —— 隧道
/// 已经起来时拨开关，它当场就把那一层拉起来或停下去。一个只在重连后才生效
/// 的开关，在用户看来就是「拨了没反应」。
///
/// ## 运行期锁定
///
/// 隧道在跑的时候这一页**整页不可改**（见 [shuSettingsLockedNotice]）：所有
/// 取值都是建立监听那一刻定下来的，中途改只会得到「界面上写着新值、实际还
/// 绑在旧值」这种查不出来的不一致。要改就先断开。
///
/// ⚠️ 「连接超时」**不在**这一页，在 aTrust 协议页。它是握手超时（认证到
/// 隧道建好整段），不是网络层的连通性探测 —— 把它摆在端口中间，会让人以为
/// 它管的是「本机转发的超时」。
///
/// 证书固定（TOFU）的入口也**不在**这一页。指纹仍然照常校验（见
/// `ConnectionController._trustCertificate`），但清除入口撤掉了：它是一次
/// 没有回退的信任重置，摆在一堆日常设置中间太容易误触。
///
/// 尚未稳定的开关（把 TCP 交给 L3 的那一个）同样**不在**这一页，在
/// 「实验性选项」。这一页上的每一项都是**建立监听那一刻**定下来的绑定参数，
/// 所以运行期整页封住；实验开关只在连接时被读一次，改动下一次连接就生效 ——
/// 两者不是同一种东西，混在一起会让「为什么这里点不动」变得没有道理。
class ShuConnectionSettingsPage extends StatefulWidget {
  const ShuConnectionSettingsPage({super.key});

  @override
  State<ShuConnectionSettingsPage> createState() =>
      _ShuConnectionSettingsPageState();
}

/// 两条本机代理通道。
///
/// 它们的设置项完全同形（开关 / 监听地址 / 端口），只有取值来源不同 ——
/// 用一个枚举把「同形」写进类型里，比把同一段 UI 复制两遍少一半错误。
/// 它不出现在任何选择器里：这是同一件事的两个实例，不是给用户挑的选项。
enum _ProxyChannel {
  http('HTTP', Icons.public),
  socks('SOCKS5', Icons.settings_ethernet);

  const _ProxyChannel(this.label, this.icon);

  final String label;
  final IconData icon;

  bool enabledIn(SettingsStore settings) =>
      this == http ? settings.httpProxyEnabled : settings.socksProxyEnabled;

  ShuProxyListen listenIn(SettingsStore settings) =>
      this == http ? settings.httpListen : settings.socksListen;

  int portIn(SettingsStore settings) =>
      this == http ? settings.httpPort : settings.socksPort;
}

class _ShuConnectionSettingsPageState extends State<ShuConnectionSettingsPage> {
  @override
  void initState() {
    super.initState();
    // 授权可能在系统设置里被手动取消，所以每次进入都重问一次，
    // 而不是缓存一个值。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ConnectionController>().refreshVpnPermission();
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final connection = context.watch<ConnectionController>();
    // 隧道在跑时整页封住。判据是 `tunnelUp` 而不是某个数据面的运行标志：
    // VPN 没开、只有代理在跑时，改 DNS / MTU 同样没有意义 —— 那些值要等
    // 下一次建接口才被读。授权状态那一行例外（见下）：它是只读的观测。
    final locked = connection.tunnelUp;
    final editable = !locked && !connection.busy;
    // 授权状态这一行要说的那句话，与引导页第 1 页共用（见
    // `shuVpnPermissionStatus`）：同一件事在两个页面上不能有第二种读法。
    final status = shuVpnPermissionStatus(
      context,
      supported: connection.vpnSupported,
      prepared: connection.vpnPrepared,
    );

    return ShuSettingsSubPage(
      title: '网络连接',
      banner: locked ? const ShuNoticeBar(shuSettingsLockedNotice) : null,
      children: [
        for (final channel in _ProxyChannel.values) ...[
          SectionHeader(title: '${channel.label} 代理'),
          SettingsSwitchRow(
            icon: channel.icon,
            title: '启用 ${channel.label} 代理',
            value: channel.enabledIn(settings),
            enabled: editable,
            onChanged: (value) =>
                _setProxyEnabled(settings, connection, channel, value),
          ),
          SettingsRow(
            icon: Icons.lan_outlined,
            title: '${channel.label} 监听地址',
            // 显示「名字 · 地址」而不是只显示名字：这一行是用户确认
            // 「现在到底绑在哪张网卡」的唯一地方。
            value: channel.listenIn(settings).display,
            enabled: editable,
            onTap: () => _editListen(settings, connection, channel),
          ),
          SettingsRow(
            icon: Icons.numbers,
            title: '${channel.label} 代理端口',
            value: _portLabel(channel.portIn(settings)),
            enabled: editable,
            onTap: () => _editPort(settings, connection, channel),
          ),
        ],

        const SectionHeader(title: 'Android VPN 服务'),
        SettingsSwitchRow(
          icon: Icons.vpn_lock_outlined,
          title: '启用 VPN 服务',
          value: settings.vpnEnabled,
          enabled: editable,
          onChanged: (value) => _toggleVpn(settings, connection, value),
        ),
        SettingsRow(
          icon: Icons.verified_user_outlined,
          title: '系统授权状态',
          value: status.text,
          valueColor: status.color,
          // 未连接时点它可以补一次授权（授权也可以在系统设置里被撤销，
          // 所以这一行是只读观测 + 一个重新询问的入口）。隧道跑起来之后
          // 连它也封住 —— 这一页在运行期「整页不可改」是一条不打折的
          // 规则，留一个例外只会让人以为别的行说不定也能点。
          enabled: !locked,
          onTap: connection.vpnSupported && !locked
              ? () => _requestPermission(connection)
              : null,
        ),
        SettingsRow(
          icon: Icons.straighten,
          title: 'MTU',
          value: '${settings.vpnMtu}',
          enabled: editable,
          onTap: () => _pickMtu(settings),
        ),
        SettingsRow(
          icon: Icons.dns_outlined,
          title: 'DNS',
          // 留空 = 用底层网络那一组（原生侧会自己从系统取，并在 API 33+
          // 把它们排除在隧道之外）。不指网关下发的那一组：那些是内网
          // 地址，在底层网络里不可达。
          value: settings.vpnDns.isEmpty ? '跟随系统' : settings.vpnDns,
          enabled: editable,
          onTap: () => _pickDns(settings),
        ),
      ],
    );
  }

  static String _portLabel(int port) => port == 0 ? '自动' : '$port';

  /// 拨某个通道的启用开关：设置写下来，顺手把这一层拉起来或停下去。
  ///
  /// 两个通道各自处理：HTTP 端口被占不该把 SOCKS5 也关掉，反过来也一样。
  Future<void> _setProxyEnabled(
    SettingsStore settings,
    ConnectionController connection,
    _ProxyChannel channel,
    bool value,
  ) async {
    switch (channel) {
      case _ProxyChannel.http:
        settings.httpProxyEnabled = value;
      case _ProxyChannel.socks:
        settings.socksProxyEnabled = value;
    }
    if (!connection.tunnelUp || connection.busy) return;
    if (value) {
      if (channel == _ProxyChannel.http) {
        await connection.startHttpProxy();
      } else {
        await connection.startSocksProxy();
      }
    } else {
      if (channel == _ProxyChannel.http) {
        await connection.stopHttpProxy();
      } else {
        await connection.stopSocksProxy();
      }
    }
  }

  /// 拨「启用 VPN 服务」。
  ///
  /// 与代理不同，这一条有个前置：**系统授权**。没授权就先把开关退回关，
  /// 并说清原因 —— 直接写进设置会让下次连接在无声中失败。
  Future<void> _toggleVpn(
    SettingsStore settings,
    ConnectionController connection,
    bool value,
  ) async {
    if (value && connection.vpnSupported && connection.vpnPrepared != true) {
      final granted = await connection.requestVpnPermission();
      if (!mounted) return;
      if (!granted) {
        showShuSnack(context, '未授予 VPN 权限，未能启用');
        return;
      }
    }
    settings.vpnEnabled = value;
    if (!connection.tunnelUp || connection.busy) return;
    if (value && !connection.vpnRunning) {
      await connection.startVpn();
    } else if (!value && connection.vpnRunning) {
      await connection.stopVpn();
    }
  }

  Future<void> _requestPermission(ConnectionController connection) async {
    final granted = await connection.requestVpnPermission();
    if (!mounted) return;
    showShuSnack(context, granted ? '已获得 VPN 授权' : '未授予 VPN 权限');
  }

  /// 填监听地址。
  ///
  /// 从两个预设放成自由填写，是因为只有「仅本机 / 所有网卡」表达不了
  /// 「只放行某一张网卡」这种需求；放开之后只想让 USB 网络共享那一台连进来
  /// 也有了写法。代价是错误输入的入口也变宽了，所以两道门都留着：
  ///
  /// 1. 字面地址校验（在 [ShuProxyListen.parse] 里，对话框上直接报错）；
  /// 2. 任何非回环地址都要过一次确认 —— 隧道是「以你的身份进校园网」的
  ///    东西，把入口开给别的设备等于把校园账号借出去。
  ///
  /// 改完还要重绑：绑定地址是**建立监听那一刻**定下来的，不重绑就是旧值。
  /// 两个通道各绑各的，所以重绑也分开做 —— 改 HTTP 的地址不该让 SOCKS5
  /// 那一侧断一下。
  Future<void> _editListen(
    SettingsStore settings,
    ConnectionController connection,
    _ProxyChannel channel,
  ) async {
    final current = channel.listenIn(settings);
    final value = await showShuTextPrompt(
      context: context,
      title: '${channel.label} 监听地址',
      label: '绑定地址',
      initial: current.address,
      helper:
          '只能填 IP 地址。127.0.0.1 = 仅本机，0.0.0.0 = 所有网卡，'
          '也可以填某一张网卡上的地址。',
      validate: (raw) =>
          ShuProxyListen.parse(raw) == null ? '请填一个 IP 地址，例如 127.0.0.1' : null,
    );
    if (value == null) return;
    final next = ShuProxyListen.parse(value);
    // 对话框已经校过一遍，这里只是让类型收窄 —— 多一道门不亏。
    if (next == null || next == current) return;
    if (!mounted) return;

    if (next.exposesToNetwork) {
      final confirmed = await _confirmExpose(next, channel);
      if (confirmed != true) return;
    }

    switch (channel) {
      case _ProxyChannel.http:
        settings.httpListen = next;
      case _ProxyChannel.socks:
        settings.socksListen = next;
    }
    if (channel == _ProxyChannel.http) {
      await connection.rebindHttpProxy();
    } else {
      await connection.rebindSocksProxy();
    }
  }

  /// 「把入口开给别的设备」的确认框。两个通道共用同一段话术。
  Future<bool?> _confirmExpose(ShuProxyListen next, _ProxyChannel channel) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('允许同网络的设备连入？'),
        content: Text(
          '${channel.label} 代理会监听 ${next.address}，从这个地址能连过来的'
          '设备都可以通过你的校园账号访问校园网，而且不需要密码。\n'
          '只在自己的可信网络里这样做。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  Future<void> _editPort(
    SettingsStore settings,
    ConnectionController connection,
    _ProxyChannel channel,
  ) async {
    final current = channel.portIn(settings);
    final port = await showDialog<int>(
      context: context,
      builder: (_) =>
          _PortDialog(title: '${channel.label} 端口', initial: current),
    );
    if (port == null || port == current) return;
    switch (channel) {
      case _ProxyChannel.http:
        settings.httpPort = port;
      case _ProxyChannel.socks:
        settings.socksPort = port;
    }
    // 端口和地址一样是绑定参数，改完不重绑就还是旧的 —— 而界面上已经
    // 显示新的了，那种不一致比「没改」更难查。
    if (channel == _ProxyChannel.http) {
      await connection.rebindHttpProxy();
    } else {
      await connection.rebindSocksProxy();
    }
  }

  /// 拨「TCP 走 L3（实验）」的入口已经不在这里 —— 它搬去了「实验性选项」，
  /// 与它的确认框一起。这一页只管绑定参数。
  Future<void> _pickMtu(SettingsStore settings) async {
    final next = await showShuChoiceSheet<int>(
      context: context,
      title: 'MTU',
      current: settings.vpnMtu,
      options: const [
        ShuChoice(1280, '1280', 'IPv6 下限，最保守'),
        ShuChoice(1400, '1400', '默认'),
        ShuChoice(1500, '1500', '以太网值，可能被隧道封装撑破'),
      ],
    );
    if (next != null) settings.vpnMtu = next;
  }

  Future<void> _pickDns(SettingsStore settings) async {
    const custom = '__custom__';
    final choice = await showShuChoiceSheet<String>(
      context: context,
      title: 'DNS',
      current: settings.vpnDns.isEmpty ? '' : custom,
      options: const [
        ShuChoice('', '跟随系统', '用底层网络当前的 DNS 服务器'),
        ShuChoice(custom, '自定义…', '把查询交给隧道里的这一台'),
      ],
    );
    if (choice == null) return;
    if (choice != custom) {
      settings.vpnDns = '';
      return;
    }
    if (!mounted) return;
    final value = await showShuTextPrompt(
      context: context,
      title: 'DNS',
      label: '服务器地址',
      initial: settings.vpnDns,
      helper: '留空则回到「跟随系统」；填了的地址会跟着隧道一起走',
      validate: (value) {
        if (value.isEmpty) return null;
        final octets = value.split('.');
        if (octets.length != 4) return '请填 IPv4 地址';
        for (final octet in octets) {
          final parsed = int.tryParse(octet);
          if (parsed == null || parsed < 0 || parsed > 255) return '请填 IPv4 地址';
        }
        return null;
      },
    );
    if (value == null) return;
    settings.vpnDns = value;
  }
}

/// `0` 在这里是一个有含义的取值（自动），所以不能要求「必须填一个端口号」。
class _PortDialog extends StatefulWidget {
  const _PortDialog({required this.title, required this.initial});

  /// 「HTTP 端口」/「SOCKS5 端口」—— 两个通道共用同一段 UI，标题必须能变。
  final String title;

  final int initial;

  @override
  State<_PortDialog> createState() => _PortDialogState();
}

class _PortDialogState extends State<_PortDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.initial}',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value < 0 || value > 65535) {
      setState(() => _error = '请输入 0–65535 之间的整数');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '端口',
              helperText: '0 表示自动选择空闲端口',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: ShuYoTextStyles.meta(color: colors.danger)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
