import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/app_info.dart';
import '../../app/page_transitions.dart';
import '../../app/shu_launch_surface.dart';
import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/auth/auth_constants.dart';
import '../../core/connection/connection_controller.dart';
import '../../core/settings/settings_store.dart';
import '../../widgets/shu_surfaces.dart';
import '../account/login_form.dart';

/// 引导第 1 页要申请的一项系统权限。
///
/// 写成枚举（而不是散在页面里的几个常量）是因为这一页有三处要按它对齐：
/// 行首的图标、行尾的状态词、以及底部按钮的启用条件 —— 共用一份定义，将来
/// 加权限时才不会漏掉某一处。
///
/// 目前只有一项。Android 上真能申请的也只有它：VPN 服务授权（`VpnService`）。
/// 通知、电池优化白名单之类将来要加的话，在这里加一个值、在
/// `_requestPermission` 里补一条分派即可，版式不用动。
enum _ShuPermission {
  /// Android 的 `VpnService` 授权 —— 建立隧道的前提。
  vpn(
    icon: Icons.vpn_lock_outlined,
    title: 'VPN 服务',
    description: 'ShuVPN 默认使用 Android 的 VPN 接口建立隧道',
  );

  const _ShuPermission({
    required this.icon,
    required this.title,
    required this.description,
  });

  /// 行首图标 —— 与设置页里「启用 VPN 服务」那一行同一个。
  final IconData icon;

  /// 列表里那一行的标题。
  final String title;

  /// 标题下面那行小字：说清这一项是干什么用的。
  final String description;
}

/// 新用户引导 —— 三页，一页一件事。
///
/// 它是**首启的第一个界面**（不是弹窗、也不是可以划掉的浮层）：路由在
/// `settings.welcomeCompleted == false` 时把一切重定向到这里，所以用户要到
/// 第 3 页登录成功才走得到主页。三页分别对应「没做完就用不了」的三件事：
///
/// | 页 | 内容 | 做完的条件 |
/// | :--- | :--- | :--- |
/// | 0 | 这个应用是干什么的 | 按下「继续」 |
/// | 1 | 逐项申请系统权限 | 列表里的每一项都已授权 |
/// | 2 | 登录校园账户 | `ShuLoginForm` 走完并交换到凭据 |
///
/// ## 第 1 页是一张清单，不是一颗按钮
///
/// 它不靠底部按钮去申请：正文是一张**裸列表**（无卡片、无边框），一行一项
/// 系统权限，**点行本身就是申请**；底部的按钮要到列表全绿才解禁。这样
/// 「还差哪一项」是看得见的 —— 一颗「去授权」按钮只能告诉用户「有事没做完」。
///
/// 行用的形状照抄「账号管理」里那几行凭据（`AccountPage._CredentialRow`）：
/// `ListTile` + 左侧图标 + 正文 + 右侧 [ShuStatusSlot]。状态的词与色也共用
/// 同一个函数（[shuVpnPermissionStatus]），所以「已授权」在这一页和在设置页
/// 逐字逐色一致 —— 用户在两个地方不用各学一次读法。
///
/// 状态的真值在 [ConnectionController] 里，这一页只是转述。页面自己再记一份
/// （「我点过、它答应了」）看着省事，但那是第二个答案：用户到系统设置里把授权
/// 撤掉之后，页面还挂着一个勾、设置页却已经写着「未授权」。
///
/// 非 Android 上清单为空（没有系统 VPN 这回事），「全部申请到」自动成立、
/// 按钮直接可点 —— 与 [ConnectionController.ensureVpnPermission] 在非 Android
/// 上返回 true 是同一条思路：没有这项权限的地方，不该被它挡住。
///
/// ## 版式来源
///
/// 第 0 页照 `ShuYo` 的 `StartupOnboarding._welcome` 抄：居中的图标 + 大标题、
/// 三条「图标 / 标题 / 说明」，页脚一行小字。改的只有文案与三个图标
/// （那边讲课表与校园服务，这边讲隧道与认证）。
///
/// 与那边不同的一处：ShuYo 把这些页放在一块**从底部升起的面板**里，因为它
/// 同时还负责「从主页再打开一次账号管理」。这里没有那个用途 —— 引导就是
/// 引导 —— 所以改成整屏，顶部留一条返回键栏、底部一个按钮。
///
/// ## 翻页是滑动，不是切换
///
/// 三页装在 `PageView` 里，翻页走 `nextPage` / `previousPage`（320ms /
/// 280ms，`easeOutCubic`），所以相邻两页是**横向推过去**的；而
/// `NeverScrollableScrollPhysics` 关掉了手势 —— 前进必须经过按钮，因为
/// 第 1 页要等清单全绿（底部按钮才会解禁）。手势滑过去会绕过那道检查。
///
/// ## 登录复用账户管理那一套
///
/// 第 2 页按下的按钮不是跳转到别处，而是**把这一页换成登录表单** —— 与
/// `AccountPage` 完全相同的两状态结构（`_signingIn`），用的是同一个
/// [ShuLoginForm]，因此两步验证、企业微信扫码、凭据过渡页的行为逐字一致。
/// 换的这一下也是同一个 [ShuSharedAxisXSwitcher]（登录表单从右侧滑进来、
/// 三页往左让出去）。
///
/// 登录完成后写 `welcomeCompleted` 并 `go('/connect')`，落到首页。
class ShuWelcomePage extends StatefulWidget {
  const ShuWelcomePage({super.key});

  /// 前进的动画时长与曲线，与 `ShuYo` 的 `_continue` 逐字一致。
  static const Duration forwardDuration = Duration(milliseconds: 320);
  static const Duration backwardDuration = Duration(milliseconds: 280);
  static const Curve pageCurve = Curves.easeOutCubic;

  /// 第 1 页的副标题。
  ///
  /// 系统权限只有 Android 有，所以这句话要分平台：Android 上先点明「现在在
  /// 什么系统上、接下来要干什么」，别的平台没有这回事（它们走本机代理）。
  ///
  /// [isAndroid] 只为测试留 —— 真实调用方传的是
  /// [ConnectionController.vpnSupported]，那边才是要去调原生的地方。
  static String permissionSubtitle({bool? isAndroid}) =>
      (isAndroid ?? Platform.isAndroid)
      ? '当前使用 Android 系统，需要申请以下权限'
      : '无需系统 VPN 授权';

  @override
  State<ShuWelcomePage> createState() => _ShuWelcomePageState();
}

class _ShuWelcomePageState extends State<ShuWelcomePage> {
  final _pages = PageController();
  final _loginFormKey = GlobalKey<ShuLoginFormState>();

  int _page = 0;

  /// 是否已经把这一页换成登录表单（第 2 页的状态，不是第 4 页）。
  bool _signingIn = false;

  /// 正等系统授权对话框 / 正翻页。为真时清单、按钮与返回键都不可点。
  bool _busy = false;

  /// 授权被拒之后页内留下的那句话。非空时第 1 页多一行警示。
  String? _permissionNotice;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 权限状态

  /// 授权那件事的唯一真值在 [ConnectionController] 里 —— 这里只是转述。
  ConnectionController get _connection => context.read<ConnectionController>();

  /// 第 1 页要申请的那几项。
  ///
  /// 非 Android 上是空的：那里没有系统 VPN 授权这回事，清单不该摆出一行
  /// 永远拿不到的东西。空清单让「全部申请到」自动成立。
  ///
  /// 平台判断问控制器而不是自己看 `Platform`：真要去调原生的就是那一层
  /// （见 `ShuVpnPermission`），两边各判一次迟早会不一样。
  List<_ShuPermission> _requirements(ConnectionController connection) =>
      connection.vpnSupported
      ? _ShuPermission.values
      : const <_ShuPermission>[];

  /// 这一项现在是什么状态。`null` = 还没问过系统。
  bool? _stateOf(ConnectionController connection, _ShuPermission permission) =>
      switch (permission) {
        _ShuPermission.vpn => connection.vpnPrepared,
      };

  /// 清单里的每一项都拿到了 —— 底部按钮据此解禁。
  bool _allGranted(ConnectionController connection) =>
      _requirements(connection).every((p) => _stateOf(connection, p) == true);

  // ------------------------------------------------------------------ 流程

  Future<void> _advance() async {
    if (_busy) return;
    switch (_page) {
      case 0:
        await _open(1);
      case 1:
        // 按钮此刻必然可点（没全绿时它是灰的），这一行只是把「第 1 页做的事
        // 就是拿到那些权限」这条不变量写在必经之路上。
        if (!_allGranted(_connection)) return;
        await _open(2);
      default:
        _setSigningIn(true);
    }
  }

  Future<void> _back() async {
    if (_busy) return;
    if (_signingIn) {
      _setSigningIn(false);
      return;
    }
    if (_page == 0) return;
    await _open(_page - 1, forward: false);
  }

  /// 三页 ⇄ 登录表单。
  ///
  /// 这里只切**逻辑**状态 —— 视觉上的滑动由 [ShuSharedAxisXSwitcher] 演，位置
  /// 由它自己算。分开是必要的：返回键与按钮要在按下的那一刻就切过去，不能等
  /// 动画。
  void _setSigningIn(bool value) {
    if (_signingIn == value) return;
    if (!value) {
      // 表单不再被卸载（见 [ShuSharedAxisXSwitcher] 的类文档），所以焦点得自己
      // 收：否则键盘会跟着一块被藏起来的输入框留在屏幕上。
      FocusManager.instance.primaryFocus?.unfocus();
    }
    _loginFormKey.currentState?.reset();
    setState(() => _signingIn = value);
  }

  Future<void> _open(int page, {bool forward = true}) async {
    setState(() {
      _busy = true;
      if (forward) _permissionNotice = null;
    });
    await _pages.animateToPage(
      page,
      duration: forward
          ? ShuWelcomePage.forwardDuration
          : ShuWelcomePage.backwardDuration,
      curve: ShuWelcomePage.pageCurve,
    );
    if (!mounted) return;
    setState(() {
      _page = page;
      _busy = false;
    });
    // 落到权限页就先问一次系统：授权可能在系统设置里被撤掉（判断真值的
    // 那一层自己也记不住——它每次都要重新问），而这一页的按钮要按真值
    // 解禁。与设置页进入时的做法一样。
    if (page == 1) unawaited(_connection.refreshVpnPermission());
  }

  /// 点第 1 页清单里的某一项：弹系统对话框申请它。
  ///
  /// **不翻页** —— 翻页是底部按钮的事，而它要等清单全绿才解禁。所以「被拒」
  /// 的后果只是这一项没打勾：用户可以直接再点一次，拒绝不是终局。
  Future<void> _requestPermission(_ShuPermission permission) async {
    final connection = _connection;
    if (_busy || _stateOf(connection, permission) == true) return;
    setState(() {
      _busy = true;
      _permissionNotice = null;
    });
    // 每一项各自的申请入口。现在只有 VPN 一项 —— 走的就是设置页那一个，
    // 结论也直接写回控制器，页面不会自己再存一份。
    final requester = switch (permission) {
      _ShuPermission.vpn => connection.requestVpnPermission,
    };
    final granted = await requester();
    if (!mounted) return;
    setState(() {
      _busy = false;
      // 没拿到时那一行右侧已经写着「未授权」了（状态词由共享函数给），这里
      // 只需要补上**怎么办** —— 再说一遍「没授权」是同一句话讲两遍。
      if (!granted) {
        _permissionNotice = '可以再点一次这一项，或到系统设置的 VPN 里重新授权。';
      }
    });
  }

  /// 登录成功。写标记 → 回首页。
  ///
  /// 写标记**必须在 `go` 之前**：路由的 `redirect` 会读它，「还没写完就跳」
  /// 会被原地弹回这一页。`SharedPreferences` 的内存缓存是同步更新的，
  /// 所以紧接着的这一次跳转就能看到 true。
  void _finishLogin() {
    _loginFormKey.currentState?.reset();
    context.read<SettingsStore>().welcomeCompleted = true;
    if (!mounted) return;
    context.go('/connect');
  }

  // ------------------------------------------------------------------ 视图

  @override
  Widget build(BuildContext context) {
    // `watch` 而不是 `read`：授权状态会在这一页上变（点一下、或进页时问
    // 一次系统），清单里的状态词与底部按钮都要跟着重画。
    final connection = context.watch<ConnectionController>();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _topBar(context),
            Expanded(
              // 登录表单**滑进来盖在**三页之上，而不是把 `PageView` 换掉。
              //
              // 换掉（`_signingIn ? form : PageView`）看起来更直白，但会毁掉
              // 「现在在第几页」这件事：`PageView` 一旦被移出树，控制器的
              // position 就没了，放回来时新的一份从 `initialPage`（0）重新
              // 开始，而 `_page` 还停在 2 —— 底部按钮说的是一页、内容是另一页。
              //
              // 按钮与三页装在**同一块**里，登录表单占的是整块（连按钮那一条
              // 也算）—— 两边高度因此完全一样，换页过程中布局一动不动，只是
              // 整块往左让出去。
              child: ShuSharedAxisXSwitcher(
                showFront: _signingIn,
                front: _loginForm(),
                back: Column(
                  children: [
                    Expanded(
                      child: PageView(
                        controller: _pages,
                        // 前进必须按按钮：第 1 页的「下一页」要等系统对话框有
                        // 结论，手势滑过去会把那道检查绕开。
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          _welcome(context),
                          _permission(context, connection),
                          _login(context),
                        ],
                      ),
                    ),
                    _footer(context, connection),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部：只有一条返回键，没有标题。
  ///
  /// 不标题化是有意的 —— 标题就在下面几十像素处的大字里（每页一个），
  /// 顶上再写一遍等于同一句话说两遍。登录状态下这里也管返回（退回第 2 页），
  /// 所以它与 `ShuAppBar` 的 `onBack` 语义一致。
  Widget _topBar(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          if (_page > 0)
            IconButton(
              tooltip: '返回',
              onPressed: _busy ? null : _back,
              icon: const Icon(Icons.arrow_back),
            )
          else
            // 槽位**无论有没有东西都占满**：否则第 0 页的内容会比第 1 页
            // 宽 48，翻页时下面的图标与文字会横跳。
            const SizedBox(width: 56),
        ],
      ),
    );
  }

  Widget _loginForm() => ShuLoginForm(
    key: _loginFormKey,
    onChanged: () => setState(() {}),
    onCompleted: _finishLogin,
  );

  // --------------------------------------------------------------- 第 0 页

  Widget _welcome(BuildContext context) => _layout(
    context,
    header: _header(context, title: '欢迎使用 ${ShuAppInfo.name}'),
    children: [
      _feature(Icons.shield_moon_outlined, '加密隧道', '校园流量经学校网关转发'),
      _feature(Icons.lan_outlined, '校内资源直连', '在校外也能访问图书馆与内网站点'),
      _feature(Icons.badge_outlined, '统一身份认证', '使用上海大学校园账户登录'),
    ],
    pageFooter: _disclaimer(context),
  );

  // --------------------------------------------------------------- 第 1 页

  Widget _permission(BuildContext context, ConnectionController connection) {
    final requirements = _requirements(connection);
    return _layout(
      context,
      header: _header(
        context,
        title: '权限管理',
        subtitle: ShuWelcomePage.permissionSubtitle(
          isAndroid: connection.vpnSupported,
        ),
      ),
      children: [
        // 裸列表：一行一项，行本身就是申请入口（点一下弹系统对话框）。
        for (final permission in requirements)
          _permissionRow(context, connection, permission),
        // 非 Android 上清单是空的，这行小字也就没有对象可说了。
        if (requirements.isNotEmpty) _revokeHint(context),
        if (_permissionNotice != null) _notice(context, _permissionNotice!),
      ],
    );
  }

  // --------------------------------------------------------------- 第 2 页

  /// 第 2 页：登录前的数据说明 + 将要连上的系统清单。
  ///
  /// **正文与承诺分开写**：正文说「这次登录做什么」（账户信息交给谁、换回来
  /// 什么、拿去干什么），承诺单独交给 [pageFooter] —— 它固定停在按钮**上方**
  /// 的一格，与第 0 页那行免责声明是同一个位置、同一种语气。分开的理由是这两
  /// 件事的读法不同：前者要读懂，后者看一眼就够了。
  ///
  /// 都用 Apple 的「数据与隐私」句式：一句一件事，主语在每个分句里点明
  /// （谁做的、对谁做），读的人不用回头猜。
  ///
  /// 正文下面那张清单是**将要连上的系统**，与「账户管理」里那三行同一条定义
  /// （[ShuSystemTile]）—— 图标、名字、域名逐字一致：用户登录后在那一页看到的
  /// 东西，在这里已经认识过一遍。
  Widget _login(BuildContext context) => _layout(
    context,
    header: _header(context, title: '登录校园账户', subtitle: '使用上海大学统一认证系统'),
    children: [
      _paragraph(
        '您的上海大学校园账户信息将交给上海大学，用于让您安全登录并访问校内资源。'
        'ShuVPN 凭这次授权向各业务系统换取凭据，用于建立隧道。',
      ),
      for (final target in ShuOAuthTargets.visible)
        ShuSystemTile(kind: target.kind),
    ],
    pageFooter: _privacyNote(context),
  );

  // ------------------------------------------------------------- 公共零件

  /// 一页的骨架：可滚动的正文 + 可选的页脚。
  ///
  /// 正文放进 `SingleChildScrollView` 是因为小屏 + 大字体下这三页都会溢出，
  /// 而按钮**必须固定在底部** —— 它跟着内容滚走的话，最后一屏会看不到「继续」。
  Widget _layout(
    BuildContext context, {
    required Widget header,
    required List<Widget> children,
    Widget? pageFooter,
  }) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [header, const SizedBox(height: 28), ...children],
            ),
          ),
        ),
        if (pageFooter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: pageFooter,
          ),
      ],
    );
  }

  Widget _header(
    BuildContext context, {
    required String title,
    String? subtitle,
  }) {
    final colors = context.shuyoColors;
    return Center(
      child: Column(
        children: [
          Image.asset(
            ShuLaunchSurface.iconAssetFor(colors.brightness),
            width: 88,
            height: 88,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            // 26 是这套版式里的「大标题」：比 `headerTitle`(17.5) 大一档半，
            // 与 ShuYo 那边 28 的观感一致（那边用的是 `headlineSmall`）。
            style: ShuYoTextStyles.title(
              color: colors.textPrimary,
              size: 26,
              weight: FontWeight.w500,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
            ),
          ],
        ],
      ),
    );
  }

  /// 清单里的一行。
  ///
  /// 形状照抄「账号管理」里那几行凭据（`AccountPage._CredentialRow`）：
  /// `ListTile` + 左侧图标 + 右侧 [ShuStatusSlot]。状态是**文字 + 语义色**，
  /// 图标不染色 —— 颜色留给状态，图标保留它自己的语义，色盲用户也读得出。
  ///
  /// 状态槽放在 `title` 那一行的尾端，**不是** `ListTile.trailing` ——
  /// 这是与账号管理唯一的不同，也是被逼出来的：`ShuStatusSlot` 是定宽的
  /// 118，而 `trailing` 会把这一整列的宽度从标题**和副标题**里一起扣掉。
  /// 那边没有副标题所以无所谓，这里副标题是整句话 —— 塞进被扣剩的窄条里
  /// 会断成四行。挂到 `title` 行上之后副标题独占一行，状态词仍落在同一个
  /// 右边界（`trailing` 为空时正文列一直铺到行的右内边距）。
  ///
  /// 比那几行多的一笔：没拿到时右边再排一个箭头。账号管理那几行是**纯只读**
  /// 的，这一行不是 —— 点它就是去申请。拿到之后箭头收掉，与设置页里那行
  /// 「系统授权状态」同一个做法（`SettingsRow` 只在可点时画箭头）。
  Widget _permissionRow(
    BuildContext context,
    ConnectionController connection,
    _ShuPermission permission,
  ) {
    final colors = context.shuyoColors;
    final prepared = _stateOf(connection, permission);
    final status = shuVpnPermissionStatus(
      context,
      supported: connection.vpnSupported,
      prepared: prepared,
    );
    final actionable = !_busy && prepared != true;
    return ListTile(
      leading: Icon(permission.icon),
      title: Row(
        children: [
          Expanded(
            child: Text(
              permission.title,
              style: ShuYoTextStyles.bodyCompact(color: colors.textPrimary),
            ),
          ),
          ShuStatusSlot(text: status.text, color: status.color),
          if (actionable) const Icon(Icons.chevron_right),
        ],
      ),
      subtitle: Text(
        permission.description,
        style: ShuYoTextStyles.meta(color: colors.textTertiary),
      ),
      // 图标相对**两行文字**居中，与账号管理那块一样；默认的 `threeLine`
      // 会把图标按标题行顶高。
      titleAlignment: ListTileTitleAlignment.center,
      onTap: actionable ? () => _requestPermission(permission) : null,
    );
  }

  /// 清单下面那行小字 —— 授权随时可以收回。
  Widget _revokeHint(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      '可以随时撤销已授予权限',
      style: ShuYoTextStyles.meta(color: context.shuyoColors.textMuted),
    ),
  );

  Widget _feature(IconData icon, String title, String description) {
    return Padding(
      padding: const EdgeInsets.only(left: 32, bottom: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 76),
        child: Row(
          children: [
            Icon(icon, size: 26),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: ShuYoTextStyles.title(
                      color: context.shuyoColors.textPrimary,
                      size: 17,
                      weight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    description,
                    style: ShuYoTextStyles.bodyCompact(
                      color: context.shuyoColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _paragraph(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: ShuYoTextStyles.bodyCompact(
        color: context.shuyoColors.textSecondary,
      ).copyWith(height: 1.5),
    ),
  );

  /// 授权被拒时页内留下的那一行。用警示色、**不用 SnackBar**：
  /// 提示条几秒后就没了，而用户此刻正卡在这一页上，理由必须一直在。
  Widget _notice(BuildContext context, String text) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: colors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: ShuYoTextStyles.meta(color: colors.warning)
                  .copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _disclaimer(BuildContext context) => Center(
    child: Text(
      '${ShuAppInfo.disclaimer}账号与密码只发往学校认证服务器。',
      textAlign: TextAlign.center,
      style: ShuYoTextStyles.meta(color: context.shuyoColors.textMuted),
    ),
  );

  /// 第 2 页页脚那行 —— 它固定停在底部按钮**上方**的那一格，与 `_layout` 的
  /// `pageFooter` 语义一致（第 0 页用的是免责声明）。
  ///
  /// 它说的是**结果**（这些信息最后怎么样了），而正文说的是**过程**（这次登录
  /// 会发生什么）。两件事分开读更清楚：过程要读懂，结果看一眼就够。
  Widget _privacyNote(BuildContext context) => Center(
    child: Text(
      'ShuVPN 不保存您的校园账户信息，也不会向任何第三方发送。',
      textAlign: TextAlign.center,
      style: ShuYoTextStyles.meta(color: context.shuyoColors.textMuted),
    ),
  );

  Widget _footer(BuildContext context, ConnectionController connection) {
    // 第 1 页要等清单全绿才解禁：授权是这一页存在的理由，允许「跳过」等于
    // 把第 2 页之后的一切建在沙子上。没解禁时 `onPressed` 为 null ——
    // `FilledButton` 自己就会画成灰的。
    final blocked = _busy || (_page == 1 && !_allGranted(connection));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: FilledButton(
        onPressed: blocked ? null : _advance,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(switch (_page) {
          0 || 1 => '继续',
          _ => '去登录',
        }),
      ),
    );
  }
}
