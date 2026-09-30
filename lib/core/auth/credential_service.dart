import 'dart:io';

import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';

import '../logging/shu_log.dart';
import 'atrust_auth_chain.dart';
import 'atrust_sso_login.dart';
import 'authorize_service.dart';
import 'auth_constants.dart';
import 'auth_cookie_store.dart';
import 'jwxt_profile_service.dart';
import 'native_auth_service.dart';
import 'otp_service.dart';

/// 某个系统交换到的凭据。
///
/// 只保留「拿来能用」和「拿来展示」两件事，绝不保存密码。
class ShuSystemCredential {
  const ShuSystemCredential({
    required this.systemId,
    required this.state,
    this.errorCode,
    this.errorMessage,
    this.expiresAt,
    this.maskedSecret,
    this.payload = const <String, Object?>{},
  });

  factory ShuSystemCredential.missing(String systemId) => ShuSystemCredential(
    systemId: systemId,
    state: ShuCredentialState.missing,
  );

  factory ShuSystemCredential.failed(
    String systemId, {
    required String code,
    required String message,
  }) => ShuSystemCredential(
    systemId: systemId,
    state: ShuCredentialState.failing,
    errorCode: code,
    errorMessage: message,
  );

  final String systemId;
  final ShuCredentialState state;

  final String? errorCode;
  final String? errorMessage;
  final DateTime? expiresAt;

  /// 脱敏后的凭据本体，用于详情面板。
  final String? maskedSecret;

  /// 系统专有数据（例如 OTP 的账户名与口令、aTrust 的 sid）。
  ///
  /// 界面上不再直接展示这些内容，但交换结果仍然完整地留在这里：
  /// 将来要做凭据详情面板或健康检查时，不必再回去重跑一遍交换。
  final Map<String, Object?> payload;

  bool get isUsable => state == ShuCredentialState.available;

  Duration? get remaining => expiresAt?.difference(DateTime.now());

  ShuSystemCredential copyWith({
    ShuCredentialState? state,
    String? errorCode,
    String? errorMessage,
    DateTime? expiresAt,
    String? maskedSecret,
    Map<String, Object?>? payload,
    bool clearError = false,
    bool clearExpiry = false,
  }) => ShuSystemCredential(
    systemId: systemId,
    state: state ?? this.state,
    errorCode: clearError ? null : (errorCode ?? this.errorCode),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    expiresAt: clearExpiry ? null : (expiresAt ?? this.expiresAt),
    maskedSecret: maskedSecret ?? this.maskedSecret,
    payload: payload ?? this.payload,
  );
}

enum ShuCredentialState {
  unknown('未知'),
  refreshing('检查中'),
  available('可用'),
  missing('未登录'),
  expired('已过期'),
  failing('交换失败');

  const ShuCredentialState(this.label);

  final String label;
}

/// 三个系统各自的凭据交换实现。
///
/// 全部共享同一个 [ShuCookieStore]，所以一次登录后向三个系统分别授权即可，
/// 不需要重复认证。
class ShuCredentialService {
  // 构造参数是公开名（`authorizer`），字段是私有名，而 Dart 不允许
  // 以下划线开头的具名参数，所以这里没法用初始化形参。
  ShuCredentialService({
    required ShuCookieStore cookieStore,
    required ShuAuthorizeService authorizer,
    required String deviceId,
    required ShuATrustAuthChain atrustChain,
    HttpClient? httpClient,
  }) : _cookies = cookieStore,
       // ignore: prefer_initializing_formals
       _authorizer = authorizer,
       // ignore: prefer_initializing_formals
       _deviceId = deviceId,
       // ignore: prefer_initializing_formals
       _atrustChain = atrustChain,
       _client = httpClient ?? HttpClient() {
    _otp = ShuOtpService(cookieStore: cookieStore, httpClient: _client);
    _profile = ShuJwxtProfileService(
      cookieStore: cookieStore,
      httpClient: _client,
    );
  }

  final ShuCookieStore _cookies;
  final ShuAuthorizeService _authorizer;
  final String _deviceId;
  final HttpClient _client;

  late final ShuOtpService _otp;
  late final ShuJwxtProfileService _profile;

  /// 账号层已经登录过的 aTrust 链路；建隧道与凭据交换共用它。
  final ShuATrustAuthChain _atrustChain;

  /// 共享的 Cookie 容器（测试与上层诊断用）。
  ShuCookieStore get cookieStore => _cookies;

  void dispose() {
    _otp.dispose();
    _profile.dispose();
    _client.close(force: true);
  }

  /// 按系统 id 分派到具体的交换实现。
  Future<ShuSystemCredential> exchange(String systemId) async {
    final kind = ShuOAuthTargetKind.fromId(systemId);
    if (kind == null) {
      ShuLog.w(ShuLogTag.auth, '凭据交换 · 请求了未接入的系统 $systemId');
      return ShuSystemCredential.failed(
        systemId,
        code: 'unknownSystem',
        message: '未接入该系统',
      );
    }
    ShuLog.d(ShuLogTag.auth, '凭据交换 · $systemId');
    return switch (kind) {
      ShuOAuthTargetKind.atrust => exchangeATrust(),
      ShuOAuthTargetKind.otp => exchangeOtp(),
      ShuOAuthTargetKind.jwxt => exchangeJwxt(),
    };
  }

  // ---------------------------------------------------------------- aTrust

  /// 交换 aTrust 凭据。
  ///
  /// 这里**不是**一次「拿 cookie」的轻量请求，而是一次真正的 aTrust 登录：
  /// 走完 OAuth2 之后拿会话去建立 L3 隧道，确认节点选择与虚拟 IP 分配都能
  /// 走通，然后**立刻断开**。账号层的会话与 `authSession` 都会留下来，
  /// 所以用户之后点连接时不会重复任何一步。
  ///
  /// 对齐 `zju-connect`：它也是同一个进程里 `Login()` + 建隧道。
  Future<ShuSystemCredential> exchangeATrust() async {
    const target = ShuOAuthTargets.atrust;
    final server = Uri.parse('https://${ShuAuthConstants.atrustHost}');
    final session = ATrustConnector(
      loginSession: ATrustSSOLoginSession(chain: _atrustChain),
    );
    ShuLog.i(ShuLogTag.atrust, '凭据交换 · 建立一次真实隧道以验证 aTrust 会话');
    SangforSession connected;
    try {
      connected = await session.connect(
        SangforConnectOptions(
          server: server,
          // aTrust 的 OAuth2 路径不会把用户名交给网关（身份由授权码决定），
          // 但校验器要求它非空。与连接层用同一个占位值。
          username: ShuAuthConstants.oauthPlaceholderUsername,
          password: '-',
          loginDomain: _atrustChain.loginDomain,
          deviceId: _deviceId,
        ),
      );
      ShuLog.i(
        ShuLogTag.atrust,
        '凭据交换 · 隧道建立成功 · 虚拟地址 ${connected.virtualAddress ?? "-"}',
      );
    } finally {
      // 凭据交换的意义是「验证这次登录能走通」，不是把隧道挂起来。
      // 会话在账号层的 `authSession` 里，用户点连接时会另建一条隧道。
      await session.disconnect();
    }
    final sid =
        _cookies.valueFor(ShuAuthConstants.atrustHost, 'sid') ??
        _cookies.valueFor(ShuAuthConstants.atrustHost, 'sid-legacy');
    return ShuSystemCredential(
      systemId: target.kind.id,
      state: ShuCredentialState.available,
      // 不再写「会话已建立」这类复述状态的文案：账号页只看状态色。
      // 凭据本体（sid）留在 `maskedSecret`，虚拟 IP 交给连接页展示。
      maskedSecret: sid == null ? null : mask(sid),
      payload: <String, Object?>{
        'sid': ?sid,
        'virtualAddress': connected.virtualAddress,
        'dnsServers': connected.dnsServers,
        'loginDomain': _atrustChain.loginDomain,
      },
    );
  }

  // -------------------------------------------------------------------- OTP

  /// 交换 OTP 凭据。
  ///
  /// **先复用、后重授权**：口令页在会话仍然有效时直接就把口令返回了，
  /// 那种情况下整条 OAuth 一步都不必跑 —— 少一轮请求就少一处会失败的地方，
  /// 而 OTP 的 OAuth 链本来就是这条路上最脆的一段（引导页在会话有效时
  /// 不再返回 `state`，见 `ShuAuthorizeService._prepareState`）。
  ///
  /// 只有「会话真的没了」才回头把会话重新建一遍。网络类失败直接上报：
  /// 重走一遍授权也是一样的网络，只会多花几秒。
  Future<ShuSystemCredential> exchangeOtp() async {
    const target = ShuOAuthTargets.otp;

    // ① 会话还在 —— 口令页直接就给了口令。
    final direct = await _readOtpCode();
    if (direct.credential != null) {
      ShuLog.i(ShuLogTag.otp, '凭据交换 · 会话仍有效 · 未走 OAuth2 直接取到口令');
      return direct.credential!;
    }
    if (!direct.sessionLost) return direct.failure!;

    // ② 会话没了 —— 重新建立 OTP 的会话，再取一次。
    ShuLog.w(ShuLogTag.otp, '凭据交换 · 口令页判定会话失效 · 改走一轮完整 OAuth2');
    final callbackUri = await _authorizer.authorize(target);
    final result = await _authorizer.redeem(target, callbackUri);
    if (!_authorizer.isLoggedIn(target, result)) {
      ShuLog.w(ShuLogTag.otp, '凭据交换 · 重授权后仍未建立 OTP 会话');
      return ShuSystemCredential.failed(
        target.kind.id,
        code: 'otpSessionFailed',
        message: '未建立 OTP 会话（可能 state 校验失败）',
      );
    }
    ShuLog.i(ShuLogTag.otp, '凭据交换 · OTP 会话已重建 · 重新取口令');
    final retried = await _readOtpCode();
    return retried.credential ??
        retried.failure ??
        ShuSystemCredential.failed(
          target.kind.id,
          code: 'otpParseFailed',
          message: 'OTP 会话已重建，但仍未取到口令',
        );
  }

  /// 取一次当前动态口令，把「成功 / 失败 / 需要重授权」三件事分开。
  ///
  /// 私有：口令不做手动刷新（UI 上也没有这个入口）。需要实时口令的只有一个
  /// 场景 —— 交换凭据时证明会话确实可用，所以不对外暴露。
  Future<
    ({
      ShuSystemCredential? credential,
      ShuSystemCredential? failure,
      bool sessionLost,
    })
  >
  _readOtpCode() async {
    const target = ShuOAuthTargets.otp;
    try {
      final page = await _otp.fetch();
      return (
        credential: ShuSystemCredential(
          systemId: target.kind.id,
          state: ShuCredentialState.available,
          // 口令本体仍然取出来（它是这次交换成功的证据），但不摆到界面上：
          // 账号页不再显示口令，也不再显示「剩余 N 秒」—— 口令的时效由
          // 用户自己看别处的令牌源判断。
          maskedSecret: page.code,
          expiresAt: page.expiresAt,
          payload: <String, Object?>{
            'code': page.code,
            'account': page.account,
            'period': page.period,
          },
        ),
        failure: null,
        sessionLost: false,
      );
    } on ShuAuthException catch (error) {
      // `otpParseFailed` 也算「会话不可信」：服务端 200 但没给口令节点，
      // 最常见的原因就是被踢回了登录页却仍然回了 200。
      final sessionLost =
          error.code == 'otpSessionExpired' || error.code == 'otpParseFailed';
      return (
        credential: null,
        failure: ShuSystemCredential.failed(
          target.kind.id,
          code: error.code,
          message: error.message,
        ),
        sessionLost: sessionLost,
      );
    }
  }

  // ------------------------------------------------------------------- jwxt

  /// 交换教务系统凭据：授权 → 换会话 → 确认落在 `jwglxt` 里。
  ///
  /// 会话落地之后**顺带**读一次个人档案。教务系统是这套账号里唯一会
  /// 告诉客户端「你是谁」的系统，账号页那一块姓名/学号/专业/学院就是
  /// 从这里来的。读不到也不影响这次交换是否成功 —— 档案是展示信息，
  /// 不是凭据。
  ///
  /// 身份信息分两路取，**先权威后兜底**：
  ///
  /// 1. 课表数据接口的 `xsxx.XH` —— 学号的权威来源，语义没有歧义；
  /// 2. 个人信息片段 `media-heading` 里解出来的值 —— 一次请求同时拿到
  ///    年级 / 学院 / 专业，但标题格式由模板决定。
  ///
  /// 第 1 路缺的字段由第 2 路补上，所以两条都要跑。两次请求都很轻。
  Future<ShuSystemCredential> exchangeJwxt() async {
    const target = ShuOAuthTargets.jwxt;
    final callbackUri = await _authorizer.authorize(target);
    final result = await _authorizer.redeem(target, callbackUri);

    if (!_authorizer.isLoggedIn(target, result)) {
      ShuLog.w(ShuLogTag.jwxt, '凭据交换 · 未建立教务系统会话');
      return ShuSystemCredential.failed(
        target.kind.id,
        code: 'jwxtSessionFailed',
        message: '未建立教务系统会话',
      );
    }
    ShuLog.i(ShuLogTag.jwxt, '凭据交换 · 教务系统会话已建立 · 开始读档案与身份');
    final profile = await _fetchProfile();
    final identity = await _fetchIdentity();
    return ShuSystemCredential(
      systemId: target.kind.id,
      state: ShuCredentialState.available,
      payload: <String, Object?>{
        'finalUri': result.finalUri.toString(),
        ...?profile?.toPayload(),
        // 权威值覆盖兜底值：`xsxx` 里的 `XH` 说了算。
        if (identity?.studentId != null) 'studentId': identity!.studentId,
        if (identity?.name != null) 'name': identity!.name,
        if (identity?.className != null) 'className': identity!.className,
      },
    );
  }

  /// 读一次个人档案，任何异常都当作「没读到」。
  Future<ShuJwxtProfile?> _fetchProfile() async {
    try {
      return await _profile.fetch();
    } on Object catch (error) {
      // 档案页结构变了不值得让整次登录失败，留一条日志便于排查。
      ShuLog.w(ShuLogTag.jwxt, '教务系统个人档案读取失败 · $error · 本次只保存凭据');
      return null;
    }
  }

  /// 读一次课表接口里的身份信息，任何异常都当作「没读到」。
  Future<ShuJwxtIdentity?> _fetchIdentity() async {
    try {
      return await _profile.fetchScheduleIdentity();
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.jwxt, '教务系统身份信息读取失败 · $error · 只用档案片段里的值');
      return null;
    }
  }
}

/// 脱敏工具 [mask] 已随日志设施搬到 `lib/core/logging/shu_log.dart` ——
/// 它服务的正是「不要把凭据写进日志」这一件事，放在那里两边都能直接取用。

/// 向 [ShuCookieStore] 里查一个主机名下是否存在某个 Cookie（诊断用）。
extension ShuCookieStoreProbe on ShuCookieStore {
  /// 某个主机名下是否存在该名字的 Cookie。
  bool has(String host, String name) =>
      valueFor(host, name)?.isNotEmpty == true;

  /// 当前是否持有 SSO 会话。
  bool get hasSsoSession => contains(ShuAuthConstants.sessionCookieName);
}
