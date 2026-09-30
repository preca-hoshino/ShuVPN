import 'package:flutter/material.dart';

import '../app/shuyo_text_styles.dart';
import '../app/theme.dart';
import 'shu_surfaces.dart';

/// 设置页里的一行 —— **裸的**。
///
/// 「裸」是这一整个设置模块的设计决定，来自两个参考实现：
///
/// * `PiliPlus`（`lib/pages/setting/view.dart`）的目录页是一个裸 `ListView`，
///   每项一个裸 `ListTile`：`leading` 是图标，`title` 是组名，`subtitle`
///   是这个组里有什么；
/// * `ShuYo`（`lib/features/settings/client_settings_page.dart`）的 `_SettingsRow`
///   更短，连副标题都没有：`ListTile(title:, trailing: chevron_right, onTap:)`。
///
/// 两边共同否定的是同一件东西：**分组卡片**。曾经这里的每一组都是一个
/// `ShuCard`（圆角 + 边框 + 组内 `Divider`），外加一行小字分区标题。
/// 那层包裹没有多给任何信息 —— 「账户」和「外观」之间并不需要一道边界线来
/// 说明它们是两件事，行与行之间距离变大就够了。去掉之后整页读起来是一条
/// 列表，而不是几张卡片。
///
/// 也正因为如此，这一行的正文只有标题、**可选的一行副标题**，以及右侧的
/// 当前值 [value]。
///
/// `subtitle` 与 `value` 回答的是两个不同问题，别混：
///
/// * `subtitle` = 这一组里**有什么**（`主题风格、配色切换`）。固定不变的字，
///   在这行本身。
/// * `value` = **现在是什么**（`1080`、`196 秒`）。会变的字，在右边。
///
/// 目录页两者都只写前者，因为「有哪几件事可以改」才是它要回答的；二级页
/// 两者都要，因为那里的每一行就是一项设置，看不到当前值就得点开才知道。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.value,
    this.valueColor,
    this.onTap,
    this.enabled = true,
    this.danger = false,
  });

  /// 行标题。这是这一行唯一的文字主体。
  final String title;

  /// 左侧图标。
  ///
  /// 从 `PiliPlus` 借来的做法：图标是这一列里最靠左的锚点，几行的图标
  /// 落在同一条竖线上，扫视时不用读字就知道自己在哪一类里。
  final IconData icon;

  /// 这一组里**有什么**。用顿号或逗号罗列，不写完整句子。
  final String? subtitle;

  /// 右侧的当前值。写不下时省略号截断 —— 它是给人确认的，不是给人读的。
  final String? value;

  /// [value] 的颜色。为 null 时走默认的次要文字色。
  ///
  /// 只有**状态类**的值才该用它（已授权 / 未授权这种）：普通取值（端口号、
  /// MTU）上色只会让整页看起来到处在报错。
  ///
  /// 上色时右侧那一格改用 [ShuStatusSlot] 渲染 —— 与「账号管理」里那几行
  /// 凭据状态是**同一个组件**，所以两页的状态词落在同一种视觉处理上。
  final Color? valueColor;

  /// 为 null 时这一行是只读的，并且**不画右箭头**。
  ///
  /// 箭头是「这里可以点」的承诺。读不到的东西不该给这个承诺 —— 两个参考
  /// 实现也都是这么处理的（`ShuYo` 的 `_SettingsRow` 只在传入 `onTap` 时
  /// 有箭头）。
  final VoidCallback? onTap;

  final bool enabled;

  /// 破坏性操作（清除指纹这类）用 `danger` 色的标题。
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final interactive = onTap != null && enabled;
    final titleColor = !enabled
        ? colors.textMuted
        : danger
        ? colors.danger
        : colors.textPrimary;

    return ListTile(
      enabled: enabled,
      onTap: interactive ? onTap : null,
      leading: Icon(icon),
      title: Text(
        title,
        style: ShuYoTextStyles.title(size: 15.5, color: titleColor),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: ShuYoTextStyles.meta(color: colors.textTertiary),
            ),
      // 副标题会把行高撑到 72 以上，默认的 `threeLine` 对齐会把图标按
      // 标题行定位 —— 两行文字时图标就明显偏高。目录页的每行都要两行，
      // 所以这里统一居中。
      titleAlignment: ListTileTitleAlignment.center,
      trailing: _trailing(colors, onTap != null && enabled),
    );
  }

  Widget? _trailing(ShuYoColors colors, bool interactive) {
    final value = this.value;
    if (value == null && !interactive) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null)
          if (valueColor != null)
            // 状态词走共享的状态槽，与账号管理同一种视觉处理。
            ShuStatusSlot(
              text: value,
              color: enabled ? valueColor! : colors.textMuted,
            )
          else
            ConstrainedBox(
              // 固定上限而不是自适应：几行的值长短不同（`自动` 两字、
              // `https://github.com/...` 一长串），自适应会让每行的标题被
              // 压缩的程度都不一样；定宽之后标题的右边界是齐的。
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: ShuYoTextStyles.meta(
                  color: enabled ? colors.textTertiary : colors.textMuted,
                ),
              ),
            ),
        if (value != null && interactive) const SizedBox(width: 2),
        if (interactive) const Icon(Icons.chevron_right),
      ],
    );
  }
}

/// 一个开关行。左侧图标 + 标题，右侧开关。
///
/// 用 `SwitchListTile` 的 `secondary` 槽放图标，而不是自己拼 `ListTile`
/// 加 `trailing` 开关 —— 后者要手写 `Row`、还要自己处理点整行也算切换的
/// 语义，而 `SwitchListTile` 本来就是这个语义。
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    required this.icon,
    required this.value,
    this.subtitle,
    this.onChanged,
    this.enabled = true,
  });

  final String title;
  final IconData icon;
  final bool value;

  /// 一行说明，写「这个开关是干什么的」。与 [SettingsRow.subtitle] 同义，
  /// 只是这里没有右侧的当前值 —— 开关本身就是当前值。
  final String? subtitle;

  final ValueChanged<bool>? onChanged;

  /// 为 false 时开关**画成灰的、点不动**，标题也褪色。
  ///
  /// 这与「开关关着」是两件不同的事，页面上也看得出来：关着是灰色的滑块、
  /// 文字正常；封掉是整个控件褪成一片，并且 [subtitle] 会说明原因。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SwitchListTile(
      value: value,
      onChanged: enabled ? onChanged : null,
      secondary: Icon(icon),
      title: Text(
        title,
        style: ShuYoTextStyles.title(
          size: 15.5,
          color: enabled ? colors.textPrimary : colors.textMuted,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: ShuYoTextStyles.meta(color: colors.textTertiary),
            ),
    );
  }
}
