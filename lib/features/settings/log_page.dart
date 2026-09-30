import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/connection/vpn_packet_log.dart';
import '../../core/logging/shu_log.dart';
import '../../core/settings/settings_store.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_surfaces.dart';

/// 「日志」二级页。
///
/// 它取代了原来那个底部弹层（`showLogSheet`）。改成页面的理由不是样式偏好：
/// 弹层里只能**看**，而这个页面要放两件能改的东西（开不开、记到哪一档），
/// 还要放一块能一直赖在屏幕上的输出区。半屏的弹层装不下这三件事 ——
/// 键盘一弹、面板一收，真正想看的日志就只剩几行。
///
/// 结构上是三段：
///
/// 1. 两个设置行（开关 + 等级）—— 与其它二级页同形（裸 `ListTile`，无卡片）；
/// 2. 一块输出区，**占满剩下的高度**（`Expanded`）。它不随内容滚动，
///    所以日志再多也不会把上面两行顶走；
/// 3. 一行脚注，说明缓冲区里现在有多少条、上限是多少。
///
/// 两个动作放在 AppBar 右侧（复制全部 / 清除），按钮按「有没有记录」置灰 ——
/// 空的时候它们点了也不会有反应，画成可点的样子是骗人。
class ShuLogPage extends StatefulWidget {
  const ShuLogPage({super.key});

  @override
  State<ShuLogPage> createState() => _ShuLogPageState();
}

class _ShuLogPageState extends State<ShuLogPage> {
  /// 直接从单例取，不走 provider：这份缓冲区的生命周期是**整个进程**，
  /// 不是某一棵子树，挂到 `Provider` 上反而会让「谁能写日志」变成一个
  /// 需要传下去的问题。
  final ShuLog _log = ShuLog.instance;

  final ScrollController _scroll = ScrollController();

  /// 是否跟着最新一条走。
  ///
  /// 用户往上翻的时候必须停下来 —— 否则新日志一到就把视图拽回底部，
  /// 正在读的那一行立刻跑掉。翻回底部时自动恢复跟随。
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _log.addListener(_onLogChanged);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
  }

  @override
  void dispose() {
    _log.removeListener(_onLogChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onLogChanged() {
    if (!mounted) return;
    // 新记录插入之后布局才更新，所以滚到底要等这一帧画完。
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final atEnd = position.maxScrollExtent - position.pixels <= 24;
    if (atEnd == _follow) return;
    setState(() => _follow = atEnd);
  }

  void _jumpToEnd() {
    if (!mounted || !_follow || !_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if ((_scroll.position.pixels - target).abs() < 1) return;
    _scroll.jumpTo(target);
  }

  void _copyAll() {
    final lines = _log.lines;
    if (lines.isEmpty) return;
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    showShuSnack(context, '已复制 ${_log.length} 条日志');
  }

  Future<void> _pickLevel(SettingsStore settings) async {
    final picked = await showShuChoiceSheet<ShuLogLevel>(
      context: context,
      title: '日志等级',
      current: settings.logLevel,
      options: <ShuChoice<ShuLogLevel>>[
        for (final level in ShuLogLevel.values)
          ShuChoice<ShuLogLevel>(level, level.label, _levelHint(level)),
      ],
    );
    if (picked != null) settings.logLevel = picked;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final colors = context.shuyoColors;

    return Scaffold(
      appBar: ShuAppBar(
        title: '日志',
        onBack: () => Navigator.of(context).pop(),
        actions: <Widget>[
          ListenableBuilder(
            listenable: _log,
            builder: (context, _) {
              final empty = _log.isEmpty;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: '复制全部',
                    onPressed: empty ? null : _copyAll,
                    icon: const Icon(Icons.copy_all_outlined),
                  ),
                  IconButton(
                    tooltip: '清除日志',
                    onPressed: empty ? null : _log.clear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SettingsSwitchRow(
            icon: Icons.receipt_long_outlined,
            title: '启用日志',
            value: settings.logEnabled,
            onChanged: (value) => settings.logEnabled = value,
          ),
          SettingsRow(
            icon: Icons.tune,
            title: '日志等级',
            value: settings.logLevel.label,
            enabled: settings.logEnabled,
            onTap: () => _pickLevel(settings),
          ),
          Divider(height: 1, color: colors.border),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                ShuSpacing.page,
                12,
                ShuSpacing.page,
                ShuSpacing.page,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: _console(colors, settings)),
                  const SizedBox(height: 8),
                  Text(
                    '已记录 ${_log.length} 条 · 保留最近 ${ShuLog.maxRecords} 条',
                    style: ShuYoTextStyles.meta(color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 输出区。
  ///
  /// 订阅的是 [ShuLog] 而不是 `SettingsStore`：日志到达与设置变更本来就是
  /// 两个事件源，混在一个 `watch` 里会让每次记一行日志都重画上面两个开关行。
  Widget _console(ShuYoColors colors, SettingsStore settings) {
    return ListenableBuilder(
      listenable: _log,
      builder: (context, _) {
        if (!settings.logEnabled) {
          return _shell(colors, _emptyNote(colors, '日志已关闭。'));
        }
        if (_log.isEmpty) {
          return _shell(colors, _emptyNote(colors, '暂无日志。'));
        }
        final records = _log.records;
        return _shell(
          colors,
          ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            itemCount: records.length,
            itemBuilder: (context, index) => _LogLine(
              record: records[index],
              color: _levelColor(colors, records[index].level),
            ),
          ),
        );
      },
    );
  }

  Widget _shell(ShuYoColors colors, Widget child) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: colors.surfaceMuted,
      borderRadius: BorderRadius.circular(ShuRadii.tile),
      border: Border.all(color: colors.border),
    ),
    child: child,
  );

  Widget _emptyNote(ShuYoColors colors, String text) => Center(
    child: Text(
      text,
      style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
    ),
  );

  static Color _levelColor(ShuYoColors colors, ShuLogLevel level) =>
      switch (level) {
        ShuLogLevel.error => colors.danger,
        ShuLogLevel.warn => colors.warning,
        ShuLogLevel.info => colors.textSecondary,
        ShuLogLevel.debug => colors.textMuted,
      };

  static String _levelHint(ShuLogLevel level) => switch (level) {
    ShuLogLevel.error => '只记失败与异常，含发不出去的包',
    ShuLogLevel.warn => '错误，以及被兜住的问题和被丢掉的包',
    ShuLogLevel.info => '警告，加上每一步流程与每条网络流的一行记录',
    ShuLogLevel.debug =>
      '全部细节，含逐个网络包的去向（每秒最多 '
          '${ShuPacketObserver.debugBudgetPerSecond} 行）',
  };
}

/// 一条日志。
///
/// 多行消息（证书指纹不匹配那类）在 [ShuLogRecord.formatLines] 里已经缩进到
/// 与首行正文同一列，所以这里直接整块 `Text` 就够 —— 交给它自己断行的话，
/// 续行会顶到最左边，看起来像另一条记录。
class _LogLine extends StatelessWidget {
  const _LogLine({required this.record, required this.color});

  final ShuLogRecord record;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text(
        record.formatLines().join('\n'),
        style: ShuYoTextStyles.meta(color: color)
            .copyWith(fontFamily: 'monospace', height: 1.45),
      ),
    );
  }
}
