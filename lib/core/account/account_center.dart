import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_constants.dart';
import '../auth/auth_session.dart';
import '../auth/credential_service.dart';
import '../auth/jwxt_profile_service.dart';
import '../auth/native_auth_service.dart';
import '../logging/shu_log.dart';
import 'account_snapshot.dart';

/// 已经交换到凭据的系统集合。
///
/// 这是「账户」这一层对外暴露的全部内容：一个统一身份认证会话，加上它换来的
/// 三个系统凭据。UI 只依赖这个接口，所以换实现时不需要改任何 widget。
abstract class AccountCenter extends ChangeNotifier {
  /// 统一身份认证账号（学号），未登录时为 null。
  String? get accountId;

  /// 认证会话是否可用。
  bool get signedIn;

  /// 会话建立的时刻。
  DateTime? get signedInAt;

  /// 一轮授权 / 交换是否在进行中。
  bool get busy;

  /// 正在进行的操作说明，例如 `正在交换 OTP 令牌`。
  String? get progressLabel;

  /// 上一次失败的原因，展示给用户；成功时为 null。
  String? get errorMessage;

  /// 三个系统各自的凭据状态。
  List<ShuSystemCredential> get credentials;

  /// 可用的系统数 / 总数。
  CredentialSummary get summary;

  /// 上次核对到的教务系统档案（姓名 / 学号 / 年级 / 学院 / 专业）。
  ///
  /// 页面从**这里**取身份信息，而不是去 [credentials] 的载荷里现翻 ——
  /// 载荷是「这一轮交换换到了什么」，这里是「上次核对看到了什么」。
  /// 冷启动时前者是空的，后者有值（从磁盘快照读回），这正是账户页
  /// 不必一打开就联网的原因。
  ShuJwxtProfile? get profile;

  /// 会话是否已被服务端判定失效。
  ///
  /// 核对失败有很多种（网络抖动、教务系统改版），只有这一种意味着
  /// 「必须重新输密码」。UI 用它来决定弹不弹那个提示，不弹的方式是
  /// [clearSessionExpired]。
  bool get sessionExpired;

  /// 用户看过提示之后清掉标记，避免同一件事弹第二次。
  void clearSessionExpired();

  /// 是否需要在渲染账户页之前先核一遍。
  bool get needsReverification;

  /// 按需核对：磁盘上的结论还新鲜就什么都不做，否则跑一轮交换。
  ///
  /// 这是账户页在 `initState` 里调的那一个 —— **不在应用启动时调**。
  /// 理由见 [ShuAccountSnapshot]：核对里有一项真的要建一次 aTrust 隧道，
  /// 让每个没打开过账户页的启动都付这笔钱是浪费。
  Future<bool> verifyIfStale();

  /// 用统一身份认证凭据登录。
  ///
  /// 返回「成功 / 需要两步验证 / 失败」三态，把 challenge 交给 UI，
  /// 而不是把它藏在可变字段里 —— 登录事务是原子的，状态也应该一次交卷。
  ///
  /// 成功后**不在这里交换凭据**：交换要一个一个系统跑，慢且必须在界面上
  /// 有交待，所以拆成 [completeSignIn]，由过渡页盖着它跑。
  Future<ShuSignInOutcome> signIn({
    required String username,
    required String password,
  });

  /// 两步验证：发送验证码。
  Future<void> sendCode(ShuVerificationMethod method);

  /// 两步验证：提交验证码。成功只代表身份成立，凭据仍然要 [completeSignIn]。
  Future<bool> submitCode(ShuVerificationMethod method, String code);

  /// 企业微信扫码登录成功后接管会话（不交换凭据）。
  Future<bool> adoptWeComSession({
    required Iterable<({Cookie cookie, String domain, String path})> cookies,
    required String username,
  });

  /// 向全部系统换取凭据，完成一次登录。
  ///
  /// 这是整次登录里最慢的一段，调用方应当先把过程展示出来再调用它。
  Future<bool> completeSignIn();

  /// 退出登录并清空所有凭据。
  Future<void> signOut();

  /// 供 aTrust 隧道复用的原生认证会话。
  ///
  /// aTrust 的网关把统一身份认证当作 IdP，所以建立隧道时需要拿这里已经
  /// 登录好的会话去换授权码 —— 两边必须是同一个会话，否则用户得登两次。
  ShuAuthSession get authSession;
}

/// 登录结果。
@immutable
class ShuSignInOutcome {
  const ShuSignInOutcome._(this.status, this.challenge);

  /// 密码通过、会话已建立，三个系统凭据已交换完毕。
  static const success = ShuSignInOutcome._(ShuSignInStatus.success, null);

  /// 密码通过，但学校要求两步验证。
  factory ShuSignInOutcome.needsVerification(ShuLoginChallenge challenge) =>
      ShuSignInOutcome._(ShuSignInStatus.needsVerification, challenge);

  /// 登录失败，原因在 [AccountCenter.errorMessage]。
  static const failed = ShuSignInOutcome._(ShuSignInStatus.failed, null);

  final ShuSignInStatus status;

  /// 仅当 [status] 为 `needsVerification` 时非空。
  final ShuLoginChallenge? challenge;

  bool get isSuccess => status == ShuSignInStatus.success;

  bool get needsVerification => status == ShuSignInStatus.needsVerification;
}

enum ShuSignInStatus { success, needsVerification, failed }

/// 汇总数字。
@immutable
class CredentialSummary {
  const CredentialSummary({required this.available, required this.total});

  factory CredentialSummary.of(Iterable<ShuSystemCredential> credentials) {
    var available = 0;
    var total = 0;
    for (final credential in credentials) {
      total++;
      if (credential.isUsable) available++;
    }
    return CredentialSummary(available: available, total: total);
  }

  final int available;
  final int total;

  bool get allAvailable => total > 0 && available == total;

  String get label => total == 0 ? '未接入系统' : '$available/$total 系统凭据可用';
}

/// 真实的统一身份认证账户中心。
///
/// 三次握手：`login` →（可选 `sendCode` / `verifyCode`）→ 向三个系统分别
/// `authorize` + `redeem`。全程共享一个 [ShuAuthSession]，因此 `SHU_OAUTH2`
/// 会话只建立一次。
class ShuAccountCenter extends AccountCenter {
  ShuAccountCenter({ShuAuthSession? session, SharedPreferences? preferences})
    : _session = session ?? ShuAuthSession(preferences: preferences),
      _snapshots = preferences == null
          ? null
          : ShuAccountSnapshotStore(preferences),
      _credentials = <ShuSystemCredential>[
        for (final target in ShuOAuthTargets.all)
          ShuSystemCredential.missing(target.kind.id),
      ] {
    _loadSnapshot();
  }

  /// 核对结论的缓存时长。
  ///
  /// 在这之内再次打开账户页不重复核对 —— 用户上下翻两下不该打出两轮请求。
  /// 超过它，说明结论可能已经过时（会话有效期、网关心跳都是分钟级），
  /// 那就再核一次。
  static const _staleAfter = Duration(minutes: 5);

  final ShuAuthSession _session;

  /// 账户页的展示用快照；单测里不注入 `preferences` 时为 null。
  final ShuAccountSnapshotStore? _snapshots;

  final List<ShuSystemCredential> _credentials;

  String? _accountId;
  ShuJwxtProfile? _profile;
  DateTime? _signedInAt;
  bool _busy = false;
  String? _progressLabel;
  String? _errorMessage;

  /// 上次核对成功的时刻。`null` 表示本次启动还没核对过。
  DateTime? _verifiedAt;

  /// 这一轮核心里有没有系统报告「统一认证会话没被复用」。
  bool _sessionLost = false;

  /// 会话被服务端判定失效 —— 见 [sessionExpired]。
  bool _sessionExpired = false;

  @override
  String? get accountId => _accountId;

  /// 只要持有统一身份认证会话就算已登录。
  ///
  /// 学号是展示用的补充信息（企微扫码路径拿不到它），不能拿它当登录条件 ——
  /// 否则扫码登录成功之后，页面会显示成未登录。
  @override
  bool get signedIn => _session.hasSession;

  @override
  DateTime? get signedInAt => _signedInAt;

  @override
  bool get busy => _busy;

  @override
  String? get progressLabel => _progressLabel;

  @override
  String? get errorMessage => _errorMessage;

  @override
  List<ShuSystemCredential> get credentials =>
      List<ShuSystemCredential>.unmodifiable(_credentials);

  @override
  ShuJwxtProfile? get profile => _profile;

  @override
  bool get sessionExpired => _sessionExpired;

  @override
  void clearSessionExpired() {
    if (!_sessionExpired) return;
    _sessionExpired = false;
    notifyListeners();
  }

  @override
  bool get needsReverification {
    if (!signedIn) return false;
    final at = _verifiedAt;
    return at == null || DateTime.now().difference(at) >= _staleAfter;
  }

  @override
  ShuAuthSession get authSession => _session;

  @override
  CredentialSummary get summary => CredentialSummary.of(_credentials);

  /// 该系统的静态信息（显示名、说明）。
  ShuOAuthTarget? targetFor(String id) => ShuOAuthTargets.byId(id);

  // ------------------------------------------------------------------ OTP

  // 口令**不做实时轮换**。
  //
  // 试图跟着 30 秒轮换去自动重取，结果是一句话都说不清的失败：轮换的定时器与
  // 用户在页面上的各种操作抢会话，抢输的那一轮就把凭据行打成「交换失败」。
  // 取一次、把「剩余 N 秒」摆出来，过期与否交给用户看数字判断。

  /// 一轮凭据交换是否正在进行。
  bool _exchanging = false;

  /// 上一轮交换的结果，供重入时直接返回。
  bool _lastExchangeOk = false;

  // ------------------------------------------------------------------ 登录

  @override
  Future<ShuSignInOutcome> signIn({
    required String username,
    required String password,
  }) async {
    if (_busy) return ShuSignInOutcome.failed;
    _setBusy(true, '正在登录统一身份认证');
    _errorMessage = null;
    // **不记用户名本身**：它是学号或手机号，日志是要被复制粘贴出去的。
    // 长度足够区分「输错了」与「没输」。
    ShuLog.i(ShuLogTag.account, '开始登录统一身份认证 · 用户名 ${username.length} 字符');
    try {
      // `params` 由服务自己从真实登录页 URL 里截取 —— 不在这里拼。
      final result = await _session.native.login(
        username: username,
        password: password,
      );
      // 表单里输的东西**不作数**：用户可能输手机号或别名，而学号的权威
      // 来源是教务系统的 `XH`。这里只清掉上一次登录留下的值。
      _accountId = null;
      final challenge = result.challenge;
      if (challenge != null) {
        // 需要两步验证：会话还没建立，交回 UI 继续。
        ShuLog.i(
          ShuLogTag.account,
          '口令通过 · 需要两步验证 · 可选方式 '
          '${challenge.methods.keys.map((m) => m.label).join("、")}',
        );
        return ShuSignInOutcome.needsVerification(challenge);
      }
      _signedInAt = DateTime.now();
      // 会话建立成功，马上落盘 —— 这一步之后就算应用被杀，
      // 下次启动也不用再要一次密码。
      await _session.persistSession();
      ShuLog.i(ShuLogTag.account, '统一身份认证会话已建立');
      return ShuSignInOutcome.success;
    } on ShuAuthException catch (error) {
      _fail(error);
      return ShuSignInOutcome.failed;
    } on Object catch (error) {
      _fail(ShuAuthException('unknown', '登录失败：$error'));
      return ShuSignInOutcome.failed;
    } finally {
      _setBusy(false, null);
    }
  }

  @override
  Future<void> sendCode(ShuVerificationMethod method) async {
    _errorMessage = null;
    notifyListeners();
    ShuLog.i(ShuLogTag.account, '发送验证码 · ${method.label}');
    await _session.native.sendCode(method);
  }

  @override
  Future<bool> submitCode(ShuVerificationMethod method, String code) async {
    if (_busy) return false;
    _setBusy(true, '正在校验验证码');
    _errorMessage = null;
    ShuLog.i(
      ShuLogTag.account,
      '提交验证码 · ${method.label} · ${code.trim().length} 位',
    );
    try {
      await _session.native.verifyCode(method: method, code: code);
      _signedInAt = DateTime.now();
      await _session.persistSession();
      ShuLog.i(ShuLogTag.account, '两步验证通过，会话已建立');
      return true;
    } on ShuAuthException catch (error) {
      _fail(error);
      return false;
    } on Object catch (error) {
      _fail(ShuAuthException('unknown', '验证失败：$error'));
      return false;
    } finally {
      _setBusy(false, null);
    }
  }

  @override
  Future<bool> adoptWeComSession({
    required Iterable<({Cookie cookie, String domain, String path})> cookies,
    required String username,
  }) async {
    if (_busy) return false;
    _setBusy(true, '正在接管企业微信会话');
    _errorMessage = null;
    ShuLog.i(ShuLogTag.account, '接管企业微信扫码会话');
    try {
      _session.adoptCookies(cookies);
      // 扫码路径拿不到学号，交给凭据交换从教务系统的 `XH` 里取。
      _accountId = null;
      _signedInAt = DateTime.now();
      await _session.persistSession();
      ShuLog.i(ShuLogTag.account, '企业微信会话已接管');
      return true;
    } on ShuAuthException catch (error) {
      _fail(error);
      return false;
    } on Object catch (error) {
      _fail(ShuAuthException('unknown', '企业微信登录失败：$error'));
      return false;
    } finally {
      _setBusy(false, null);
    }
  }

  @override
  Future<bool> completeSignIn() async {
    if (!_session.hasSession) return false;
    // 同一时刻只能有一次凭据交换，否则会变成两遍完整的交换 ——
    // 看起来就是「突然重新来第二次」。
    if (_exchanging) return _lastExchangeOk;
    _exchanging = true;
    _lastExchangeOk = false;
    _setBusy(true, '正在获取凭据');
    _errorMessage = null;
    try {
      await _exchangeAll();
      // 单个系统失败不算整次登录失败 —— 凭据矩阵本来就是这么设计的。
      _lastExchangeOk = summary.available > 0;
      // 登录流程刚跑过一轮核对，结论是新鲜的：落盘，账户页以后先用它，
      // 不必为了这几行字再联一次网。
      _verifiedAt = DateTime.now();
      await _persistSnapshot();
      // 交换过一轮之后 `SHU_OAUTH2` 的 Cookie 可能被刷新过，重存一次。
      await _session.persistSession();
      ShuLog.i(
        ShuLogTag.account,
        '登录流程结束 · ${summary.label} · 交换成功 $_lastExchangeOk',
      );
      return _lastExchangeOk;
    } finally {
      _exchanging = false;
      _setBusy(false, null);
    }
  }

  @override
  Future<bool> verifyIfStale() async {
    if (!signedIn) return false;
    if (!needsReverification) return true;
    if (_exchanging || _busy) return _lastExchangeOk;
    _exchanging = true;
    _lastExchangeOk = false;
    _setBusy(true, '正在核对校园账户');
    ShuLog.i(ShuLogTag.account, '开始核对校园账户（上一轮结论已过期）');
    try {
      await _exchangeAll();
      // 单个系统失败不算整次核对失败 —— 凭据矩阵本来就是这么设计的。
      _lastExchangeOk = summary.available > 0;
      // 真的「对话过」才算核过：连会话都没有时跑完一圈是空跑，
      // 记下来会让页面以后都不再重试。
      if (!_sessionLost) {
        _verifiedAt = DateTime.now();
        await _persistSnapshot();
      }
      // 交换过一轮之后 `SHU_OAUTH2` 的 Cookie 可能被刷新过，重存一次。
      await _session.persistSession();
      return _lastExchangeOk;
    } on Object catch (error) {
      // 核对失败就把用户吓一跳是不对的：他只是打开了账户页。
      // 快照还在，页面照常显示上次的结论；下次进来再试。
      ShuLog.w(ShuLogTag.account, '核对校园账户失败 · $error · 沿用上次的结论');
      return false;
    } finally {
      _exchanging = false;
      _setBusy(false, null);
    }
  }

  @override
  Future<void> signOut() async {
    _setBusy(true, '正在退出登录');
    ShuLog.i(ShuLogTag.account, '退出登录，清空会话与快照');
    _session.clear();
    _accountId = null;
    _profile = null;
    _signedInAt = null;
    _errorMessage = null;
    _verifiedAt = null;
    _sessionLost = false;
    _sessionExpired = false;
    for (var index = 0; index < _credentials.length; index++) {
      _credentials[index] = ShuSystemCredential.missing(
        _credentials[index].systemId,
      );
    }
    // 快照跟着会话一起走：留着它只会让退出后的页面显示上一个用户的名字。
    await _snapshots?.clear();
    _setBusy(false, null);
  }

  // ---------------------------------------------------------------- 快照

  /// 把磁盘上上次核对的结果读回来。
  ///
  /// 只在构造函数里调一次。开头的 `!_session.hasSession` 很关键：会话已经
  /// 不在了（用户删过数据、Cookie 过期清掉了）而快照还在时，直接采信快照
  /// 会让页面显示一个「已登录的上一任用户」。
  void _loadSnapshot() {
    final snapshots = _snapshots;
    if (snapshots == null) return;
    final snapshot = snapshots.load();
    if (snapshot.isEmpty) return;
    if (!_session.hasSession) return;
    _accountId = snapshot.accountId;
    _profile = snapshot.profile;
    _verifiedAt = snapshot.verifiedAt;
    for (var index = 0; index < _credentials.length; index++) {
      final state = snapshot.credentials[_credentials[index].systemId];
      if (state == null) continue;
      _credentials[index] = _credentials[index].copyWith(state: state);
    }
    ShuLog.d(
      ShuLogTag.account,
      '从磁盘快照恢复账户状态 · ${summary.label} · '
      '核对于 ${snapshot.verifiedAt}',
    );
  }

  /// 把这次核对的结论落盘，并顺手记下会话是否已经失效。
  Future<void> _persistSnapshot() async {
    _sessionExpired = _sessionLost;
    _sessionLost = false;
    // 快照里只有「上次看到的身份」，**没有凭据本体** —— 落盘时不必再脱敏。
    ShuLog.d(
      ShuLogTag.account,
      '写入账户快照 · ${summary.label} · '
      '档案${_profile == null ? "无" : "有"} · '
      '会话失效=$_sessionExpired',
    );
    await _snapshots?.save(
      ShuAccountSnapshot(
        accountId: _accountId,
        profile: _profile,
        credentials: <String, ShuCredentialState>{
          for (final credential in _credentials)
            credential.systemId: credential.state,
        },
        verifiedAt: _verifiedAt,
      ),
    );
  }

  // -------------------------------------------------------------- 凭据交换

  /// 向三个系统**并发**换取凭据。
  ///
  /// 单个系统失败不影响其它系统 —— 凭据矩阵本来就要能表达「有的成功有的失败」。
  ///
  /// ## 为什么是并发而不是挨个来
  ///
  /// 三个系统之间**没有任何依赖**：都只是「拿同一个 `SHU_OAUTH2` 会话去换一次
  /// 授权码」，各自的 Cookie 落在各自的域上。串行跑的唯一后果是总时长等于
  /// 三段之和 —— 而这三段里有两段纯粹在等网络。并发之后是三者里最慢的那一个，
  /// 过渡页停留的时间大约少一半。
  ///
  /// 并发是安全的，因为每一路只碰自己那一格：
  ///
  /// * 写回用 `indexWhere` 定位，三个下标互不重叠；
  /// * `_profile` / `_accountId` 只有教务系统那一路会写；
  /// * `_sessionLost` 是「这一轮里有没有人报告会话没了」的累积标记，
  ///   `true` 一旦写上就不会被覆盖，先到后到没有区别。
  ///
  /// ⚠️ 进度文案跟着改了：并发之下「正在做第几个」没有意义（三个都在做），
  /// 所以报的是**完成了几个**。
  Future<void> _exchangeAll() async {
    final targets = ShuOAuthTargets.all;
    // 逐系统累积的结果只属于**这一轮**，上一轮的残值不能带进来。
    _sessionLost = false;
    _exchanged = 0;
    _progressLabel = '正在获取凭据（0/${targets.length}）';
    ShuLog.i(
      ShuLogTag.account,
      '开始并发交换 ${targets.length} 个系统的凭据 · '
      '${targets.map((t) => t.kind.id).join("、")}',
    );
    notifyListeners();
    await Future.wait([
      for (final target in targets) _exchange(target.kind.id),
    ]);
  }

  /// 本轮已经跑完的系统数（无论成败）。
  ///
  /// 并发下只能报这个数，报「正在做第几个」是假话。
  int _exchanged = 0;

  Future<void> _exchange(String systemId) async {
    final index = _credentials.indexWhere((c) => c.systemId == systemId);
    if (index < 0) return;
    _credentials[index] = _credentials[index].copyWith(
      state: ShuCredentialState.refreshing,
      clearError: true,
    );
    ShuLog.d(ShuLogTag.account, '交换 $systemId 的凭据');
    notifyListeners();

    try {
      _credentials[index] = await _session.credentials.exchange(systemId);
      // 教务系统是唯一会告诉我们「你是谁」的系统，顺手把档案与学号留下来。
      if (systemId == ShuOAuthTargets.jwxt.kind.id) {
        _profile = ShuJwxtProfile.fromPayload(_credentials[index].payload);
        _accountId = _studentIdOf(_credentials[index]) ?? _accountId;
      }
      ShuLog.i(
        ShuLogTag.account,
        '$systemId 换到凭据 · ${_credentials[index].state.label}',
      );
    } on ShuAuthException catch (error) {
      // 「统一认证会话未能复用」不是这个系统的毛病，是整个会话没了 ——
      // 那是另一回事，得让用户重新登一次，而不是把这一行标成红色的
      // 「交换失败」以后就没事了。
      if (error.code == 'sessionNotReused') _sessionLost = true;
      ShuLog.w(
        ShuLogTag.account,
        '$systemId 交换失败 [${error.code}] ${error.message}',
      );
      _credentials[index] = ShuSystemCredential.failed(
        systemId,
        code: error.code,
        message: error.message,
      );
    } on Object catch (error) {
      ShuLog.e(ShuLogTag.account, '$systemId 交换抛出未预期的异常 · $error');
      _credentials[index] = ShuSystemCredential.failed(
        systemId,
        code: 'unknown',
        message: '$error',
      );
    } finally {
      // 计数在 `finally` 里推进：**失败的那一路也要算「跑完了」**，
      // 否则进度会在 n-1 那个数上永远停住。
      _exchanged++;
      _progressLabel = '正在获取凭据（$_exchanged/${ShuOAuthTargets.all.length}）';
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ 内部

  /// 从教务系统的凭据里取出学号（`XH`）。
  String? _studentIdOf(ShuSystemCredential credential) {
    final value = credential.payload['studentId'];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _setBusy(bool value, String? label) {
    _busy = value;
    _progressLabel = label;
    notifyListeners();
  }

  void _fail(ShuAuthException error) {
    ShuLog.e(ShuLogTag.account, '账户操作失败 [${error.code}] ${error.message}');
    _errorMessage = error.message;
    notifyListeners();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }
}
