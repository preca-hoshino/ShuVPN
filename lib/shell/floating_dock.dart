import 'package:flutter/material.dart';

import '../app/theme.dart';

/// The three top-level destinations, in dock order.
///
/// 「连接」那一栏用地球（`Icons.language`）而不是盾牌：盾牌已经是大圆按钮
/// 「已连接」那一态的图标（见 `theme.dart` 的 `connectionStateStyle`），
/// 两处同一个字形会让「底栏这一项」与「隧道现在通不通」看起来是同一件事。
/// 地球说的是这一项本身 —— 从这里连出去。
enum ShuTab {
  services('服务', Icons.apps_outlined, Icons.apps),
  connect('连接', Icons.language_outlined, Icons.language),
  settings('设置', Icons.settings_outlined, Icons.settings);

  const ShuTab(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 贴底的导航栏。
///
/// 它原本是悬浮胶囊（左右留边、大圆角、毛玻璃、下坠阴影）。现在改成与
/// `ShuYo` 的 `BottomNavigationBar` 和用户提供的参考图一样的形态：
///
/// * **全宽贴底**，左右下都不留边，但顶部保留一条细分隔线把栏与内容分开；
/// * **实心**背景（`colors.background`），不再毛玻璃；
/// * **没有阴影** —— 悬浮时的 `boxShadow` 在点击时会被水波纹衬得像是多出来
///   一层；贴底之后它也没有存在的理由了（已无东西可借）；
/// * 选中项是一颗淡色胶囊（[ShuYoColors.accentSoft]），Expressive 的颜色方向。
///
/// ⚠️ 栏里**不再有连接状态圆点**。那个小圆点是这个应用曾经的特色（从任何
/// 一页扫一眼底栏就知道隧道通不通），但它与「贴底实心」这套视觉不相容 ——
/// 一个漂浮的彩色小点需要一层轻一点的背景来衬。现在要看状态就回连接页，
/// 那里的球本身就是最大的指示灯。
class FloatingDock extends StatelessWidget {
  const FloatingDock({
    super.key,
    required this.currentIndex,
    required this.onSelect,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;

    return Material(
      color: colors.background,
      // 不用阴影，也不用 `surfaceTint` —— 实心贴底的栏与页面是同一层，
      // 抬起一层反而会把内容与导航的关系说反。
      elevation: 0,
      child: DecoratedBox(
        // 用一条 1px 的顶边而不是 `Divider`：`Divider` 会吃额外的纵向空间，
        // 而这个栏的高度是算好的。
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: ShuSpacing.dockHeight,
            child: Row(
              children: [
                for (final tab in ShuTab.values)
                  Expanded(
                    child: _DockItem(
                      tab: tab,
                      selected: tab.index == currentIndex,
                      onTap: () => onSelect(tab.index),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatefulWidget {
  const _DockItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final ShuTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<_DockItem> {
  /// 指示器胶囊的**固定**锚点。
  ///
  /// 它不参与绘制（是个空盒子），只用来把点击的水波纹锁到 64×32 那一块上。
  /// 之所以不复用会动画的那个 `AnimatedContainer`：未选中时它的宽度是 0，
  /// 拿它算出来的矩形也是 0 宽，水波纹就整个看不见了。
  final _indicatorAnchor = GlobalKey();

  /// 指示器尺寸。与 Material 的 `NavigationBar` 一致（`_kIndicatorWidth` /
  /// `_kIndicatorHeight`），所以这颗胶囊和系统组件是同一种东西。
  static const _indicatorSize = Size(64, 32);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = context.shuyoColors;
    final selected = widget.selected;
    // At very large text scales the label would push the icon out of the fixed
    // dock height, so it drops out and the icon carries the meaning alone.
    final showLabel = MediaQuery.textScalerOf(context).scale(1) < 1.5;

    // 选中时图标换实心、字号不动 —— Expressive 用颜色与胶囊表达选中，
    // 不再靠「放大的图标」（那会把旁边两项挤开，栏会跟着抖）。
    final icon = Icon(
      selected ? widget.tab.selectedIcon : widget.tab.icon,
      size: 22,
      color: selected ? colors.onAccentSoft : scheme.onSurfaceVariant,
    );

    // 指示器的胶囊：贴紧图标（只包图标，高 32），文案在下面。
    // 这是旧规范与 Expressive 之间的取中 —— 三项的栏里把标签也塞进胶囊，
    // 每颗胶囊会宽到互相贴住，反而看不出是一颗一颗的。
    final indicator = AnimatedContainer(
      duration: ShuMotion.base,
      curve: ShuMotion.curve,
      height: _indicatorSize.height,
      width: selected ? _indicatorSize.width : 0,
      decoration: BoxDecoration(
        color: selected ? colors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(ShuRadii.pill),
      ),
    );

    return Semantics(
      selected: selected,
      button: true,
      label: widget.tab.label,
      child: Material(
        type: MaterialType.transparency,
        child: _IndicatorInkResponse(
          anchorKey: _indicatorAnchor,
          onTap: widget.onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    key: _indicatorAnchor,
                    width: _indicatorSize.width,
                    height: _indicatorSize.height,
                  ),
                  indicator,
                  icon,
                ],
              ),
              if (showLabel) ...[
                const SizedBox(height: 2),
                Text(
                  widget.tab.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: selected ? colors.accent : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 把水波纹锁在指示器胶囊里的 [InkResponse]。
///
/// 为什么不能只用构造参数：`getRectCallback` **不是** `InkResponse` 的构造
/// 参数，它是一个可覆写的方法。所以这里必须派生一个类 —— Material 的
/// `NavigationBar` 也是这么做的（它的 `_IndicatorInkWell extends InkResponse`
/// override 了同一个方法，把矩形对到图标的 `GlobalKey` 上）。
///
/// 三个开关各管一件事：
///
/// * `containedInkWell` —— 水波纹被 `customBorder` 裁掉，不再铺满整格；
/// * `highlightColor: transparent` —— 去掉按下时那层 12% 的整块浮面，
///   它就是被看成「多出来的椭圆阴影」的东西；
/// * `getRectCallback` —— 连水波纹的**起点矩形**也收成 64×32。
///
/// 三者缺一：只做前两条，水波纹仍然是一颗横躺的大椭圆；只做第三条，
/// 按下时那一整块浮面还在。
class _IndicatorInkResponse extends InkResponse {
  const _IndicatorInkResponse({
    required this.anchorKey,
    super.onTap,
    super.child,
  }) : super(
         containedInkWell: true,
         highlightColor: Colors.transparent,
         customBorder: const StadiumBorder(),
       );

  /// 指示器胶囊的位置来源。
  final GlobalKey anchorKey;

  @override
  RectCallback? getRectCallback(RenderBox referenceBox) {
    final box = anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return () => referenceBox.globalToLocal(rect.topLeft) & box.size;
  }
}
