import 'package:flutter/material.dart';

import '../app/shuyo_text_styles.dart';
import '../app/theme.dart';
import '../core/auth/auth_constants.dart';

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

/// 把水波纹锁在一颗指示器胶囊里的 [InkResponse]。
///
/// 两处共用：底栏的每一项，以及连接页抽屉里那一排协议按钮 —— 它们的选中
/// 态都是「图标底下垫一颗胶囊」，所以点下去的反馈也该是同一颗胶囊，而不是
/// 一整格矩形。自己画一遍必然走样，所以只留这一份。
///
/// ## 为什么不能只用构造参数
///
/// `getRectCallback` **不是** `InkResponse` 的构造参数，它是一个可覆写的
/// 方法。所以这里必须派生一个类 —— Material 的 `NavigationBar` 也是这么做
/// 的（它的 `_IndicatorInkWell extends InkResponse` override 了同一个方法，
/// 把矩形对到图标的 `GlobalKey` 上）。
///
/// 三个开关各管一件事：
///
/// * `containedInkWell` —— 水波纹被 `customBorder` 裁掉，不再铺满整格；
/// * `highlightColor: transparent` —— 去掉按下时那层 12% 的整块浮面，
///   它就是被看成「多出来的椭圆阴影」的东西；
/// * `getRectCallback` —— 连水波纹的**起点矩形**也收成胶囊那一块。
///
/// 三者缺一：只做前两条，水波纹仍然是一颗横躺的大椭圆；只做第三条，
/// 按下时那一整块浮面还在。
class ShuIndicatorInkResponse extends InkResponse {
  const ShuIndicatorInkResponse({
    super.key,
    required this.anchorKey,
    super.onTap,
    super.child,
  }) : super(
         containedInkWell: true,
         highlightColor: Colors.transparent,
         customBorder: const StadiumBorder(),
       );

  /// 胶囊那一块的位置来源 —— 调用方把它垫在图标底下（尺寸决定胶囊大小）。
  final GlobalKey anchorKey;

  @override
  RectCallback? getRectCallback(RenderBox referenceBox) {
    final box = anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return () => referenceBox.globalToLocal(rect.topLeft) & box.size;
  }
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

/// 一个业务系统在列表里的一行：图标 + 系统名 + 域名。
///
/// 两处共用这一行 —— 账户管理的凭据行（右侧挂 [ShuStatusSlot] 报「连上没有」）
/// 与引导页第 3 页的系统清单（右侧留空：用户还没登录，没有状态可报）。
///
/// 共用的理由不是省几行代码，而是**同一件事只有一种说法**：系统的名字、
/// 图标、域名在哪儿都一样，用户在看到「aTrust 网关」时不用分辨这是两回事。
///
/// 图标**不染色**。颜色留给状态文字（[ShuStatusSlot]），图标保留它自己的
/// 语义 —— 一个染成蓝色的盾牌同时说了两件事，色盲用户还读不出区别。
class ShuSystemTile extends StatelessWidget {
  const ShuSystemTile({super.key, required this.kind, this.trailing});

  final ShuOAuthTargetKind kind;

  /// 右侧那一格。账号管理放状态槽，引导页不传。
  final Widget? trailing;

  /// 行首图标。
  ///
  /// 写在 widget 层而不是给枚举加字段：`core/` 不依赖 `flutter/material`，
  /// 而 `IconData` 是 material 的东西。三行 `switch` 换掉一层跨层依赖，值。
  static IconData iconFor(ShuOAuthTargetKind kind) => switch (kind) {
    ShuOAuthTargetKind.atrust => Icons.shield_moon_outlined,
    ShuOAuthTargetKind.otp => Icons.pin_outlined,
    ShuOAuthTargetKind.jwxt => Icons.calendar_month_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return ListTile(
      leading: Icon(iconFor(kind)),
      title: Text(
        kind.displayName,
        style: ShuYoTextStyles.bodyCompact(color: colors.textPrimary),
      ),
      subtitle: Text(
        kind.host,
        style: ShuYoTextStyles.meta(color: colors.textTertiary),
      ),
      // 图标相对**两行文字**居中；默认的 `threeLine` 会把它按标题行顶高。
      titleAlignment: ListTileTitleAlignment.center,
      trailing: trailing,
    );
  }
}

/// 系统 VPN 授权的**状态词与语义色**。
///
/// 三页要说同一句话：设置页的「系统授权状态」、引导页第 1 页的权限清单、
/// 以及将来任何一处提到这件事的地方。写成一个函数而不是各页私有的一份
/// switch，理由与 [ShuStatusSlot] 一样 —— 「已授权」这个词在哪儿都得是这四个
/// 字、都得是 `accent` 蓝，否则用户要在每个页面各学一次读法。
///
/// 读法与账号管理里那几行凭据一致：可用是 `accent` 蓝、还没解决是
/// `warning`、没有结论是中性灰。
///
/// 取值是 `bool?` 而不是自带头尾状态的原因：`null` 在这里有确切含义 ——
/// **还没问过系统**（见 `ConnectionController.vpnPrepared`），与「问过，
/// 没给」是两件事，不能合并成 false。
///
/// **永远不返回 null 颜色**：调用方多半把它塞进 [ShuStatusSlot]，而颜色为
/// null 时那一格会退回到普通取值的样子（右对齐的次要文字）——同一个状态在
/// 两种取值下长得不一样。
({String text, Color color}) shuVpnPermissionStatus(
  BuildContext context, {
  required bool supported,
  required bool? prepared,
}) {
  final colors = context.shuyoColors;
  if (!supported) {
    return (text: '仅 Android 支持', color: colors.textTertiary);
  }
  return switch (prepared) {
    true => (text: '已授权', color: colors.accent),
    false => (text: '未授权', color: colors.warning),
    null => (text: '检查中…', color: colors.textTertiary),
  };
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
