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
/// * **拉开**：那一行往上走，恰恰好露出**协议的三个按钮**（连上之后还会
///   多出「连接方式」）。这一档是「我要改点什么」或者「我要抄一个地址」，
///   用完往下一推、或者点外面一下就回去了。
///
/// 拉开不靠点：把手能拖、抽屉里任意一处都能拖 —— 跟着手指走，松手吸附到
/// 最近那一档。两档之间的吸引子一共两个，也就没有「半开」这种状态需要解释。
///
/// ## 拉开那一档是**量出来的**，不是写死的一个数
///
/// 它等于抽屉里那一列内容的真实高度（见 [_ConnectionDrawerState._measure]）。
/// 写死一个数字要么把最后一行切掉（内容变多时——比如连上之后多出「连接方式」
/// 那几行），要么在内容少时于底部留下一片空白。两者都是「这块东西没做完」的
/// 长相，而难看的地方止于数字这一个来源。
///
/// 也因此，这一页的抽屉**永远不会出现滚动条**：拉到底就是内容的底。
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
/// 设置里关掉的协议**仍然占一格**，只是画成灰的、按不动（不是禁用一个功能，
/// 是把设置页那个开关的效果当场兜现出来）。隧道在跑时整排也按不动 —— 与
/// 「网络连接」那一页同一条规则，只是这里锁的是一段而不是整页。
///
/// **连接方式只在连上之后出现**。它们是结果而不是选择：断着的时候没有任何
/// 通道在跑，摆三行「已关闭」只是噪声；出现时也只列设置里开着的那几条。
class ConnectPage extends StatelessWidget {
  const ConnectPage({super.key});

  /// 抽屉里第一行那个 `Row` 的 key。
  ///
  /// 它给测试用：这一行是**唯一**能表示「抽屉停在哪一档」的锚点 —— 两种
  /// 档位下它都在树里（不像下面那几组可能落在缓存区外），而它的纵向位置
  /// 直接跟着档位走（拉开时整张单子被顶上去）。
  static const Key statusRowKey = ValueKey<String>('connect-status-row');

  /// 抽屉内容那一列的 key。
  ///
  /// 它给测试用：那一列的自然高度**就是**「拉开」那一档的高度（那正是这一
  /// 版要做的事），所以它是那条断言的基准 —— `getSize` 拿到的是自然高度
  /// 而不是视口高度，因为这个 `Column` 是 `SingleChildScrollView` 的孩子。
  static const Key contentKey = ValueKey<String>('connect-drawer-content');

  /// 协议那一排里的一个按钮。
  ///
  /// 那一排是手写的（不用 `SegmentedButton`），所以没有 `segments` 之类的
  /// 属性可供测试读取 —— 只能靠 key 定位到具体那一个再按下去，看行为。
  static Key protocolButtonKey(ShuProtocol protocol) =>
      ValueKey<String>('connect-protocol-${protocol.id}');

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
/// | 拉开 | 内容量出来的 | 那一行 + 协议那三个按钮（连上之后还有连接方式） |
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
/// ## 两档的高度都是**像素**换算出来的比例，不是写死的比例
///
/// 「未拉开」要刚好露出那一行字，那是一个固定的**像素**高度，与屏幕多高
/// 无关：写成 `0.2` 的话，矮屏会把那一行裁掉一截，而高屏会露出一大片空白。
///
/// 「拉开」要刚好露出**全部内容** —— 所以它是一个量出来的像素高度（见
/// [_ConnectionDrawerState._measure]），再除上可用高度换成比例。内容比屏幕
/// 还高时（矮屏）这个比例会被 `0.9` 截住，抽屉里于是可以滑；那种情况下
/// 拉到底确实是「还得再滑一下」，但那是内容太长，不是留白。
///
/// ## 隧道在跑时协议那一排只读，连接方式则**只在连上之后**出现
///
/// 前者与「网络连接」那一页同一条规则（那里是整页封住）。判据也一样简单：
/// 换协议只改 `draft`，隧道起来之后 `draft` 与 `state` 会分叉 —— 界面上
/// 写着 aTrust、实际跑着别的，是查不出来的那种不一致。
///
/// 后者是这一版改掉的：断着的时候没有一条通道在跑，「连接方式」整段都不画。
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

  /// 量到内容之前用的一个估计值。
  ///
  /// 第一帧必须给出一个合法的 `maxChildSize`（`DraggableScrollableSheet` 的
  /// 构造断言 `initialChildSize <= maxChildSize`），而内容高度要等布局完
  /// 才知道 —— 中间这一帧就用它顶着。内容的高度会在一帧之后把它盖掉，所以
  /// 这个数只影响「用户快得不可思议地在这一帧里就开始拖」的那种情形。
  static const double fallbackExpandedHeight = 420;

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

  /// 量内容高度用的锚点。
  ///
  /// 它挂在包住整列内容的那个 `Padding` 上（而不是 `SingleChildScrollView`
  /// 上）：后者量到的是**视口**高度，也就是抽屉当前多高 —— 拿它当「内容有
  /// 多高」会得到一个自我证实的循环。挂在里面才拿得到自然高度。
  final GlobalKey _contentKey = GlobalKey();

  /// 内容自然高度（含底部留白）。`null` = 还没量到。
  ///
  /// 它是**拉开那一档的全定义**：抽屉拉到底就是内容的底，多一个像素都不给。
  double? _contentHeight;

  /// 两档的比例。它们在 [build] 里由实际像素算出，存下来给 [_progress] 与
  /// [_toggle] 用 —— 那两个都发生在手势回调与帧中间，那里拿不到
  /// `LayoutBuilder` 的 `box`。
  double _min = 0;
  double _max = 1;

  /// 交给 `snapSizes` 的那个 list。
  ///
  /// **必须是同一个实例**：`DraggableScrollableSheet` 判「吸附点变没变」用
  /// 的是 `widget.snapSizes != oldWidget.snapSizes`，而 `List` 的 `==` 是
  /// 恒等比较 —— 每帧新建一个 list 会让它每次都以为变了（然后 post-frame
  /// 重新吸附一遍，把正在进行的拖拽打断）。
  List<double>? _snapSizes;

  /// 两档比例的比较容差。
  ///
  /// 它们是「像素 ÷ 可用高度」的商，同一份内容在相邻两帧里可能差一个 ulp ——
  /// 不给容差的话「尺寸没变」这件事永远判不成立。0.0005 × 可用高度在手机上
  /// 还不到一个像素。
  static const double _resizeEpsilon = 0.0005;

  /// 量一次内容高度，量到了就重建（[build] 里排的这一帧回调）。
  ///
  /// 为什么必须绕这一圈：`maxChildSize` 是构造参数，而内容高度要等布局完
  /// 才知道 —— 没有「先布局、再决定自己多高」这种写法。所以顺序是
  /// 「先用估计值拉起来 → 量 → 用真值重建」，中间那一帧的抽屉停在未拉开
  /// 那一档，用户看不到任何跳变。
  void _measure() {
    final box = _contentKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final height = box.size.height;
    final known = _contentHeight;
    // 半像素的容差：同一份内容在相邻两帧里可能因为布局取整差这一点点，
    // 不给容差就会来回 setState 到天荒地老。
    if (known != null && (height - known).abs() < 0.5) return;
    setState(() => _contentHeight = height);
  }

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

  /// **兜底**：容量在抽屉开着的时候变了，就直接把它收回去。
  ///
  /// 容量（[_min] / [_max]）只在两种时候变：内容真的换了（连接成功多出
  /// 「连接方式」那几行、断开又少回去），或者可用高度变了（旋屏、分屏拖动）。
  ///
  /// 不兜的话，那两种时候都会发生一件没法解释的事：
  ///
  /// * 容量**变大**：抽屉停在旧的那一档上不动，新露出来的几行被切掉半截 ——
  ///   看上去像内容没画全；
  /// * 容量**变小**：`DraggableScrollableSheet` 会把当前位置直接夹到新的
  ///   上限，抽屉当着用户的面往下跳一格。
  ///
  /// 「收回去」是这一页上用户已经会的一个动作（点外面、往下推都是它），
  /// 所以遇到就收回去，让用户自己再拉一次 —— 那时候量到的已经是新容量了。
  ///
  /// ## 为什么是**跳到**未拉开那一档，而不是动画过去
  ///
  /// 分屏拖动、旋屏这类改变会连着好几帧都在变，动画会被一帧一帧地重新
  /// 开始，抽屉以每帧一次的速度往下爬。跳过去没有这个问题：一帧到位，而且
  /// 已经在 [min] 上时 `updateSize` 会直接返回，不会空转。
  ///
  /// [wasOpen] 要在 [_min]/[_max] 被换掉**之前**读 —— [_progress] 是拿
  /// 当前位置与那两档比出来的，换了档位再问就没有意义了。
  void _collapseIfResized(
    double previousMin,
    double previousMax,
    bool wasOpen,
  ) {
    final resized =
        (previousMin - _min).abs() > _resizeEpsilon ||
        (previousMax - _max).abs() > _resizeEpsilon;
    // 停在未拉开那一档（或者还没挂上）时不用管 —— 「容量变了」对它是一件
    // 没有后果的事，它本来就只露那一行字。
    if (!resized || !wasOpen || !_sheet.isAttached) return;
    // 这一句是从 `LayoutBuilder` 的 builder 里调过来的，那里**跑在 layout
    // 里**（`LayoutBuilder` 就是在布局期 `buildScope`）—— 那种时候写
    // `updateSize` 的那个 `ValueNotifier` 会把旁支标脏，属于「构建期改状态」。
    // 排到这一帧画完之后再做。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheet.isAttached) return;
      _sheet.jumpTo(_min);
    });
  }

  void _animateTo(double size) {
    if (!_sheet.isAttached) return;
    _sheet.animateTo(size, duration: ShuMotion.base, curve: ShuMotion.curve);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    // 量内容高度只能在布局之后 —— 在 `build` 里 `setState` 会直接抛
    //「setState() or markNeedsBuild() called during build」。每帧排一个
    // 回调的代价可以忽略：`_measure` 在高度没变时会立刻返回。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });

    // 用**实际可用的高度**换算比例，不是屏幕高度：这一层被 appbar 与底栏
    // 夹在中间，两者的差在矮屏上能到一成，而「露出多少像素」正是两档的
    // 全部定义。
    return LayoutBuilder(
      builder: (context, box) {
        final min = (_ConnectionDrawer.peekHeight / box.maxHeight).clamp(
          0.06,
          0.24,
        );
        // 「拉开」那一档的高底就是内容本身。0.9 是一道保险：万一某一天
        // 内容真的比屏幕还高，抽屉也不能撑到顶（上面那颗圆是这一页的
        // 主角）—— 那种情况下抽屉里会滑。
        //
        // 下界只是 `min` 本身，**没有**任何「两档之间要差多少」的余量：
        // 那点余量会把抽屉撑得比内容高，正是这一版要去掉的那种空白。内容
        // 本来就比未拉开那一档高（那一行字 + 那排按钮），两档永远分得开。
        final max =
            ((_contentHeight ?? _ConnectionDrawer.fallbackExpandedHeight) /
                    box.maxHeight)
                .clamp(min, 0.9);
        // 这一帧之前它是不是「开着」。必须在下面那两行赋值**之前**读 ——
        // [_progress] 是拿当前位置与当前那两档比出来的。
        final wasOpen = _progress > 0.01;
        final previousMin = _min;
        final previousMax = _max;
        _min = min;
        _max = max;
        // 容量变了就把开着的抽屉收回去（见 [_collapseIfResized]）。
        _collapseIfResized(previousMin, previousMax, wasOpen);
        final snapSizes = _snapSizes;
        if (snapSizes == null || snapSizes[0] != min || snapSizes[1] != max) {
          _snapSizes = <double>[min, max];
        }

        // 遮罩与抽屉是**兄弟**，不是「包着抽屉的监听器」。
        //
        // ⚠ 这一条不是排版偏好，是必须的。`DraggableScrollableSheet` 在
        // 容量变化、当前位置被夹新的时候会**同步** `notifyListeners()`
        // （`_onExtentReplaced`，见 `draggable_scrollable_sheet.dart`），
        // 而那一刻我们正在 `LayoutBuilder` 的**布局期构建**里（它就是在
        // layout 里跑 `buildScope` 的）。如果听这个控制器的 `AnimatedBuilder`
        // 是抽屉的**祖先**，那一句 notify 就会在它自己 `performRebuild`
        // 还没结束时把它标脏 —— `Element.rebuild` 末尾的 `assert(!_dirty)`
        // 当场炸掉（"Failed assertion: '!_dirty' is not true"）。
        //
        // 换成兄弟之后，那句 notify 标脏的是一个**旁支**：它同样在这次
        // 构建范围内（所以不会被拦下），但它并不在重建中，于是什么事都没有。
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 遮罩。它在抽屉**下面**（`Stack` 里后画的在上面），盖住的
            // 就是抽屉没占的那一块 —— 也就是大圆。
            AnimatedBuilder(
              animation: _sheet,
              builder: (context, _) => IgnorePointer(
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
            ),
            DraggableScrollableSheet(
              controller: _sheet,
              initialChildSize: min,
              minChildSize: min,
              maxChildSize: max,
              // 两个吸引子，没有中间态 —— 这就是「两段式」。
              snap: true,
              snapSizes: _snapSizes,
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
                  // `SingleChildScrollView` 而不是 `ListView`：这一列内容
                  // **必须是一个整体**才能量出自然高度 —— `ListView` 把每
                  // 一行当成独立的孩子，那里面没有一个东西的高度是「内容
                  // 一共多高」。
                  //
                  // 换成它不会影响拖拽：`DraggableScrollableSheet` 判「这一下
                  // 该移动自己还是该滚列表」用的是 `pixels > 0` 与两档的边界，
                  // **不看** `maxScrollExtent`（见 `draggable_scrollable_sheet.dart`
                  // 的 `applyUserOffset`）。所以在未拉开那一档（内容露不全、
                  // `maxScrollExtent > 0`）向上拖是抽屉长大；拉到内容高度之后
                  // `maxScrollExtent` 正好是 0，也就正好停住 ——「不多给一个
                  // 像素」这件事是内容高度算出来的结果，不是另写的一道判断。
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: Padding(
                      key: _contentKey,
                      padding: const EdgeInsets.fromLTRB(
                        ShuSpacing.page,
                        0,
                        ShuSpacing.page,
                        16,
                      ),
                      child: Column(
                        key: ConnectPage.contentKey,
                        mainAxisSize: MainAxisSize.min,
                        // `ListView` 给每个孩子的是紧宽度约束，这里要保持
                        // 一样 —— 不然居中的小组件（把手那根横条）会缩成
                        // 自己那么宽，命中区跟着变小。
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _DrawerGrabber(
                            key: ConnectPage.grabberKey,
                            onTap: _toggle,
                          ),
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
              ),
            ),
          ],
        );
      },
    );
  }

  /// 拉开之后才看得见的那一截。
  ///
  /// 两块内容的出现条件不同，理由也不同：
  ///
  /// * **协议** —— 任何状态下都在。它是这一页唯一的**选择**（「从哪条路
  ///   走」），而选择要在能改的时候改：设置里关掉的按不动，隧道一起来
  ///   整排也按不动；
  /// * **连接方式** —— **只在连上之后出现**（这一版改掉的就是它原先
  ///   任何状态下都摆着这件事）。它是**结果**不是选择：断着的时候没有
  ///   任何通道在跑，三行「已关闭」只是噪声；而且只列设置里开着的那几路
  ///   （另外那几路本来就不会走）。
  ///
  /// 形状学的是设置页：图标 + 名字 + 右侧当前值，没有卡片、没有分割线，
  /// 行与行之间只靠距离分组。这一页里用同一个形状还有一个好处 —— 抽屉拉开
  /// 之后从上到下是一条列，而不是一片控件。
  List<Widget> _sections(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final colors = context.shuyoColors;
    final controller = widget.controller;
    // 「成功连上」是「连接方式」出现的**唯一**条件；协议的只读还多一种：
    // 正在连（`busy`）时也不该改 —— 那时已经有一份 `state` 在路上了。
    final connected = controller.state == SangforConnectionState.connected;
    final locked = controller.busy || connected;
    final selected = controller.draft.protocol;

    // 只列「设置里开着」或者「此刻真的在跑」的通道。后半句不是冗余：系统
    // VPN 会把 HTTP 通道**强制**拉起来（它的 TCP 那半边全靠它），那种时候
    // 即使 `httpProxyEnabled` 是关的，那个地址也确实是系统代理指向的地方。
    final channels = <Widget>[
      if (settings.httpProxyEnabled || controller.httpProxyRunning)
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
      if (settings.socksProxyEnabled || controller.socksProxyRunning)
        _DrawerRow(
          icon: Icons.settings_ethernet,
          title: 'SOCKS5 代理',
          trailing: _CopyableValue(
            value: controller.proxyAddress,
            label: 'SOCKS5 代理地址',
          ),
        ),
      if (settings.vpnEnabled || controller.vpnRunning)
        _DrawerRow(
          icon: Icons.vpn_lock_outlined,
          title: 'Android VPN 服务',
          trailing: ShuStatusSlot(
            // 这一行说的是**接口建起来没有**，不是「设置里开着没有」——
            // 开着却没起来正是要看的那种状态，用设置值回答等于什么都没说。
            text: controller.vpnRunning ? '已启用' : '已关闭',
            color: controller.vpnRunning ? colors.accent : colors.textMuted,
          ),
        ),
    ];

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
      _ProtocolTabs(
        selected: selected,
        isEnabled: settings.isProtocolEnabled,
        // 隧道在跑（或正在连）时整排只读 —— 与「网络连接」那一页同一条规则：
        // 换协议只改 `draft`，而那一刻 `draft` 已经与 `state` 分叉了。
        onSelected: locked ? null : controller.selectProtocol,
      ),
      // 连接方式是**结果**，所以只在有结果的时候出现。
      if (connected) ...<Widget>[
        const SectionHeader(title: '连接方式'),
        if (channels.isEmpty)
          // 连上了却一个通道都没开：隧道在，流量没有出口。说出来比留一片
          // 空白强 —— 那种时候用户正在问「为什么连上了还是打不开网页」。
          const _DrawerRow(
            icon: Icons.block,
            title: '没有启用的连接方式',
            enabled: false,
          )
        else
          ...channels,
      ],
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

/// 三选一的协议选择条 —— 并排三段，每段一个图标加一个名字。
///
/// ## 它是**手写的**，不是 `SegmentedButton`
///
/// Material 的 `SegmentedButton` 画出来是一条被描边圈住的横条：三段共用
/// 一圈外框，段与段之间再画竖线。那是「一组选项」的长相，而这个应用里
/// 唯一一处「选中态长什么样」已经在底栏定下来了 —— 图标底下垫一颗
/// `accentSoft` 胶囊、文字用强调色。两处不一致会让人觉得这是两个不同的
/// 东西，而它们其实是同一件事（在几个里挑一个）。
///
/// 手写之后还顺带拿回了三样 `SegmentedButton` 给不了的东西：
///
/// * 三态（选中 / 能选 / 灰掉）的颜色直接写在这一段里，不必绕一层
///   `WidgetStateProperty` 去猜它什么时候算 disabled；
/// * 图标与文字的位置完全由这里决定（`ButtonSegment.icon` 一旦非空，
///   `SegmentedButton` 会改用自己算的一套内边距，并强制图标与文字并排）；
/// * 水波纹用的就是底栏那颗胶囊（[ShuIndicatorInkResponse]）。
///
/// ## 为什么是一排，而不是三行列表
///
/// 三行列表让每一行独占整行，读起来像设置页，但它要花掉 144 像素 —— 等于把
/// 抽屉拉开那一档的一大半花在一个「改一次就不动」的选择上。横着排只占一行，
/// 而这一档里的东西越短越好：它的上面是一颗大圆，下面是一列状态。
///
/// ## 一格一百出头，所以图标**叠在文字上面**
///
/// 横条在抽屉里被拉满整行，三段平分之后每格只有一百出头的逻辑像素。
/// `EasyConnect` 十一个字母本来就快占满，图标要是并排放在旁边还要再花二十
/// 几个像素 —— 那一格会被挤成两行。叠起来之后每格需要的就是**文字本身**
/// 那么宽，与底栏那三项的排法也正好一致。
///
/// ## 选不了的那几段是**灰的**，不是藏起来的
///
/// 设置里没开的协议照样占一格：那个位置将来会有一个可选的东西，藏起来只会
/// 让人以为漏了。灰掉的段自己按不动（[_ProtocolButton.enabled] 为假），整排
/// 在连接期间也按不动（`onSelected` 为 null）。
class _ProtocolTabs extends StatelessWidget {
  const _ProtocolTabs({
    required this.selected,
    required this.isEnabled,
    required this.onSelected,
  });

  /// 现在选中的那一条。
  final ShuProtocol selected;

  /// 设置里这一条开着没有。为 false 的那一段画成灰的、按不动。
  final bool Function(ShuProtocol) isEnabled;

  /// 为 null 时整排只读（正在连或隧道在跑）。
  final ValueChanged<ShuProtocol>? onSelected;

  @override
  Widget build(BuildContext context) {
    final locked = onSelected == null;
    return Row(
      children: <Widget>[
        for (final protocol in ShuProtocol.values)
          Expanded(
            child: _ProtocolButton(
              key: ConnectPage.protocolButtonKey(protocol),
              protocol: protocol,
              selected: protocol == selected,
              // 整排只读与单段关掉在这里合成一个结果 —— 底下那一段只需要
              // 知道「按不按得动」，不必自己判两个条件。
              enabled: !locked && isEnabled(protocol),
              onTap: () => onSelected?.call(protocol),
            ),
          ),
      ],
    );
  }
}

/// 协议选择条里的一段。
///
/// 排法与底栏的一项**逐字相同**（`floating_dock.dart` 的 `_DockItem`）：
/// 一颗胶囊垫在图标底下（未选中时宽度为 0）、文字在它下面、整块的水波纹
/// 被锁在那颗胶囊上。两者唯一的差别是这里的胶囊矮 2 像素、图标小 2 像素 ——
/// 底栏是「应用的一级导航」，这里是「抽屉里的一个控件」，不该一样重。
///
/// ## 胶囊锚点为什么是一颗空盒子
///
/// 它不参与绘制，只用来把水波纹的矩形锁到 64×30 那一块上。之所以不复用会
/// 动画的那个 `AnimatedContainer`：未选中时它的宽度是 0，拿它算出来的矩形
/// 也是 0 宽，水波纹就整个看不见了。（这一段的写法与底栏同源，理由也一样。）
class _ProtocolButton extends StatefulWidget {
  const _ProtocolButton({
    super.key,
    required this.protocol,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ShuProtocol protocol;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  /// 选中胶囊的尺寸。与底栏那颗同源（`NavigationBar` 的 `_kIndicatorWidth` /
  /// `_kIndicatorHeight`），只是矮 2 像素。
  static const Size indicatorSize = Size(64, 30);

  /// 图标比底栏那 22 小 2 —— 这一排是抽屉里的一行，不是导航栏。
  static const double iconSize = 20;

  @override
  State<_ProtocolButton> createState() => _ProtocolButtonState();
}

class _ProtocolButtonState extends State<_ProtocolButton> {
  /// 胶囊的位置来源。见 [_ProtocolButton] 的类注释。
  final GlobalKey _indicatorAnchor = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = context.shuyoColors;
    final selected = widget.selected;
    final enabled = widget.enabled;

    // 三态一次判完，而不是把颜色散在三处：它们是同一件事（这个按钮现在
    // 是什么状态）的三个答案，分开写迟早会有一个忘了跟着改。
    final (iconColor, labelColor) = switch ((enabled, selected)) {
      // 灰掉：设置里没开，或者隧道正在跑 —— 两种原因，同一种长相。
      (false, _) => (colors.textMuted, colors.textMuted),
      // 选中：与底栏完全同一套读法（垫色上的墨 + 强调色文字）。
      (true, true) => (colors.onAccentSoft, colors.accent),
      // 能按但没选中：安静，但不像灰掉那样退到背景里。
      (true, false) => (scheme.onSurfaceVariant, scheme.onSurfaceVariant),
    };

    return Semantics(
      selected: selected,
      enabled: enabled,
      button: true,
      label: widget.protocol.label,
      child: Material(
        type: MaterialType.transparency,
        child: ShuIndicatorInkResponse(
          anchorKey: _indicatorAnchor,
          // 按不动时连水波纹也没有 —— `InkResponse` 的 `onTap` 为 null
          // 就不再响应手势。
          onTap: enabled ? widget.onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    SizedBox(
                      key: _indicatorAnchor,
                      width: _ProtocolButton.indicatorSize.width,
                      height: _ProtocolButton.indicatorSize.height,
                    ),
                    AnimatedContainer(
                      duration: ShuMotion.base,
                      curve: ShuMotion.curve,
                      height: _ProtocolButton.indicatorSize.height,
                      width: selected ? _ProtocolButton.indicatorSize.width : 0,
                      decoration: BoxDecoration(
                        color: selected
                            ? colors.accentSoft
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(ShuRadii.pill),
                      ),
                    ),
                    Icon(
                      widget.protocol.icon,
                      size: _ProtocolButton.iconSize,
                      color: iconColor,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  widget.protocol.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 与底栏同一个样式（`labelSmall` = 12/w500）—— 同样的字号
                  // 在两个地方承担同一件事「这一格叫什么」。
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: labelColor,
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

/// 抽屉里的一行 —— 形状学的是设置页那种「图标 + 名字 + 右侧当前值」。
///
/// 它现在只服务「连接方式」那几行（协议是一排按钮，见 [_ProtocolTabs]），
/// 那几行都是**只读**的观测：地址是要抄走的、VPN 那一行说的是接口建起来
/// 没有 —— 没有一件是能按的，所以这一行连 `onTap` 都不收。
///
/// ## 「关掉」与「没开」是两件事
///
/// [enabled] 为假的行褪色（唯一这么用的地方是「一个通道都没开」那句陈述）。
/// 设置里关掉的通道**根本不出现**，而不是画成灰的 —— 与协议那一排刚好相反，
/// 因为协议是「这个位置将来会有一个选择」，通道是「现在到底走哪条路」。
class _DrawerRow extends StatelessWidget {
  const _DrawerRow({
    required this.icon,
    required this.title,
    this.trailing,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return ListTile(
      enabled: enabled,
      // left/right 各 4 与上面那一行字、与组标题对齐；`compact` 把行高压到
      // 48 —— 这一组要的是紧凑，而设置页那几行是 56 起步（它每行都是一项
      // 设置，这一页只是一列「现在怎么连着」）。
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
