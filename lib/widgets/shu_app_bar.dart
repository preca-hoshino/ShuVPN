import 'package:flutter/material.dart';

import '../app/shuyo_text_styles.dart';
import '../app/theme.dart';

/// 全应用共用的顶栏。
///
/// **排版以「账户管理」那一页为准** —— 那一页是这类页面的原型：一条固定高度的
/// 栏，左边给返回键，标题紧挨着它、左对齐，垂直居中；**标题不居中**。
///
/// 之所以要抽出来，是因为在这之前顶栏有两套，而且**对不齐**：
///
/// | 用在哪 | 实现 | 标题字号 | 高度 | 标题左边界 |
/// | :--- | :--- | :--- | :--- | :--- |
/// | 服务 / 连接 / 设置（dock 目的地） | `ShuPageHeader`（放在 `ListView` 里） | 19 | 不固定 | 16 |
/// | 各二级页 | `AppBar` | 17.5 | 56 | 64 |
///
/// 从设置页点进「外观」，标题会**横跳 48 像素**、字号也换一档 —— 那种感觉
/// 就像换了一个应用。现在两边都走这个 widget，高度、字号、左边界全一致。
///
/// 根页的顶栏也**钉住了**：以前 `ShuPageHeader` 是列表的第一项，滚一下就跟着
/// 走。钉住之后标题始终在同一个位置，代价是首屏少 [toolbarHeight] 的高度
/// （各页的滚动内容已经相应地把上边距调小了）。
class ShuAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ShuAppBar({
    super.key,
    required this.title,
    this.onBack,
    this.backEnabled = true,
    this.onNotifications,
    this.actions,
    this.backTooltip = '返回',
  });

  /// 栏高。与 Material 的 `AppBar` 默认值相同，所以替换前后**垂直方向
  /// 没有位移** —— 各个页面已经按这个高度调过间距了。
  ///
  /// ⚠️ 这 64 是**不含状态栏**的：`Scaffold` 另外把 `MediaQuery.padding.top`
  /// 加到给顶栏的高度预算里（`scaffold.dart` 的
  /// `_appBarMaxHeight = preferredHeightFor(...) + topPadding`）。所以这里
  /// **绝不能**再把状态栏高度从 64 里面扣掉，见 [build] 里 `SafeArea` 的位置。
  static const double toolbarHeight = 64;

  /// 标题的起始位置，也是左侧图标的槽宽。
  ///
  /// 取 56 是为了**与 Material 的 `AppBar` 逐像素对齐** —— 账户页原本就是
  /// 用 `AppBar` 的，这里要做的就是让其余各页看起来和它一样。而且这个槽位
  /// **无论放不放东西都占满**：有返回键时它装按键，没有时装一个空盒子。
  /// 否则根页的标题会落在 16、二级页落在 56，来回点几次就能看出标题在跳。
  static const double _leadingWidth = 56;

  final String title;

  /// 返回键的回调。为 null 时不画返回键，标题也就跟着左移到页边距上。
  ///
  /// 是回调而不是 `bool`：这一栏不管自己是从哪一层被推上来的，
  /// 只负责把「用户想回去」这件事交回给页面。账户页要用它先退回登录表单的
  /// 第一步（`_back`），而不是直接弹栈。
  ///
  /// ⚠️ **只要这一页是被推上来的，就一定要传**。曾经账户页在概览状态下传了
  /// `null`（以为「没有子步骤就不用返回」），结果是那一页左上空空如也、
  /// 只能靠系统手势退出 —— 用户反馈的「二级页缺少返回箭头」就是它。
  final VoidCallback? onBack;

  /// 返回键是否可点。用于「看得见但现在不能走」的情况（例如登录请求进行中）：
  /// 它让箭头**变灰留在原位**，而不是整颗消失。整颗消失会让人以为页面变了。
  final bool backEnabled;

  /// 通知入口。非 null 时在**左槽**显示（一级页用它，没有返回键，槽位正好空着）。
  final VoidCallback? onNotifications;

  final String? backTooltip;

  /// 右侧动作区。现在各页都是空的，但槽位留在这里 ——
  /// 以后要在某一页加个「刷新」之类的入口时，不必再回来改这个 widget。
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;

    // ⚠️ `SafeArea` 必须在 `SizedBox` **外面**。
    //
    // 反过来写（`SafeArea` 在外、固定高度在内）会把状态栏高度从这 64 里面
    // 吃掉，`Row` 只剩 64-48=16，48×48 的返回键装不下就被裁掉 ——
    // 这正是「二级页没有返回箭头」的成因。Material 的 `AppBar` 也是这么
    // 排的（`app_bar.dart`：先定高，再 `SafeArea(bottom: false, child: ...)`）。
    final bar = SizedBox(
      height: toolbarHeight,
      child: Row(
        children: [
          // 左槽：有返回键时装返回键，否则装通知（一级页），都没有就留空。
          SizedBox(
            width: _leadingWidth,
            child: switch ((onBack, onNotifications)) {
              (final VoidCallback back, _) => IconButton(
                tooltip: backTooltip,
                onPressed: backEnabled ? back : null,
                icon: const Icon(Icons.arrow_back),
              ),
              (null, final VoidCallback notify) => IconButton(
                tooltip: '通知',
                onPressed: notify,
                icon: const Icon(Icons.notifications_none),
              ),
              _ => null,
            },
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // 字号取 `headerTitle`(17.5/w600)：它本来就是这套 token 里
                // 「栏标题」的那一档，此前只有 `AppBar` 在用，现在两边统一。
                style: ShuYoTextStyles.headerTitle(color: colors.textPrimary),
              ),
            ),
          ),
          ...?actions,
          // 右侧没有动作时补一格，让标题的可用宽度在有无动作的情况下一致 ——
          // 否则标题会在加动作的那一页突然被挤窄。
          if (actions == null || actions!.isEmpty)
            const SizedBox(width: ShuSpacing.page),
        ],
      ),
    );

    return SafeArea(bottom: false, child: bar);
  }
}
