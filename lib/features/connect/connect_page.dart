import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/connection/connection_controller.dart';
import '../../core/connection/protocol.dart';
import '../../core/connection/vpn_packet_log.dart';
import '../../core/settings/settings_store.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_surfaces.dart';
import 'connect_button.dart';

/// 中 dock 目的地。形状抄的是 Speedtest：**一颗大圆 + 底部一张两段式抽屉**。
///
/// ## 为什么抽屉第一行是「一句会变的话」而不是「一排固定的行」
///
/// 这一页要回答的问题随状态完全变样：
///
/// | 状态 | 用户想知道的是 |
/// | :--- | :--- |
/// | 未连接 | 「我要连谁」—— 所以那一行写协议名与服务器 |
/// | 连接中 | 「到哪一步了」—— 所以那一行右边转起来、中间写当前这一步 |
/// | 已连接 | 「通到哪了、有没有在跑」—— 所以那一行换成 IP 与上下行、时延 |
/// | 失败 | 「为什么」—— 所以那一行换成错误原文，并上警示色 |
///
/// 四种内容取在屏幕上的同一块地方（底栏正上方），于是用户的视线不用挪：
/// 点的地方（大圆）永远在中间，读的地方永远在它下面。把它们铺成四排固定
/// 的行做不到这一点 —— 那是每一行各自变化，而这是**同一行在换内容**。
///
/// 那一行**不套卡片**：图标、标题、小字三样裸着排在抽屉里。它不是个能点
/// 的东西，而描边 + 底色 + 圆角恰恰是一句「这里可以按」；抽屉自己那两条
/// 圆角与顶边已经把这一块的边界画出来了，里面再描一圈就是框里套框。
///
/// ## 底部是一张**两段式抽屉**（[_ConnectionDrawer]）
///
/// 这一段是向 Speedtest 学的，学的是它的**机制**而不是配色：
///
/// * **未拉开**：只露一行字。它回答「现在通不通」—— 协议、地址、上下行、
///   时延，一眼扫完。这一档是常态，绝大多数打开这一页的时刻都停在这里；
/// * **拉开**：那一行往上走，下面两组露出来 —— 协议（换一条）与连接方式
///   （三路各自监听在哪，带复制）。这一档是「我要改点什么」或者「我要抄一个
///   地址」，用完往下一推、或者点外面一下就回去了。
///
/// 拉开不靠点：把手能拖、抽屉里任意一处都能拖 —— 跟着手指走，松手吸附到
/// 最近那一档。两档之间的吸引子一共两个，也就没有「半开」这种状态需要解释。
///
/// 拉开之后**不重复上面那一行已经说过的事**：服务器地址在那一行的副标题里
/// 已经写了一道，协议的当前状态也由「哪一行写着使用中」当场回答了。再各
/// 占一行只是把抽屉撑长。
///
/// ## 拉开时背景会暗下去，点外面就收回去
///
/// 遮罩的浓度跟着**抽屉自己的高度**走（[AnimatedBuilder] 听
/// `DraggableScrollableController`），所以手指拖到一半松手时它不会先暗后亮 ——
/// 底下那颗圆的可见度与抽屉露多少是同一件事。灰遮罩盖住的那一块也是
/// 「点一下就收回」的命中区：拉开的抽屉会遮住大圆，没有这条退路就只能靠
/// 把手那一根 4 像素的横条。
///
/// ## 为什么把协议与代理地址放进抽屉而不是放页面上
///
/// 它们各自只在一种场合被用到，而这一页的常态是「什么都不改，只是看一眼
/// 通不通」：
///
/// * 协议改一次就不动，而且**只在未连接时才有意义**（隧道起来之后改它，
///   `draft` 与 `state` 会分叉）—— 一条「连着时改了也没用」的控件不该占
///   页面上最好的一块位置；
/// * 两个代理地址是「要抄走」的东西，不是「要盯着看」的东西。放进抽屉
///   并不意味着难拿：往下拉一下再点复制，比在一屏里找它更快。
///
/// 设置里关掉的协议**仍然选不中**（不是禁用一个功能，是把设置页那个开关的
/// 效果当场兜现出来）。隧道在跑时三行协议整段只读 —— 与「网络连接」那一页
/// 同一条规则，只是这里锁的是一段而不是整页。
class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key});

  /// 抽屉里第一行那个 `Row` 的 key。
  ///
  /// 它给测试用：这一行是**唯一**能表示「抽屉停在哪一档」的锚点 —— 两种
  /// 档位下它都在树里（不像下面那几组可能落在缓存区外），而它的纵向位置
  /// 直接跟着档位走（拉开时整张单子被顶上去）。
  static const Key statusRowKey = ValueKey<String>('connect-status-row');

  /// 抽屉把手那根小横条的 key。
  ///
  /// 同上：它是抽屉里唯一「点一下就能换档」的东西（那一行字只读），而它
  /// 本体是一根 4 像素高的横条 —— 拿不到 key 就只能去撞一个字号或位置。
  static const Key grabberKey = ValueKey<String>('connect-drawer-grabber');

  /// 抽屉遮罩那块的 key。
  ///
  /// 它同时是两件事的证据：它的**颜色浓度**就是「抽屉拉开了多少」（测试
  /// 拿它断言背景确实暗下去了），而它的**命中区**就是「点一下就收回」
  /// 那条退路。
  static const Key scrimKey = ValueKey<String>('connect-drawer-scrim');

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ConnectionController>();
    final scheme = Theme.of(context).colorScheme;
    final colors = context.shuyoColors;

    final usable = controller.hasEnabledProtocol;
    // 不再传 `detail`：卡片自己按状态拼那两行字，而它是唯一读这个字段的
    // 地方 —— 一个只有一处消费的参数等于多一条要同步的路径。
    final style = connectionStateStyle(colors, scheme, controller.state);

    return Scaffold(
      appBar: ShuAppBar(
        title: '连接',
        onNotifications: () => context.push('/notifications'),
      ),
      // `DockShell` 开着 `extendBody`，所以底栏是**压在**这一页上面的；
      // 这一层 `SafeArea` 会替我们把它和手势条的高度留出来
      // （`Scaffold` 在 `extendBody` 时把底栏高度并进了 body 的 padding）。
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 大圆。它的活动范围是**抽屉未拉开时留下的那一块** ——
            // 抽屉是压在它上面的，所以按整屏居中会算错：圆的视觉中心会
            // 比屏幕中心低半个抽屉的高度。
            Positioned.fill(
              bottom: _ConnectionDrawer.peekHeight,
              child: LayoutBuilder(
                builder: (context, box) {
                  final diameter = math
                      .min(box.maxWidth * 0.56, box.maxHeight * 0.82)
                      .clamp(112.0, 208.0);
                  return Center(
                    child: ConnectButton(
                      style: style,
                      diameter: diameter,
                      onTap: () => _onPress(context, controller, usable),
                    ),
                  );
                },
              ),
            ),
            // 抽屉。它盖在圆上面 —— 与 Speedtest 一样：往下拉的时候圆被
            // 盖掉是应该的，因为那一刻用户在读抽屉，不是在读那颗圆。
            _ConnectionDrawer(controller: controller, usable: usable),
          ],
        ),
      ),
    );
  }

  void _onPress(
    BuildContext context,
    ConnectionController controller,
    bool usable,
  ) {
    if (!usable) {
      // 走全应用那一条提示通道：从底下浮出来的一根长条，几秒后自己退场。
      showShuSnack(context, '无可用协议，请先在设置中启用一个');
      return;
    }
    controller.toggle();
  }
}

/// 底部那张**两段式抽屉**。整个连接页的构图就是「圆 + 这张抽屉」。
///
/// ## 两档，各自回答一个问题
///
/// | 档 | 高度 | 里面是什么 |
/// | :--- | :--- | :--- |
/// | 未拉开 | [peekHeight] | 一行字：「现在通不通」—— 协议 / 地址 / 上下行 / 时延 |
/// | 拉开 | [expandedHeight] | 那一行 + 两组裸列表：协议、连接方式 |
///
/// 两档之间**不是弹层与内容的关系，而是同一张单子的两个停靠位**：拉开时
/// 下面的内容不是凭空出现，它一直在树里，刚才只是在屏幕外。所以手感是连续
/// 的（跟着手指走、松手吸附到最近那一档），而不是「点一下、浮一层」。
///
/// ## 为什么用 [DraggableScrollableSheet] 而不是自己写拖拽
///
/// 它把三件最容易写错的事都做好了：跟着手指的位移、松手后的速度判定
/// （甩一下就能到另一档）、以及吸附。自己用 `AnimationController` 拼一遍
/// 得到的除了更多代码，还有一套和系统手感不一样的惯性曲线。
///
/// 唯一的代价是**内容必须是一个用它的 `scrollController` 的滚动视图** ——
/// 那也是它同时支持「拉到底再继续滑」的方式。
///
/// ## 两档的高度用像素换算，不是写死两个比例
///
/// 「未拉开」要刚好露出那一行字，那是一个固定的**像素**高度，与屏幕多高
/// 无关：写成 `0.2` 的话，矮屏会把那一行裁掉一截，而高屏会露出一大片空白。
/// 见 [_ConnectionDrawerState] 里那两行 `clamp`。
///
/// ## 隧道在跑时协议那一段只读
///
/// 与「网络连接」那一页同一条规则（那里是整页封住）。判据也一样简单：
/// 换协议只改 `draft`，隧道起来之后 `draft` 与 `state` 会分叉 —— 界面上
/// 写着 aTrust、实际跑着别的，是查不出来的那种不一致。
class _ConnectionDrawer extends StatefulWidget {
  const _ConnectionDrawer({required this.controller, required this.usable});

  final ConnectionController controller;

  /// 三个协议全关时为 false。它一路传进卡片 ——「未连接」与「没得连」是
  /// 两种完全不同的处境，而它们看起来一模一样。
  final bool usable;

  /// 未拉开时露出来的高度。
  ///
  /// 它必须 ≥ 把手 + 那一行：那一行是这一页上唯一「平时就该看见」的东西，
  /// 露不全等于没露。80 = 把手 22 + 那一行 52 + 一点余量。
  static const double peekHeight = 80;

  /// 拉开之后的高度上限。
  ///
  /// 不是越高越好：拉到底之后上面那半屏只剩一颗被压扁的圆，而这一页的
  /// 主角是那颗圆。500 刚好放得下两组裸列表（各三行加上一行组标题），
  /// 又给圆留下了构图。
  ///
  /// 这个数是**量出来的**，不是估的：六行列表 + 两行组标题 + 拉开时那一行
  /// 字一共 473，再加底部内边距。改小一点，`Android VPN 服务` 那一行就会
  /// 掉到底外 —— 拉到底还得在抽屉里再滑一下才看得到它。
  /// `widget_test.dart` 里一条拿**真机视口**跑的用例守着这个数。
  ///
  /// 内容比屏幕高时（矮屏）它就是按比例算的上限，抽屉里会滑；内容比它短
  /// 的时候底下会空一截 —— 看不见，抽屉的底色就是 `colors.background`，
  /// 与页面底色是同一个，所以空的那一块没有任何边界。
  static const double expandedHeight = 500;

  /// 遮罩最浓时的黑度。
  ///
  /// 比 Material 自己的 `Colors.black54` 轻：这一页被遮住的不是一屏内容，
  /// 而是一颗圆 —— 0.54 会让它看起来像出了错。
  static const double scrimAlpha = 0.34;

  @override
  State<_ConnectionDrawer> createState() => _ConnectionDrawerState();
}

class _ConnectionDrawerState extends State<_ConnectionDrawer> {
  final DraggableScrollableController _sheet = DraggableScrollableController();

  /// 两档的比例。它们在 [build] 里由实际像素算出，存下来给 [_progress] 与
  /// [_toggle] 用 —— 那两个都发生在手势回调与帧中间，那里拿不到
  /// `LayoutBuilder` 的 `box`。
  double _min = 0;
  double _max = 1;

  /// 抽屉拉开到几成 —— 0 是未拉开，1 是到底。
  ///
  /// 它是**当场问控制器**得到的，不是存下来的一个字段：用户用手指拖到一半
  /// 松手、或者直接甩上去，那一次变化没人写进字段里。遮罩浓度、以及
  /// [_toggle] 该往哪边动，读的都是这一个值。
  double get _progress {
    if (!_sheet.isAttached || _max <= _min) return 0;
    return ((_sheet.size - _min) / (_max - _min)).clamp(0.0, 1.0);
  }

  /// 现在停在哪一档。
  bool get _expanded => _progress > 0.5;

  /// 遮罩要不要参与命中测试。
  ///
  /// 它有一个下限，而不是判 `== 0`：吸附落地时那个浮点数不保证正好是
  /// `_min`，差一个 ulp 就会让一块完全透明的遮罩把大圆的点击永久吃掉。
  bool get _scrimBlocks => _progress >= 0.01;

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  /// 请求动画到另一档。拖拽手势由抽屉自己处理，这里只管点。
  void _toggle() => _animateTo(_expanded ? _min : _max);

  /// 收回去。给遮罩用 —— 拉开的抽屉会盖住大圆，没有这一条就只能靠把手
  /// 那一根 4 像素的横条把它收回去。
  void _collapse() => _animateTo(_min);

  void _animateTo(double size) {
    if (!_sheet.isAttached) return;
    _sheet.animateTo(size, duration: ShuMotion.base, curve: ShuMotion.curve);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    // 用**实际可用的高度**换算比例，不是屏幕高度：这一层被 appbar 与底栏
    // 夹在中间，两者的差在矮屏上能到一成，而「露出多少像素」正是两档的
    // 全部定义。
    return LayoutBuilder(
      builder: (context, box) {
        final min = (_ConnectionDrawer.peekHeight / box.maxHeight).clamp(
          0.06,
          0.24,
        );
        final max = (_ConnectionDrawer.expandedHeight / box.maxHeight).clamp(
          min + 0.08,
          0.8,
        );
        _min = min;
        _max = max;

        // 只听控制器，不重建下面那棵树：`child` 是抽屉自己，它的变化由
        // `DraggableScrollableSheet` 内部的状态驱动，与这里的重建无关。
        return AnimatedBuilder(
          animation: _sheet,
          child: DraggableScrollableSheet(
            controller: _sheet,
            initialChildSize: min,
            minChildSize: min,
            maxChildSize: max,
            // 两个吸引子，没有中间态 —— 这就是「两段式」。
            snap: true,
            snapSizes: <double>[min, max],
            builder: (context, scrollController) => DecoratedBox(
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(ShuRadii.card),
                ),
                border: Border(top: BorderSide(color: colors.border)),
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(ShuRadii.card),
                ),
                child: ListView(
                  // 必须用抽屉给的这个控制器，否则拖不动。
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(
                    ShuSpacing.page,
                    0,
                    ShuSpacing.page,
                    16,
                  ),
                  children: <Widget>[
                    _DrawerGrabber(key: ConnectPage.grabberKey, onTap: _toggle),
                    _ConnectionStatusRow(
                      key: ConnectPage.statusRowKey,
                      controller: widget.controller,
                      usable: widget.usable,
                    ),
                    ..._sections(context),
                  ],
                ),
              ),
            ),
          ),
          builder: (context, child) => Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 遮罩。它在抽屉**下面**（`Stack` 里后画的在上面），盖住的
              // 就是抽屉没占的那一块 —— 也就是大圆。
              IgnorePointer(
                ignoring: !_scrimBlocks,
                child: GestureDetector(
                  // `opaque`：透明的那块也要接住点击，否则点大圆旁边
                  // 的空白不会收回抽屉。
                  behavior: HitTestBehavior.opaque,
                  onTap: _collapse,
                  child: ColoredBox(
                    key: ConnectPage.scrimKey,
                    color: Colors.black.withValues(
                      alpha: _ConnectionDrawer.scrimAlpha * _progress,
                    ),
                  ),
                ),
              ),
              // 抽屉自己的上层没有东西：那一行字与两组列表全在它里面。
              ?child,
            ],
          ),
        );
      },
    );
  }

  /// 拉开之后才看得见的那两组。
  ///
  /// 它们**一直**在树里（没拉开的差别只是位置在屏幕外），所以这里不该有
  /// 「要不要画」的判断 —— 两组都是「怎么连」的一部分，任何状态下都该看得
  /// 见：协议是「从哪条路走」，另外三行是「流量从哪个口子交出去」。
  ///
  /// 形状学的是设置页：图标 + 名字 + 右侧当前值，没有卡片、没有分割线，
  /// 行与行之间只靠距离分组。这一页里用同一个形状还有一个好处 —— 抽屉拉开
  /// 之后从上到下是一条列，而不是一片控件。
  List<Widget> _sections(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final colors = context.shuyoColors;
    final controller = widget.controller;
    final locked = controller.busy;
    final selected = controller.draft.protocol;
    // 「安卓 VPN 服务在不在用」有两个来路：设置里那个开关，以及它此刻是不是
    // 真的在跑（连上隧道时它是被强制拉起的）。两个都算「已启用」。
    final vpnOn = settings.vpnEnabled || controller.vpnRunning;

    return <Widget>[
      SectionHeader(
        title: '协议',
        // 锁定说明挂在组标题右边，不另占一行：它说的是**这一组现在能不能
        // 动**，与标题是同一件事的两半。
        trailing: locked
            ? Text(
                '连接期间不可改',
                style: ShuYoTextStyles.meta(color: colors.textMuted),
              )
            : null,
      ),
      for (final option in ShuProtocol.values)
        _DrawerRow(
          icon: option.icon,
          title: option.label,
          // 设置里关掉的、以及隧道在跑时锁住的，都按不动。
          enabled: !locked && settings.isProtocolEnabled(option),
          onTap: option == selected
              ? null
              : () => controller.selectProtocol(option),
          // 右侧那一格只说**这一行的状态**，三种取值互斥：在用 / 还没接
          // （[ShuProtocol.implemented] 为假）/ 什么也不说（可用但没选中）。
          trailing: option == selected
              ? ShuStatusSlot(text: '使用中', color: colors.accent)
              : option.implemented
              ? null
              : ShuStatusSlot(text: '未接入', color: colors.textMuted),
        ),

      const SectionHeader(title: '连接方式'),
      _DrawerRow(
        icon: Icons.public,
        title: 'HTTP 代理',
        trailing: _CopyableValue(
          value: controller.httpListenAddress,
          label: 'HTTP 代理地址',
        ),
      ),
      // 地址与图标都跟着设置页那两行：同一样东西在两个页面上应该是同一个
      // 字形，否则用户会以为它们是两种不同的东西。
      _DrawerRow(
        icon: Icons.settings_ethernet,
        title: 'SOCKS5 代理',
        trailing: _CopyableValue(
          value: controller.proxyAddress,
          label: 'SOCKS5 代理地址',
        ),
      ),
      _DrawerRow(
        icon: Icons.vpn_lock_outlined,
        title: 'Android VPN 服务',
        trailing: ShuStatusSlot(
          text: vpnOn ? '已启用' : '已关闭',
          color: vpnOn ? colors.accent : colors.textMuted,
        ),
      ),
    ];
  }
}

/// 抽屉顶上那根小横条。
///
/// 它是「这里能拉」的**通用写法** —— 几乎每一个可拉的面板都有一根，所以
/// 用户不用学。点它也能切换档位：那根横条太细，只拖不点会让想展开的人
/// 先试一次失败。
class _DrawerGrabber extends StatelessWidget {
  const _DrawerGrabber({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Semantics(
      button: true,
      label: '连接抽屉',
      hint: '双击拉开或收起',
      child: GestureDetector(
        // `opaque` 让那根 4px 的横条周围的空白也算命中区域，
        // 否则要把手指精确放在横条上才点得中。
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 22,
          child: Center(
            child: Container(
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: colors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 抽屉里的一行 —— 形状学的是设置页那种「图标 + 名字 + 右侧当前值」。
///
/// ## 为什么协议从「横向 Tab」退回成三行列表
///
/// 三条协议并排在一条 Tab 上时，每一格只有一百出头逻辑像素：图标只能叠在
/// 文字上面，`EasyConnect` 那十一个字母几乎贴着边，「未接入」这种状态也没
/// 地方写。竖着排之后每行都独占整行 —— 图标在左、状态在右，与下面「连接
/// 方式」那三行是同一个形状，整张抽屉读起来是一条列，而不是一片控件。
///
/// 代价是这一组从 40 像素变成 144 像素，抽屉的高度上限因此从 400 提到 480。
/// 它仍然是个两段式抽屉 —— 只是第二段里内容多了一点。
///
/// ## 「点不动」与「没选中」是两件事
///
/// [enabled] 为假的行褪色、点不动（设置里关掉了，或者隧道正在跑）；正在
/// 用的那一条由右侧的「使用中」说出来，而不是靠选中色 —— 设置页里右边的
/// 字就是状态，这一页沿用同一套读法。
class _DrawerRow extends StatelessWidget {
  const _DrawerRow({
    required this.icon,
    required this.title,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return ListTile(
      enabled: enabled,
      onTap: enabled ? onTap : null,
      // 左右各 4 与上面那一行字、与组标题对齐；`compact` 把行高压到 48 ——
      // 这两组要的是紧凑，而设置页那几行是 56 起步（它每行都是一项设置，
      // 这一页只是一列「现在怎么连着」）。
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
      titleAlignment: ListTileTitleAlignment.center,
      leading: Icon(icon),
      title: Text(
        title,
        style: ShuYoTextStyles.bodyCompact(
          color: enabled ? colors.textPrimary : colors.textMuted,
        ),
      ),
      trailing: trailing,
    );
  }
}

/// 「地址 + 复制」那一格。
///
/// 设置页在同一个位置放的是一行 `value` 文字；这一页多给一颗复制按钮 ——
/// 抽屉里的地址是**要抄走的**（填进别的应用、或者别的设备的代理设置），不是
/// 要读的。两者挨着放，不用先点开再复制。
class _CopyableValue extends StatelessWidget {
  const _CopyableValue({required this.value, required this.label});

  final String value;

  /// 无障碍标签里那句「复制×××」。
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ConstrainedBox(
          // 定宽上限而不自适应：两行的地址长短不同（`127.0.0.1:2233` 与
          // 某张具名网卡上的长地址），自适应会让两行的名字被压缩的程度
          // 不一样；定宽之后名字的右边界是齐的。
          constraints: const BoxConstraints(maxWidth: 132),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShuYoTextStyles.meta(color: colors.textTertiary),
          ),
        ),
        _CopyButton(value: value, label: label),
      ],
    );
  }
}

/// 抽屉的第一行 —— 这一页的「一句话」，形状抄的是 Speedtest。
///
/// ## 四种状态共用同一行
///
/// | 状态 | 左 | 中 | 右 |
/// | :--- | :--- | :--- | :--- |
/// | 未连接 | 协议 icon | 协议名 / 服务器 | — |
/// | 连接中 | 协议 icon | 状态词 / 服务器 | **转圈** |
/// | 已连接 | 协议 icon | 地址 / 上下行与时延 | — |
/// | 失败 | 警示 icon | 错误原文 / 协议与服务器 | — |
///
/// 四种内容取在屏幕上的同一块地方，所以用户的视线不用挪：点的地方（大圆）
/// 永远在中间，读的地方永远在它下面。
///
/// ## 为什么它是三样裸着的东西，而不是一张卡片
///
/// 因为它**不可点**。描边 + 底色 + 圆角是一句「这是一块能按的东西」，而
/// 「拉开抽屉」这件事已经交给把手与拖拽了 —— 给一行只能读的字套上可点的
/// 外观，是把用户引向一次不会有任何反应的点击。
///
/// 去掉框之后反而更清楚：抽屉自己那两条圆角与顶边已经把这一块的边界画出来
/// 了，里面再描一圈就是框里套框。图标、标题、小字各就各位，没有一样需要
/// 边框来解释自己。
///
/// ## 为什么已连接时不显示协议名了
///
/// 因为那一刻「连的是谁」已经由结果回答了 —— `10.95.178.77` 就是答案。
/// 再写一遍协议名是重复，而这一行只有两行的宽度：重复的代价是把上下行挤到
/// 第二行去。协议名拉开抽屉就能看到。
///
/// ## 左边的图标一直是**协议的**，变的只是颜色
///
/// 它换成绿盾牌曾经是有意为之（想要一个「通了」的记号），但那件事已经由
/// 大字号的颜色和「↑ ↓ 时延」说完了；再换一个字形就是把一排图标里唯一
/// 认得出「走的哪条路」的锚点换掉了。所以字形永远是协议自己的，连上之后
/// 只把它染成 success ——同一个图标换一个颜色，认的是同一样东西。
///
/// ## 转圈是全行唯一的「活物」，也守着「降低动效」
///
/// `CircularProgressIndicator` 的不确定态是永动机，与 `ConnectButton` 里
/// 那个进度环是同一个理由：开了「降低动效」就不画它。顺带一个好处 ——
/// widget 测试里的 `pumpAndSettle` 不会被它绊住。
class _ConnectionStatusRow extends StatelessWidget {
  const _ConnectionStatusRow({
    super.key,
    required this.controller,
    required this.usable,
  });

  final ConnectionController controller;

  /// 三个协议全关时为 false。那时这一行改成说这件事 ——「未连接」与「没得连」
  /// 是两种完全不同的处境，而它们看起来一模一样。
  final bool usable;

  bool get _busy {
    final state = controller.state;
    return state == SangforConnectionState.connecting ||
        state == SangforConnectionState.authenticated ||
        state == SangforConnectionState.disconnecting;
  }

  bool get _connected => controller.state == SangforConnectionState.connected;

  bool get _failed => controller.state == SangforConnectionState.error;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final scheme = Theme.of(context).colorScheme;
    final style = connectionStateStyle(colors, scheme, controller.state);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final protocol = controller.draft.protocol;

    // 标题：这一行是**会变的那件事**。
    //
    // 已连接时只剩地址本身，不再冠一个 `IP ` —— 这一行没有第二个可能是
    // 地址的东西（副标题是上下行与时延），前缀只是一对多余的字符。
    final title = switch (controller.state) {
      SangforConnectionState.connected => controller.virtualAddress ?? '分配中',
      SangforConnectionState.error =>
        controller.errorMessage ?? controller.errorCode?.name ?? '连接失败',
      _ when !usable => '无可用协议',
      _ => protocol.label,
    };
    // 副标题：这一行是**补充**。
    final subtitle = switch (controller.state) {
      SangforConnectionState.connected =>
        '↑ ${formatRate(controller.uploadBytesPerSecond)}'
            ' · ↓ ${formatRate(controller.downloadBytesPerSecond)}'
            ' · 时延 '
            '${controller.latencyMs == null ? '—' : '${controller.latencyMs!.round()} ms'}',
      SangforConnectionState.error =>
        '${protocol.label} · ${controller.draft.server}',
      _ when !usable => '去设置里启用一个协议',
      _ => controller.draft.server,
    };
    final titleColor = !usable
        ? colors.warning
        : _failed
        ? colors.danger
        : _connected
        ? colors.textPrimary
        : colors.textPrimary;
    final subtitleColor = _connected
        ? colors.textSecondary
        : colors.textTertiary;

    // 左圆：字形永远是协议自己的，失败才换成警示。已连接只换颜色 ——
    // 一排图标里唯一能认出「走的哪条路」的就是它，不该被换掉。
    final (leadingIcon, leadingColor) = switch (controller.state) {
      SangforConnectionState.error => (Icons.error_outline, colors.danger),
      SangforConnectionState.connected => (protocol.icon, colors.success),
      _ when !usable => (Icons.block, colors.warning),
      _ => (protocol.icon, colors.accent),
    };

    return Padding(
      // 左边这 4 与下面那几组 `SectionHeader` 对齐 —— 一行裸字没有边框可
      // 依，就只能与别的行对齐。
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      child: Row(
        children: [
          Icon(leadingIcon, size: 22, color: leadingColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShuYoTextStyles.title(
                    size: 15.5,
                    weight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShuYoTextStyles.meta(color: subtitleColor),
                ),
              ],
            ),
          ),
          // 转圈只在真的在做事情的那三个状态出现。它是状态，不是把手 ——
          // 连上之后它消失，这一行就只剩那三样东西。
          if (_busy && !reduceMotion) ...<Widget>[
            const SizedBox(width: 8),
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: style.color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 把一个地址抄进剪贴板。按过之后变成对勾，**不自动变回来**。
///
/// 不做「一秒后恢复」：那需要一个 `Timer`，而这一层没有任何别的地方需要
/// 计时器；对勾留在那里本身也是「刚才抄的是这一个」的记号，比一闪而过的
/// 反馈更经看。
///
/// ## 为什么确认不靠一条 SnackBar
///
/// 抽屉里那两行地址上下挨着，而且长得几乎一样（只有端口不同）。一条从底
/// 下浮出来的长条看不出**是哪一行**被抄走了；对勾就落在被抄的那一行里，
/// 没有这个歧义。
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.value, required this.label});

  final String value;

  /// 无障碍标签用的名字（`复制 HTTP 代理`）。
  final String label;

  /// 按钮的边长。用 `IconButton` 的默认尺寸（40）会把地址框顶高，
  /// 而这一行的高度是被标题的字号决定的。
  static const double size = 30;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return IconButton(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: widget.value));
        if (!mounted) return;
        setState(() => _copied = true);
      },
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
        width: _CopyButton.size,
        height: _CopyButton.size,
      ),
      iconSize: 17,
      tooltip: _copied ? '已复制' : '复制${widget.label}',
      icon: Icon(
        _copied ? Icons.check : Icons.content_copy,
        color: _copied ? colors.accent : colors.textTertiary,
      ),
    );
  }
}
