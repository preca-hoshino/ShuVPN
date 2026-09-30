import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/page_transitions.dart';
import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/account/account_center.dart';
import '../../core/auth/auth_constants.dart';
import '../../core/auth/credential_service.dart';
import '../../core/auth/jwxt_profile_service.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_surfaces.dart';
import 'login_form.dart';

/// 「账号管理」—— 设置页的二级页面。
///
/// 之前是浮动弹窗，但那不适合这个应用：
///   1. 要放一个完整的两步登录表单，弹窗里放不下；
///   2. 86% 高度的弹窗在小屏 + 键盘弹出后会挤成一团；
///   3. 二级页天生有返回栈，不必手绘拖拽条和返回键。
///
/// 页面有两个状态，而不是两页：
///   `_signingIn == false` → 概览（账户 + 各个 OAuth 系统的凭据状态）
///   `_signingIn == true`  → 登录表单
///
/// 两个状态之间的切换走 [ShuSharedAxisXSwitcher]：登录表单从右侧滑进来、概览
/// 往左让出四分之一屏，与「设置 → 账户管理」那一步同一套动作。
///
/// ⚠️ 两块内容**一直**在树上，所以在概览里也能读到 `_loginFormKey.currentState`
/// —— 这既是上面那些 `?.` 还留着的理由，也是为什么离开登录时要自己收键盘
/// （以前是整棵子树被卸载，焦点跟着一起没了）。
///
/// 概览分成**两块**，每块由一行小字标题带出：
///
/// 1. 「上大校园账户」—— 账户本身。已登录时显示姓名与年级 / 学院 / 专业
///    （从教务系统的个人信息片段读来），点它走退出确认；未登录时显示
///    「未登录」，点它进登录表单。
/// 2. 「OAuth 系统」—— 各个系统换到的凭据状态，颜色走 ShuYo 的语义 token
///    （可用是 `accent` 蓝，失败是 `danger` 红）。
///
/// 退出**不再单独占一行**：它和账户是同一件事的两种走向，分成两行反而要
/// 用户先分辨「我要点哪一行」。
///
/// 页面上**不列端点**。曾经有一块写满 `host/path` 的清单，但它是排障信息、
/// 不是账户信息 —— 它把「我是谁」和「我在跟谁说话」混在了同一屏。
///
/// [ShuOAuthTargets.visible] 决定凭据行里列哪几个系统：
/// 教务系统与会话照常交换，但不在这里单独露脸（它的信息体现在账户块里）。
class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  /// 登录表单的句柄：返回键与底部按钮都要驱动它。
  final _loginFormKey = GlobalKey<ShuLoginFormState>();

  /// 是否正在登录。为 true 时整页换成表单。
  bool _signingIn = false;

  bool get _busy => _loginFormKey.currentState?.busy ?? false;

  bool get _atVerificationStep => _loginFormKey.currentState?.step == 1;

  @override
  void initState() {
    super.initState();
    // 核对放在**这一页被打开时**，而不是应用启动时。
    //
    // 核对不是没有代价的：它要向三个系统各跑一轮交换，其中 aTrust 那一项
    // 真的会建一次隧道再断开。而绝大多数启动只是为了连隧道，用户根本没看过
    // 这一页 —— 那笔钱不该让所有人付。
    //
    // 结论也新鲜时（五分钟内核对过）什么都不做，快照直接顶上。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<AccountCenter>().verifyIfStale());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 核对发现会话真的失效了才提示；网络抖动、教务改版这些失败都不算 ——
    // 那些只会让某一行显示「未连接」，会话本身还好好的。
    if (!context.read<AccountCenter>().sessionExpired) return;
    // 只对「用户正看着这一页」的情况弹，否则会在别的页面上凭空冒出来。
    if (ModalRoute.of(context)?.isCurrent != true) return;
    // 标记在这里、**同步**地清掉。
    //
    // 这个标记描述的是「刚刚发生了一次失效」，不是「当前处于失效状态」。
    // 而 `didChangeDependencies` 每收到一次通知都会跑一遍（`build` 里
    // `watch` 了账户中心，所以 `busy` 一变就会重跑），要是等弹窗里再清，
    // 中间那几轮会各排一个弹窗，用户一次性看到好几个。
    context.read<AccountCenter>().clearSessionExpired();
    WidgetsBinding.instance.addPostFrameCallback((_) => _warnSessionExpired());
  }

  /// 会话失效提示。是否要弹已经在 [didChangeDependencies] 里判断过了。
  Future<void> _warnSessionExpired() async {
    if (!mounted) return;
    final again = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('校园账户登录已失效'),
        content: const Text('统一认证会话已经过期或被踢下线，需要重新登录才能继续使用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重新登录'),
          ),
        ],
      ),
    );
    if (again == true && mounted) _openLogin();
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCenter>();
    return PopScope(
      // 登录请求进行中时不许退出，否则回来会看见一个半死会话。
      canPop: !_busy,
      child: Scaffold(
        appBar: ShuAppBar(
          // 标题随登录步骤走，与 ShuYo 的 `NativeLoginPage` 一致：
          // 概览与账密页是「账户管理」，验证码页是「验证身份」。
          title: _atVerificationStep ? '验证身份' : '账户管理',
          // 这一页是**被推上来的**，所以返回键永远要有。
          //
          // ⚠️ 以前这里写的是 `_signingIn ? ... : null`，也就是「概览状态不画
          // 返回键」—— 那是错的。概览才是这一页的主状态，用户从设置点进来看到
          // 的正是它，结果没有返回键、只能靠系统手势退。
          //
          // 现在两种情况都画，只是**回调不同**：登录中先退回表单第一步
          // （`_back`），概览里直接弹栈。
          onBack: _signingIn ? _back : () => Navigator.of(context).pop(),
          // 登录请求进行中时把箭头变灰留在原地，而不是让它消失。
          backEnabled: !_busy,
        ),
        body: SafeArea(
          // 两块都在树上，`showFront` 只报「哪一块在前面」；位置由换页器算。
          //
          // 为什么不做成 `_signingIn ? 表单 : 概览`：那样中间什么都没有，切换是
          // 一帧之内对调的 —— 这正是以前「进入登录状态没有动画」的原因。
          child: ShuSharedAxisXSwitcher(
            showFront: _signingIn,
            // 两块都按 `ShuLoginForm` / `_overview` 的常态造一次，之后每帧只
            // 挪位置：它们是同一个 widget 实例，不会跟着动画反复重建。
            front: ShuLoginForm(
              key: _loginFormKey,
              onChanged: () => setState(() {}),
              onCompleted: _finishLogin,
            ),
            back: _overview(context, account),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 概览

  Widget _overview(BuildContext context, AccountCenter account) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        ShuSpacing.page,
        0,
        ShuSpacing.page,
        ShuSpacing.page * 2,
      ),
      children: [
        // ① 账户本身。小字标题把这一块和下面那块分开。
        //
        //    点击的含义只由 `signedIn` 决定，**不能**用「有没有读到档案」
        //    当判据 —— 档案读失败时人是登录着的，那时弹登录表单就错了。
        const SectionHeader(title: '上海大学校园账户'),
        _AccountTile(
          account: account,
          profile: account.profile,
          onTap: account.busy
              ? null
              : (account.signedIn
                    ? () => _logout(context, account)
                    : _openLogin),
        ),

        // ② 各个 OAuth 系统的凭据状态。教务系统也在这里 —— 它的数据
        //    已经在上面那块显示了，但「这个系统连上没有」是独立的一条信息：
        //    登录过但教务系统交换失败时，上面那块会缺字段，只有这里说得清
        //    是哪个系统出的问题。
        const SectionHeader(title: '上海大学 OAuth 系统'),
        for (final credential in account.credentials)
          _CredentialRow(credential: credential),
      ],
    );
  }

  // ------------------------------------------------------------------ 登录

  /// 概览 ⇄ 登录表单。
  ///
  /// 这里只切**逻辑**状态，视觉上的换页由 [ShuSharedAxisXSwitcher] 自己演。
  /// 两者分开是必要的：标题栏、返回键、`PopScope` 都要在按下的那一刻就切过去，
  /// 不能等动画 —— 否则「验证身份」这几个字会慢半拍才出现。
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

  void _openLogin() => _setSigningIn(true);

  void _back() {
    final form = _loginFormKey.currentState;
    // 先退回表单的第一步；已经在第一步时才离开登录。
    if (form != null && form.back()) return;
    _leaveLogin();
  }

  void _leaveLogin() => _setSigningIn(false);

  /// 登录成功后回概览，而不是退出页面 —— 用户还要看凭据换到了没有。
  void _finishLogin() {
    if (!mounted) return;
    _setSigningIn(false);
  }

  Future<void> _logout(BuildContext context, AccountCenter account) async {
    final confirmed = await _confirm(
      context,
      title: '退出上海大学校园账户？',
      message: '退出后需要重新登录才能建立隧道。',
    );
    if (!confirmed) return;
    await account.signOut();
  }

  /// 退出确认框。登录态下点账户行就会走到这里。
  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('退出'),
            ),
          ],
        ),
      ) ??
      false;
}

/// 账户块。
///
/// 它是这一页唯一「可点」的地方，而点击的含义随状态变：
///
/// | 状态 | 第一行 | 第二行 | 第三行 | 点击 |
/// | :--- | :--- | :--- | :--- | :--- |
/// | 未登录 | `未登录` | — | — | 进登录表单 |
/// | 已登录 + 读到档案 | **姓名**（大字） | 学号 | 专业 · 学院 | 退出确认 |
/// | 已登录 + 无档案 | 学号或 `已登录` | — | — | 退出确认 |
/// | 进行中 | 同上 | 同上 | 同上 | 不响应，右侧转圈 |
///
/// 三行的层级刻意分开：姓名是身份，字号最大；学号是编号，小一号；
/// 专业与学院是属性，**并排**放在第三行 —— 它们回答的是同一类问题
/// （「学什么的」），拆成两行反而是把一件事当两件事写。
///
/// 右侧**不再写「已登录」**。曾经这里有一个绿色的状态词，和下面那些凭据行
/// 对齐成一条竖线；但那两件事其实不同：下面回答的是「这个系统连上没有」，
/// 而这一块的三行文字本身已经把「登的是谁」说得清清楚楚 —— 再补一个
/// 「已登录」是同一句话说两遍，还额外借走了界面里唯一表示「成功」的颜色。
/// 核对进行中时右侧只留一个转圈。
///
/// 右侧的箭头是这个页面上**唯一**的「这里可以点」的提示，与 ShuYo 的
/// `_accountTile` 一致；下面的凭据行都是只读的，所以它们没有箭头。
class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.profile,
    required this.onTap,
  });

  final AccountCenter account;
  final ShuJwxtProfile? profile;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final signedIn = account.signedIn;
    final title = !signedIn
        ? '未登录'
        : (profile?.name ?? account.accountId ?? '已登录');
    final details = _details(colors);
    return ListTile(
      leading: const Icon(Icons.school_outlined),
      title: Text(
        title,
        style: signedIn
            // 姓名是这一页最大的字：它首先回答「我是谁」。
            ? ShuYoTextStyles.title(
                color: colors.textPrimary,
                size: 18,
                weight: FontWeight.w600,
              )
            : ShuYoTextStyles.bodyCompact(color: colors.textMuted),
      ),
      // 副标题自带两行（学号、专业 · 学院），所以不再给 ListTile 的
      // 默认间距留空 —— 那会把三行撑得过散。
      //
      // `isThreeLine` 必须跟着副标题一起出现：`ListTile` 断言
      // 「三行就必须有副标题」，未登录时这里正是没有副标题的情况。
      subtitle: details,
      isThreeLine: details != null,
      // 图标与箭头**相对整块文字垂直居中**。
      //
      // 默认值是 `threeLine`：只要 `isThreeLine` 为真，它就把图标按
      // `minVerticalPadding` 顶到与**标题行**对齐（源码 `list_tile.dart`
      // 的 `ListTileTitleAlignment._yOffsetFor`）—— 于是三行文字 + 大字的
      // 账户块里，学士帽明显偏高，箭头也一样偏。改成 `center` 后两者都按
      // 整块（标题 + 副标题）的高度居中，视觉上才稳。
      titleAlignment: ListTileTitleAlignment.center,
      // 转圈与箭头互斥：对齐 ShuYo —— 忙的时候没有可点的东西，
      // 这时候还摆着箭头会让人以为能点。
      trailing: account.busy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            )
          : (onTap == null ? null : const Icon(Icons.chevron_right)),
      onTap: onTap,
    );
  }

  /// 学号与「专业 · 学院」。都缺席时返回 `null`（未登录就是这种情况）。
  ///
  /// 学号的优先级：档案里的 `studentId` → 账户中心的 `accountId`。
  /// 两者其实是同一个值（都来自课表接口的 `XH`），但从**两个不同的地方**
  /// 进来：档案是上一轮核对的结果，`accountId` 是交换时当场留下的。
  /// 只看前者的话，只要档案那个片段翻车（它就是临时拼的），学号就不见了。
  Widget? _details(ShuYoColors colors) {
    final studentId = profile?.studentId ?? account.accountId;
    final traits = [
      if (profile?.major != null) profile!.major!,
      if (profile?.college != null) profile!.college!,
    ];
    if (studentId == null && traits.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (studentId != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              studentId,
              style: ShuYoTextStyles.meta(color: colors.textTertiary),
            ),
          ),
        if (traits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              traits.join(' · '),
              style: ShuYoTextStyles.meta(color: colors.textTertiary),
            ),
          ),
      ],
    );
  }
}

/// 一条**只读**的系统凭据。
///
/// 行本身交给 [ShuSystemTile]（图标 + 系统名 + 域名）—— 引导页第 3 页那张
/// 清单用的是同一个组件，所以两处的名字与域名逐字一致。这里只补上一件
/// 那一页没有的事：**状态**。
///
/// 状态写在**右侧**的行内小字上，参照 ShuYo 的 `_accountTile` —— 那边也是
/// 「图标保持默认色，状态是文字」。我们只改一处：ShuYo 把状态紧贴在名称后面
/// （`名称 已登录`），这里改成**右对齐**（[ShuStatusSlot]），让同组几行的状态
/// 落在同一条竖线上，扫一眼就能比出哪个没连上。
///
/// 图标**不染色**。之前用颜色表示状态，结果是「蓝盾牌」既是「可用」又占走了
/// 图标本身的语义；而且色盲用户读不出区别。颜色留给状态文字。
class _CredentialRow extends StatelessWidget {
  const _CredentialRow({required this.credential});

  final ShuSystemCredential credential;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final target = ShuOAuthTargets.byId(credential.systemId);
    // 凭据只可能来自注册表里那三个系统（`ShuOAuthTargets.all`），查不到
    // 说明数据坏了 —— 不画一行什么都没有的空壳，也不崩。
    if (target == null) return const SizedBox.shrink();
    final status = _status(colors);
    return ShuSystemTile(
      kind: target.kind,
      trailing: ShuStatusSlot(text: status.text, color: status.color),
    );
  }

  /// 这一行现在是什么状态，以及对应的 ShuYo 语义色。
  ///
  /// | 状态 | 文字 | 颜色 |
  /// | :--- | :--- | :--- |
  /// | 可用 | `已连接` | `accent` 蓝 |
  /// | 正在处理 | `正在获取…` | `textMuted` |
  /// | 已过期 | `已过期` | `warning` |
  /// | 交换失败 | `交换失败` | `danger` 红 |
  /// | 未登录 / 未知 | `未连接` | `textMuted` |
  ///
  /// 交换失败不再把服务端原话摆在行内 —— 那句话可能很长，会把这一行撑成
  /// 两行；它属于详情，不属于列表。这里只说「失败了」，颜色已经足够。
  ({String text, Color color}) _status(ShuYoColors colors) {
    switch (credential.state) {
      case ShuCredentialState.available:
        return (text: '已连接', color: colors.accent);
      case ShuCredentialState.refreshing:
        return (text: '正在获取…', color: colors.textMuted);
      case ShuCredentialState.expired:
        return (text: '已过期', color: colors.warning);
      case ShuCredentialState.failing:
        return (text: '交换失败', color: colors.danger);
      case ShuCredentialState.missing:
      case ShuCredentialState.unknown:
        return (text: '未连接', color: colors.textMuted);
    }
  }
}
