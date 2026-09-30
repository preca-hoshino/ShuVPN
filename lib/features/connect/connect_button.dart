import 'package:flutter/material.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';

/// 连接页上那颗**圆形按钮**。
///
/// 它是 Material 3 的做法，而不是把 `FloatingActionButton` 换一套配色 ——
/// 两者的差别不在于长得多圆，而在于**颜色从哪来**：
///
/// * FAB 的 `backgroundColor` 是「品牌色」，一个不随状态变的值；
/// * M3 的状态型圆形按钮取的是一对 **container / onContainer** 角色，
///   两者由 `ColorScheme` 保证对比度，所以「已连接」换成「失败」时只是换了
///   一对角色，前景与底色始终是自己配好的。
///
/// 形状、按下反馈、以及那条不确定进度环的取舍也都按同一标准：
///
/// * `CircleBorder` —— M3 的圆形按钮就是正圆，不做「大圆角方块」；
/// * 海拔保持 0，只用一圈 1px 的 `outlineVariant` 描边 —— 页面上只有它
///   一个元素，抬起来反而像浮在别的什么东西上面；
/// * 按下是 `InkResponse(containedInkWell: true)` 并把 `highlightColor` 设成
///   透明：水波纹被裁在圆里，不会在圆外扩出一圈方形浮面。
class ConnectButton extends StatelessWidget {
  const ConnectButton({
    super.key,
    required this.style,
    required this.diameter,
    this.onTap,
  });

  final ConnectionStateStyle style;

  /// 正圆直径。由页面按可用空间算好传进来 ——
  /// 组件自己不去读 `MediaQuery`，否则同一颗按钮在竖屏与横屏上会有两套
  /// 内在逻辑，而这是页面的职责。
  final double diameter;

  /// 为 null 时按不动（请求进行中）。
  ///
  /// ⚠️ 颜色**不跟着变**。禁用态在别处意味着「灰掉、说明还不能用」，
  /// 而这里正在进行中的那一步本身就是最清楚的反馈 —— 把它一并褪色，
  /// 会让「正在连接」看起来像「连接坏了」。
  final VoidCallback? onTap;

  /// 进度环比正圆大出来的那几像素。给描边留位，不让它压在圆边上。
  static const double _ringInset = 6;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 降低动效时不画进度环：`CircularProgressIndicator` 的不确定态是永动机，
    // 只在「正在连接」这一类状态下出现，而那个状态下面的文字已经说清楚了。
    // （顺带一个好处：widget 测试里的 `pumpAndSettle` 不会被它绊住。）
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final showRing = style.isAnimated && !reduceMotion;

    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: diameter * 0.11),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(style.icon, size: diameter * 0.26, color: style.onContainer),
          SizedBox(height: diameter * 0.055),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              style.label,
              maxLines: 1,
              style: ShuYoTextStyles.title(
                color: style.onContainer,
                size: 17,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: '连接状态：${style.label}',
      hint: onTap != null ? '双击切换连接' : null,
      child: SizedBox(
        width: diameter + _ringInset * 2,
        height: diameter + _ringInset * 2,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (showRing)
              SizedBox.square(
                dimension: diameter + _ringInset,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  // 环用 [ConnectionStateStyle.color] 而不是**容器色**：
                  // 后者是刷在圆里面的那种浅底，直接画到页面背景上会淡到看不见
                  // （浅色主题的 `primaryContainer` 与背景的明度几乎一样）。
                  // `color` 这个字段存在的意义就是「画在背景上」，环正是它。
                  color: style.color,
                  backgroundColor: style.color.withValues(alpha: 0.18),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: style.container,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: SizedBox.square(
                dimension: diameter,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkResponse(
                    onTap: onTap,
                    containedInkWell: true,
                    highlightColor: Colors.transparent,
                    customBorder: const CircleBorder(),
                    child: content,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
