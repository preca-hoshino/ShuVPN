import 'package:flutter/material.dart';

import '../app/shuyo_text_styles.dart';
import '../app/theme.dart';
import 'shu_app_bar.dart';

/// 二级设置页共用的外壳：一个普通 `AppBar` + 一列**裸行**。
/// 二级页互相之间长得一样，把它们共用的那点骨架抽出来，各页就只剩内容了 ——
/// 而这几页的差异本来也只在内容上（三个选项 vs 两个开关）。
///
/// 内容**不套卡片、不分段落**：与设置目录页同一形态（见 [SettingsRow]）。
class ShuSettingsSubPage extends StatelessWidget {
  const ShuSettingsSubPage({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ShuAppBar(
        title: title,
        onBack: () => Navigator.of(context).pop(),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          ShuSpacing.page,
          // 顶部只留一点点：以前分组自带一段上边距，现在没有分组了，
          // 这一段要自己给。
          8,
          ShuSpacing.page,
          ShuSpacing.page * 2,
        ),
        children: children,
      ),
    );
  }
}

/// 二级页里的一段说明文字。
///
/// 设置页上的解释性文字塞进行内会把标题挤没，挂在行下面又容易被当成可点的
/// 东西；单起一段小字最省事，也最不容易被误读。
///
/// 它是**整页最后一个元素**的常客 —— 前面的行都是「一个动作一行」，
/// 而「为什么是这样」放到最后统一说，读的人可以先跳过去。
class ShuSettingsNote extends StatelessWidget {
  const ShuSettingsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.only(
        left: 4,
        right: 4,
        top: ShuSpacing.page,
        bottom: 4,
      ),
      child: Text(text, style: ShuYoTextStyles.meta(color: colors.textMuted)),
    );
  }
}

/// 二级页**页首**的一段警告。
///
/// 与 [ShuSettingsNote] 是同一样东西的两种语气：都是小字、都不带标题、都不
/// 容易被误当成可点的东西。区别只在颜色与位置 —— 它在页首、用警示色，说的
/// 是「动这一页上的东西之前要先知道的事」；[ShuSettingsNote] 在页尾、用
/// 次要色，说的是「为什么是这样」。
///
/// 语气要求与日志一致（见 `shu_log.dart`）：**陈述后果，不喊，不加感叹号**。
/// 它要用的时候，页面上每一项都真的可能让设备在连接期间上不了网；把这一点
/// 写清楚就够了 —— 吓人的写法只会让人跳过这一段，而跳过的人正好是最该看见
/// 它的那一个。
class ShuSettingsWarning extends StatelessWidget {
  const ShuSettingsWarning(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
      child: Text(text, style: ShuYoTextStyles.meta(color: colors.warning)),
    );
  }
}

/// 一行「单选」：一组里只能选一个的设置用它。
///
/// 用打勾的行而不是下拉或分段控件：这类设置通常只有两三个选项，全摊开来
/// 用户一眼能看见所有可能性；而分段控件在中文标签下很容易被挤成等宽的窄条。
///
/// 图标与设置行同一条竖线（`ListTile` 的 `leading` 槽），所以它混在几个开关
/// 和入口之间也不会显得是另一套东西 —— 区别只在最左边那个图标是空心圆
/// 还是实心圆。
class ShuChoiceTile<T> extends StatelessWidget {
  const ShuChoiceTile({
    super.key,
    required this.value,
    required this.current,
    required this.label,
    required this.onSelected,
  });

  final T value;
  final T current;
  final String label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final selected = value == current;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? colors.accent : colors.textMuted,
      ),
      title: Text(
        label,
        style: ShuYoTextStyles.title(
          size: 15.5,
          color: selected ? colors.textPrimary : colors.textSecondary,
        ),
      ),
      onTap: () => onSelected(value),
    );
  }
}

/// 一个可选项，供 [showShuChoiceSheet] 用。
@immutable
class ShuChoice<T> {
  const ShuChoice(this.value, this.label, [this.subtitle]);

  final T value;
  final String label;
  final String? subtitle;
}

/// 数值型设置的选择器（超时秒数这类）。
///
/// 主题那种「一眼看全所有选项」的用 [ShuChoiceTile] 铺成行；这里的选项
/// 只有数字有意义、不用比较，所以用弹层 —— 选完就走，不占页面。
Future<T?> showShuChoiceSheet<T>({
  required BuildContext context,
  required String title,
  required List<ShuChoice<T>> options,
  required T current,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final colors = sheetContext.shuyoColors;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ShuSpacing.page,
                0,
                ShuSpacing.page,
                8,
              ),
              child: Text(
                title,
                style: ShuYoTextStyles.sectionTitle(color: colors.textPrimary),
              ),
            ),
            for (final option in options)
              ListTile(
                title: Text(
                  option.label,
                  style: ShuYoTextStyles.title(
                    size: 15.5,
                    color: colors.textPrimary,
                  ),
                ),
                subtitle: option.subtitle == null
                    ? null
                    : Text(
                        option.subtitle!,
                        style: ShuYoTextStyles.meta(color: colors.textTertiary),
                      ),
                trailing: option.value == current
                    ? Icon(Icons.check, color: colors.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(option.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// 让用户改一行文字的对话框（服务器地址、登录域这类）。
///
/// 用对话框而不是弹层：这类设置**必须看到现在是什么**（用户是照着网关上的
/// 值改，不是凭印象选），而弹层从底部升起、还要盖住半屏键盘，看不到背景里
/// 的上下文。对话框把「原来是什么 / 现在要改成什么」摆在一起。
///
/// 返回去掉首尾空格的文本；取消返回 `null`。**空串是合法返回值**（它表示
/// 「用户真的把它清空了」），所以调用方不能用「空即取消」来判断 ——
/// 这正是返回值用 `String?` 而不是 `String` 的原因。
Future<String?> showShuTextPrompt({
  required BuildContext context,
  required String title,
  required String label,
  required String initial,
  String? helper,
  String? Function(String value)? validate,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ShuTextPromptDialog(
      title: title,
      label: label,
      initial: initial,
      helper: helper,
      validate: validate,
    ),
  );
}

class _ShuTextPromptDialog extends StatefulWidget {
  const _ShuTextPromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    this.helper,
    this.validate,
  });

  final String title;
  final String label;
  final String initial;
  final String? helper;
  final String? Function(String value)? validate;

  @override
  State<_ShuTextPromptDialog> createState() => _ShuTextPromptDialogState();
}

class _ShuTextPromptDialogState extends State<_ShuTextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    final error = widget.validate?.call(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: widget.label,
              helperText: widget.helper,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: ShuYoTextStyles.meta(color: colors.danger)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
