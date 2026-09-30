import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/shu_app_bar.dart';

/// 右 dock 目的地 —— 设置的**目录页**。
///
/// 这一页只列「有哪几组设置」，每组一行：左边一个图标，中间组名，右边是
/// 这一组**现在是什么**，末尾一个右箭头。真正能改的东西全在二级页里。
///
/// 为什么是目录页而不是一张长页：原先五组十几行全铺开，滚到一半已经忘了
/// 上面写的是什么。更麻烦的是它把两类东西混在同一屏里 ——「账户现在什么
/// 状态」是**看一眼**的事，「把端口改成 1081」是**去做一件事**。目录页
/// 负责前者，二级页负责后者，两种节奏不该挤在一起。
///
/// 形态上刻意保持**裸列表**：没有分组卡片、没有分区小字标题、组之间也
/// 没有分隔线。参考实现 `PiliPlus` 与 `ShuYo` 都是这样，而那层包裹本来
/// 也没多给任何信息 —— 理由写在 [SettingsRow] 上。
///
/// 顺序：账户最先，外观与三类协议居中，网络连接与实验性选项随后，
/// 日志、关于收尾。
/// 账户放第一行和 `ShuOAuthTargets` 把教务系统排第一是同一个理由 ——
/// 先回答「我是谁」。协议排在连接之前是因为「连谁」比「本机怎么转」先决定。
///
/// 唯一一个点进去不是裸列表的是**账户管理** —— 那一页有三行文字的身份块、
/// 可点的账户行和逐系统的凭据状态，它回答的问题不是「改成什么」而是
/// 「现在是谁」，结构本来就不一样。其余各页与目录页同形。
///
/// 每一行**只有名字和「里面有什么」**：副标题写这一组里能改哪几件事，
/// 右侧原本还写着各组的当前值（`张三 · 25123456`、`SOCKSS 1080`、`v0.1.0`、
/// `12 行`），那些去掉了。当前值在这里只做两件事 —— 让每一行看起来都在报
/// 一个数字，以及**每次数字变动时整页都要重画**。想知道现在是什么值，
/// 点进去看；目录页只负责回答「有哪几件事可以改」。
///
/// ⚠️ 副标题是**目录页专有**的。二级页里那些逐个配置项的小字描述已经全部
/// 删掉了（见 `SettingsRow` 的说明），两者不是同一样东西：
/// 这里的副标题说的是「去那一页能做什么」，那里的说的是「这个开关是什么」。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ShuAppBar(
        title: '设置',
        onNotifications: () => context.push('/notifications'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          ShuSpacing.page,
          ShuSpacing.page,
          ShuSpacing.page,
          ShuSpacing.dockInset,
        ),
        children: [
          SettingsRow(
            icon: Icons.person_outline,
            title: '账户管理',
            subtitle: '上海大学校园账户、各 OAuth 系统连接',
            onTap: () => context.go('/settings/account'),
          ),
          SettingsRow(
            icon: Icons.palette_outlined,
            title: '外观',
            subtitle: '主题风格、配色切换',
            onTap: () => context.go('/settings/appearance'),
          ),
          SettingsRow(
            icon: Icons.shield_moon_outlined,
            title: 'aTrust 协议',
            subtitle: '网关地址、登录域、隧道参数',
            onTap: () => context.go('/settings/protocol/atrust'),
          ),
          SettingsRow(
            icon: Icons.hub_outlined,
            title: 'EasyConnect 协议',
            subtitle: 'Easy Connect 隧道参数',
            onTap: () => context.go('/settings/protocol/easyconnect'),
          ),
          SettingsRow(
            icon: Icons.lock_open_outlined,
            title: 'OpenVPN 协议',
            subtitle: 'OpenVPN 隧道参数',
            onTap: () => context.go('/settings/protocol/openvpn'),
          ),
          SettingsRow(
            icon: Icons.alt_route,
            title: '网络连接',
            subtitle: 'HTTP 与 SOCKS5 代理、Android VPN 服务',
            onTap: () => context.go('/settings/connection'),
          ),
          SettingsRow(
            icon: Icons.science_outlined,
            title: '实验性选项',
            subtitle: '尚未稳定的行为，默认全部关闭',
            onTap: () => context.go('/settings/experimental'),
          ),
          // ⚠️ 「日志」与「关于」两行**故意不带副标题**，其余六行都带。
          //
          // 这不是遗漏。上面六行是「你还得改点什么」的地方，副标题写的是
          // 里面有几件事；最后这两行是「看一眼」的地方 —— 一个是流水，
          // 一个是版本与许可。用行高的差别把它们从前面那六行里分出来，
          // 比再加一道分隔线轻。
          SettingsRow(
            icon: Icons.article_outlined,
            title: '日志',
            onTap: () => context.go('/settings/log'),
          ),
          SettingsRow(
            icon: Icons.info_outline,
            title: '关于',
            onTap: () => context.go('/settings/about'),
          ),
        ],
      ),
    );
  }
}
