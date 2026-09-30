import 'package:flutter/material.dart';

/// 二级页的转场：**从右侧滑入，沿原路收回**。
///
/// 形态取自 Material 3 的 **shared axis X**（横向共享轴）：新页从屏幕右侧整屏
/// 宽处滑到原位，已经在栈里的那一页往左让出四分之一屏 —— 让位这一步是这套转场
/// 与「单纯 `SlideTransition`」的全部差别：只有新页在动时，用户看到的是「一张
/// 纸盖上来」；两页一起动，看到的才是「一叠纸往左翻过去」。后退时两个动画同时
/// 倒放，所以「收回」与「进来」是同一条路径的往返。
///
/// 位移本身写在 [_ShuSharedAxisXSlide] 里，**页内换页用的是同一份**
/// （[ShuSharedAxisXSwitcher]）—— 同一个动作在两处必须逐帧一样。
///
/// 时长不由这里决定：`PageTransitionsTheme` 只给形状，时长跟着路由走
/// （`MaterialPageRoute` 的 300ms，正好是 MD3 里 shared axis 那一档）。
///
/// ⚠️ **光装上它不够。** 主题里配好之后，还要求路由真的走到
/// `MaterialRouteTransitionMixin.buildTransitions` 上去 —— 而 go_router 默认
/// 不会：它按「树里有没有 `MaterialApp`」猜页类型，猜错就用 `NoTransitionPage`，
/// 这个 builder 一次都跑不到。所以 `router.dart` 里每条被推上来的路由都显式
/// 给了 `MaterialPage`（见那边的 `_subPage`），两处要一起看。
///
/// ⚠️ 这里**不裁切**（没有 `ClipRect`）：滑出去的页面有一部分在屏幕外，
/// 裁一刀要多一次合成，而 `Scaffold` 自己已经把它裁在可视区里了。
class ShuSharedAxisXPageTransitionsBuilder extends PageTransitionsBuilder {
  const ShuSharedAxisXPageTransitionsBuilder();

  /// 新页的起点：右边一整屏宽。
  static const Offset enterFrom = Offset(1, 0);

  /// 旧页的让位终点。
  ///
  /// 0.25 是 MD3 给「次要元素」的位移量 —— 它要足够看出来「在让位」，又要
  /// 小到下一页滑完之后，下面那一页的标题仍然停在原来的位置上可辨认。
  static const Offset recedeTo = Offset(-0.25, 0);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 第一页是 dock 外壳（`StatefulShellRoute` 那一层），它**一直**在栈底；让它
    // 跟着往左退，等于每次开设置都推着整个 Shell 动一下，而 Shell 上并没有
    // 「被压在下面」的语义 —— 它更像一块背景板。于是这套转场的实际观感是：
    // 底下的 Shell 不动，每一张二级页从右侧抽出来、按原路收回去。
    if (route.isFirst) return child;

    // 两个进度各推一格：`animation` 是**这一页**自己在进来的进度，
    // `secondaryAnimation` 是它上面那页压过来的进度（没人在上面时恒为 0）。
    // 所以同一份位移既说了「我进来」，也说了「我被压着往左退」。
    return _ShuSharedAxisXSlide(
      enter: _eased(animation),
      recede: _eased(secondaryAnimation),
      child: child,
    );
  }
}

/// 全平台共用的那套转场。
///
/// 为什么不挑平台：iOS 默认的 `CupertinoPageTransitionsBuilder` 会带上边缘
/// 返回手势与横幅阴影，而这个应用只有一个形态（dock 三页 + 二级页），
/// 两套转场并存只会让「同为二级页」的两条路看起来不是一个应用。
Map<TargetPlatform, PageTransitionsBuilder> shuPageTransitionsBuilders() => {
  for (final platform in TargetPlatform.values)
    platform: const ShuSharedAxisXPageTransitionsBuilder(),
};

/// **页内**换页：同一页里两块内容之间的 shared axis X。形状与
/// [ShuSharedAxisXPageTransitionsBuilder] 完全相同（真正共用
/// [_ShuSharedAxisXSlide]），只是它换的是同一页里的两块内容而不是两条路由 ——
/// 账户管理的「概览 ⇄ 登录表单」、引导页的「三页 ⇄ 登录表单」都是它。
///
/// 那些地方**不能**用路由：登录表单要复用同一个 `GlobalKey`（宿主靠它读
/// `busy` / `step`、调 `reset`），推成一条路由就等于让同一个 key 出现在两条
/// 路由上。
///
/// ## 两块内容一直都在树上
///
/// 这是它与 `AnimatedSwitcher` 的根本区别。`AnimatedSwitcher` 会把**旧的那一份
/// 留在树上**直到动画跑完，于是「退回去、又在 300ms 之内再点进来」这条路上，
/// 同一棵树里会同时出现两个带同一个 `GlobalKey` 的表单 —— 直接崩，而且崩在概率
/// 极低的路径上，常规测试测不出来。这里换页只改两块的位置，不改它们的存亡。
///
/// 代价是两块都不能带着「只在被看见时才对」的状态：靠挂载 / 卸载顺带做的事
/// （比如收键盘）得自己做，见 `AccountPage._setSigningIn`。
///
/// ## 三处必须这么写
///
/// * **底色**：两块都包一层 [Material]（页面底色）。上面那块滑进来时，下面那块
///   在缝隙里还看得见，而这两块内容自己是透明的列表，不铺底色就会互相透出来
///   （路由之间没这个问题：每一页都有自己的 `Scaffold`）。
///   ⚠️ 别用 `ColoredBox` —— `ListTile` 的水波纹画在最近的 `Material` 上，中间
///   插一层 `ColoredBox` 会被它盖住，框架直接就断言报错。
/// * **藏起来那一块**：`Visibility(maintainState: true)` —— 它退化成 [Offstage]，
///   于是不画、不响应点击、**finder 也跳过**（`debugVisitOnstageChildren`），
///   「登录表单已经退场」这类断言才不会被藏起来的那份骗过去。
///   ⚠️ 别加 `maintainSize: true`：那条走 `_Visibility` 分支、不再退化成
///   [Offstage]，藏起来的那块照样会被 finder 找出来。
/// * **布局**：[Offstage] 仍会照原样 layout 子节点（只把自己的尺寸报成
///   `constraints.smallest`），而 `Stack(fit: expand)` 给的正是紧约束、两者相等。
///   所以换回来时不会先闪一帧没排好版的画面。
class ShuSharedAxisXSwitcher extends StatefulWidget {
  const ShuSharedAxisXSwitcher({
    super.key,
    required this.showFront,
    required this.front,
    required this.back,
  });

  /// 是不是已经切到 [front] 了。
  final bool showFront;

  /// [showFront] 为真时完全就位的那一块。它从右侧滑进来。
  final Widget front;

  /// 原来那一块。它退到 [ShuSharedAxisXPageTransitionsBuilder.recedeTo]。
  final Widget back;

  @override
  State<ShuSharedAxisXSwitcher> createState() => _ShuSharedAxisXSwitcherState();
}

class _ShuSharedAxisXSwitcherState extends State<ShuSharedAxisXSwitcher>
    with SingleTickerProviderStateMixin {
  /// 300ms，与 `MaterialPageRoute` 同档 —— 二级页的转场就是这个数，两处才是
  /// 同一套动作。不取 `ShuMotion` 那一档：那是**零件**级动作的时长（按下、切
  /// tab），而这是「换一整页」。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.showFront ? 1 : 0,
  );

  late final CurvedAnimation _progress = _eased(_controller);

  @override
  void didUpdateWidget(ShuSharedAxisXSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 控制器归这块自己管：宿主只报「现在是哪一块在前面」，不必持有 controller、
    // 也不必为 `TickerProviderStateMixin` 多承一份所有权。
    if (widget.showFront == oldWidget.showFront) return;
    // 两个方向都从**当前值**接着走（`forward` / `reverse` 不会先跳到端点），
    // 所以动画没跑完就掉头时位置是连续的。
    if (widget.showFront) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 两块底下铺的是同一个颜色，换页过程中也不会变，取一次就够。
    final background = Theme.of(context).scaffoldBackgroundColor;
    return AnimatedBuilder(
      animation: _progress,
      // `AnimatedBuilder` 的 `child` 参数这里用不上（有两块），但**不必**担心
      // 每帧重建它们：`front` / `back` 是宿主 `build` 里造好的同一个 widget
      // 实例，`updateChild` 见到同一个实例就直接短路。
      builder: (context, _) {
        final t = _progress.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 下面那块：让出去。整块让完之后就不再画它了（连 finder 都找不到，
            // 理由见类文档）。它自己不动，所以进来的进度钉在 1。
            Visibility(
              visible: t < 1,
              maintainState: true,
              child: _ShuSharedAxisXSlide(
                enter: kAlwaysCompleteAnimation,
                recede: _progress,
                child: Material(color: background, child: widget.back),
              ),
            ),
            // 上面那块：滑进来。它没有在让位，所以让位的进度钉在 0。
            //
            // 摆在后面是因为滑进来时它是**盖**在旧的那块上的，与二级页推入的
            // 观感一致（而不是两块各画一半）。
            Visibility(
              visible: t > 0,
              maintainState: true,
              child: _ShuSharedAxisXSlide(
                enter: _progress,
                recede: kAlwaysDismissedAnimation,
                child: Material(color: background, child: widget.front),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// shared axis X 的位移：**新的一块从右侧滑进来，旧的一块往左让出四分之一屏**。
///
/// 两个进度各推一格，来源不同 —— 二级页之间由路由的 `animation` /
/// `secondaryAnimation` 推，页内换页由一个 controller 推（另一边配常量动画：
/// 没在让位的那块把让位进度钉在 [kAlwaysDismissedAnimation]，没在进来的那块把
/// 进来进度钉在 [kAlwaysCompleteAnimation]）。
///
/// 形状只在这一个地方写。传进来的进度**要先过 [_eased]** —— 本类不上曲线
/// （常量动画那两端不必，0 与 1 本来就不受曲线影响）。
class _ShuSharedAxisXSlide extends StatelessWidget {
  const _ShuSharedAxisXSlide({
    required this.enter,
    required this.recede,
    required this.child,
  });

  /// 进来的进度：0 = 还在右边一整屏处，1 = 就位。
  final Animation<double> enter;

  /// 让出去的进度：0 = 就位，1 = 退到
  /// [ShuSharedAxisXPageTransitionsBuilder.recedeTo]。
  final Animation<double> recede;

  final Widget child;

  @override
  Widget build(BuildContext context) => SlideTransition(
    position: Tween<Offset>(
      begin: Offset.zero,
      end: ShuSharedAxisXPageTransitionsBuilder.recedeTo,
    ).animate(recede),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: ShuSharedAxisXPageTransitionsBuilder.enterFrom,
        end: Offset.zero,
      ).animate(enter),
      // `SlideTransition` 底下是 `RenderFractionalTranslation`：它只改绘制偏移、
      // 不建图层，所以缺了这道边界的话，每一帧都要把整块内容重新录制一遍。
      // 有了它，录好的那一层直接复用，只做重新合成。
      child: RepaintBoundary(child: child),
    ),
  );
}

/// 转场的那一对曲线：`easeOutCubic` 进、`easeInCubic` 出。
///
/// 前进是「快起慢停」—— 内容先到位、手再松开；后退则反过来。
///
/// `CurvedAnimation` 是唯一一个能按方向换曲线的内置动画，代价是它会给 parent
/// 挂一个状态监听、要由调用方释放（见 [CurvedAnimation.dispose]）。所以：
/// 短命的那两处（路由的 `buildTransitions`，每次重建都要一份新的）用完就扔 ——
/// 与 Flutter 自带的 `FadeUpwardsPageTransitionsBuilder` 是同一个写法；长命的
/// 那一处（[ShuSharedAxisXSwitcher]）存在字段里，在 `dispose` 释放。
CurvedAnimation _eased(Animation<double> parent) => CurvedAnimation(
  parent: parent,
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);
