import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_info.dart';
import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/shu_app_bar.dart';

/// 设置目录页最后一行进来的地方。
///
/// 应用的身份（名字、版本、来源）与许可证都在这里。**运行日志不在这一页**：
/// 它是排障时要看的一份流水，属于「应用怎么工作」，不属于「这个应用是什么」，
/// 所以它在设置目录页上有自己的一行。
///
/// 这一页把**只读信息**（应用名与版本、上游致谢）与**可点的入口**
/// （许可、仓库）混在一起，所以两者的区别得看得出来：名字与版本
/// 是顶部那块居中的字，上游致谢是一段小字，剩下的才是可点的行。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;

    return Scaffold(
      appBar: ShuAppBar(title: '关于', onBack: () => Navigator.of(context).pop()),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          ShuSpacing.page,
          8,
          ShuSpacing.page,
          ShuSpacing.page * 2,
        ),
        children: [
          const _AppIdentity(),
          const SizedBox(height: 24),

          SettingsRow(
            icon: Icons.description_outlined,
            title: '第三方开源许可',
            onTap: () => showLicensePage(
              context: context,
              applicationName: ShuAppInfo.name,
              applicationVersion: ShuAppInfo.versionLabel,
              applicationLegalese: ShuAppInfo.disclaimer,
            ),
          ),
          SettingsRow(
            icon: Icons.link,
            title: '项目仓库',
            value: ShuAppInfo.repository,
            onTap: () => _copy(context, ShuAppInfo.repository),
          ),

          const SizedBox(height: ShuSpacing.page),
          const _Credits(),

          const SizedBox(height: ShuSpacing.page),
          Text(
            ShuAppInfo.disclaimer,
            textAlign: TextAlign.center,
            style: ShuYoTextStyles.meta(color: colors.textMuted),
          ),
        ],
      ),
    );
  }

  /// Links are copied instead of opened: opening them would mean adding a
  /// browser dependency for one row of text.
  static void _copy(BuildContext context, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制链接到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}

/// 顶部的应用身份块：图标 + 名字 + 版本。
///
/// 它回答「这是什么应用」，所以放在第一眼的位置。三个字段都是**只读**的，
/// 排成一列居中而不是做成行 —— 做成行会跟下面那些可点的入口长得一样。
class _AppIdentity extends StatelessWidget {
  const _AppIdentity();

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: colors.accentSoft,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(Icons.shield, size: 40, color: colors.onAccentSoft),
        ),
        const SizedBox(height: 12),
        Text(
          ShuAppInfo.name,
          style: ShuYoTextStyles.pageTitle(color: colors.textPrimary),
        ),
        const SizedBox(height: 2),
        Text(
          '版本 ${ShuAppInfo.versionLabel}',
          style: ShuYoTextStyles.meta(color: colors.textTertiary),
        ),
        const SizedBox(height: 14),
        Text(
          '${ShuAppInfo.tagline}。'
          '通过 Sangfor 协议核心建立隧道，并在本地提供 HTTP 与 SOCKS5 转发。',
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// 上游与致谢。
///
/// 这一块是**纯信息**，没有任何可点的东西，所以没有做成设置行 ——
/// 四个项目各自一行平铺开会让这一页看起来有五分之四都是别人的名字。
/// 压成一段小字，需要的人自己看，不需要的人也能直接划过去。
///
/// 也**不套卡片**：这一页从上到下都是裸列表，突然冒出一个圆角容器会让它
/// 看起来像可以拿起来的东西。
class _Credits extends StatelessWidget {
  const _Credits();

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '上游与致谢',
            style: ShuYoTextStyles.label(
              color: colors.textTertiary,
              size: 13,
            ).copyWith(letterSpacing: 0.6),
          ),
          const SizedBox(height: 8),
          Text(
            'zju-connect · EasierConnect · NJUConnect · shu-sso-poc',
            style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            '这些公开实现让协议核心可以被验证，特此致谢。'
            '统一身份认证由上海大学提供，本应用只做协议对接。',
            style: ShuYoTextStyles.meta(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
