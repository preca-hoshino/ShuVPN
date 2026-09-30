import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_surfaces.dart';

/// Left-hand dock destination.
///
/// Deliberately a placeholder: the intent is to list the resources this VPN
/// exposes, but the shape of that catalogue is not decided yet, so the page
/// ships a real empty state instead of a dead button.
class ServicesPage extends StatelessWidget {
  const ServicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ShuAppBar(
        title: '服务',
        onNotifications: () => context.push('/notifications'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          ShuSpacing.page,
          ShuSpacing.page,
          ShuSpacing.page,
          ShuSpacing.dockInset,
        ),
        children: const [
          EmptyState(
            icon: Icons.apps_outlined,
            title: '还没有服务列表',
            message: '这里将展示 VPN 提供的服务与资源目录。\n在接入资源目录之前保持为空。',
          ),
        ],
      ),
    );
  }
}
