import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_store.dart';
import '../../widgets/settings_scaffold.dart';

/// 「外观」。
///
/// 现在只有一件事：主题。曾经还有一项「Dock 毛玻璃」，随底栏改成贴底实心
/// 一起去掉了 —— 毛玻璃要有东西可模糊才有意义，而底栏现在是实心的一层。
/// 留着那个开关会变成一个「按了没有任何变化」的开关。
///
/// 主题用打勾的行铺开而不是弹层：只有三个选项，全摊开来用户一眼能看见
/// 所有可能性；而分段控件在中文标签下很容易被挤成等宽的窄条。
class ShuAppearanceSettingsPage extends StatelessWidget {
  const ShuAppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();

    return ShuSettingsSubPage(
      title: '外观',
      children: [
        for (final mode in ThemeMode.values)
          ShuChoiceTile<ThemeMode>(
            value: mode,
            current: settings.themeMode,
            label: _label(mode),
            onSelected: (value) => settings.themeMode = value,
          ),
      ],
    );
  }

  static String _label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };
}
