import 'package:flutter/material.dart';

import '../app/shuyo_text_styles.dart';
import '../app/theme.dart';

/// Solid rounded container used for grouped content.
///
/// Built on [Material] rather than a decorated box so the [ListTile]s inside a
/// settings group can paint their ink.
class ShuCard extends StatelessWidget {
  const ShuCard({super.key, required this.child, this.padding, this.color});

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Material(
      color: color ?? colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShuRadii.card),
        side: BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(ShuSpacing.page),
        child: child,
      ),
    );
  }
}

/// 全应用共用的「说一句话就走」的通道。
///
/// 就是 Material 的 `SnackBar` —— 从底部浮出来的一条长条，会自己排队、
/// 会在几秒后自己退场、会避开手势条。不自己画一个的原因是：自绘的那些
/// 要么盖在底栏上、要么被手势条裁掉半截，而这三件事 `SnackBar` 都已经
/// 处理过了。
///
/// `hideCurrentSnackBar` 是必须的：连点两下按钮时，后一条会排在前面那条
/// 后面等着，用户会觉得「点了没反应」。先撤掉再去重的做法在这里更顺手。
void showShuSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
}

/// Small label that opens a group of settings.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, ShuSpacing.page, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: ShuYoTextStyles.label(
                color: colors.textTertiary,
                size: 13,
              ).copyWith(letterSpacing: 0.6),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 一行右侧的**状态槽**。
///
/// 全应用只有两种「右边会写一句话」的行：账号管理里那几行凭据状态，
/// 以及网络连接里的系统授权状态。两页共用这一个组件，所以「已连接」
/// 「未授权」这些词在两边是**同一种视觉处理**：右对齐、小字、语义色。
///
/// 宽度固定而不是自适应：几行文字长度不同（`已连接` 三字、`正在获取…`
/// 五字），自适应会让每行的起点都不一样，右对齐就白做了。
///
/// 单独一行用（网络连接页那种）时固定宽度不带来任何好处，但也无害 ——
/// 为了「一个组件」这件事，值。
class ShuStatusSlot extends StatelessWidget {
  const ShuStatusSlot({super.key, required this.text, required this.color});

  /// 状态槽的固定宽度。按最长的那句留，并允许换行。
  static const width = 118.0;

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: TextAlign.right,
        style: ShuYoTextStyles.meta(color: color),
      ),
    );
  }
}

/// Neutral placeholder for a feature that has no data yet.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return ShuCard(
      padding: const EdgeInsets.symmetric(
        horizontal: ShuSpacing.page,
        vertical: 32,
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: colors.textMuted),
          const SizedBox(height: 12),
          Text(
            title,
            style: ShuYoTextStyles.title(color: colors.textPrimary, size: 15.5),
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: ShuYoTextStyles.meta(color: colors.textTertiary),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
