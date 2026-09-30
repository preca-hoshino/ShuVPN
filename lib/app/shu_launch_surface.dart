import 'package:flutter/material.dart';

import 'theme.dart';

/// 应用的第一屏：**底色 + 居中的图标**，没有文字、没有指示器。
///
/// 与 `ShuYo` 的 `ShuYoLaunchSurface` 同一形态。它只承担一件事 —— 把
/// 「应用已经起来了」这件事在 Flutter 引擎画第一帧的同时就说清楚。此前
/// 这一段是空白：`main()` 先把设置读完才 `runApp`，而那之前屏幕上只有
/// Android 的原生启动图（一块纯色）。
///
/// 图标**不旋转、不呼吸、不淡入**。启动通常只有几百毫秒，给这么短的一瞬
/// 加动效，用户看到的是一个跳动了一半的图形；静止的图标读起来是「在等」，
/// 动的图标读起来是「卡住了」。
///
/// 取色走当前主题的 [ShuYoColors]（调用方把它放进 `MaterialApp` 即可），
/// 所以浅色下是纸白底 + 蓝色图标、深色下是近黑底 + 白色图标，与 Android
/// 原生启动图那一对完全对得上 —— 中间不会有一下颜色突变。
class ShuLaunchSurface extends StatelessWidget {
  const ShuLaunchSurface({super.key});

  /// 图标边长（dp）。与原生那一份 `launch_background.xml` 里的 112dp 相同。
  static const double iconSize = 112;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    // `ColoredBox` 而不是 `Scaffold`：这一屏下面没有 `Navigator` 之外的东西
    // 需要它（没有 AppBar、没有 SnackBar 通道、也不该有 SafeArea 的上下留白
    // 变化），而 `Scaffold` 会额外铺一层 `Material` 与手势区。
    return ColoredBox(
      color: colors.background,
      child: Center(
        child: Image.asset(
          iconAssetFor(colors.brightness),
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          // 启动图标通常比 112dp 大得多（这里源图是 1024），缩小绘制的默认
          // 采样会让它发糊。这一档正是给「缩得很小的位图」准备的。
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }

  /// 该亮度用哪一张图。
  ///
  /// 浅色底用**蓝色**那一张（应用的主标识），深色底用**白色**那一张 ——
  /// 蓝色的对比度在近黑底上掉得厉害，而白色图标在纸白底上等于没有。
  ///
  /// 没有第三张：`assets/images/icon_clear_black.png` 是**不透明白底**上
  /// 的黑色图标，铺在纸白底上会露出一个白色方块，所以这里不用它。
  static String iconAssetFor(Brightness brightness) =>
      brightness == Brightness.dark
      ? 'assets/images/ic_launcher_white.png'
      : 'assets/images/icon_clear_blue.png';
}
