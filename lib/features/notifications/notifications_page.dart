import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_surfaces.dart';

/// 「通知」。
///
/// 目前**没有任何通知源** —— 这是个占位页，但占位的方式是有意的：
/// 它走的是正常的 `EmptyState`（空状态），而不是留白或「敬请期待」。
///
/// 区别在于用户的感受：一片空白会让人以为页面没加载出来；`EmptyState` 明确
/// 说「现在没有通知」，于是同一个页面在将来真的有通知时，什么都不用改 ——
/// 有内容就显示内容，没有就显示这句话。
///
/// 入口在一级页顶栏的左上角（[ShuAppBar.onNotifications]），与 `ShuYo` 的
/// `AppHeader` 一致。它不属于 dock 的三个目的地：通知是「偶尔来看一眼」的
/// 东西，不是「长期待在某处」的地方。
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ShuAppBar(title: '通知', onBack: () => Navigator.of(context).pop()),
      body: const Padding(
        padding: EdgeInsets.all(ShuSpacing.page),
        child: EmptyState(
          icon: Icons.notifications_none,
          title: '暂无通知',
          message: '会话失效、凭据过期这类事情会在这里提醒你。',
        ),
      ),
    );
  }
}
