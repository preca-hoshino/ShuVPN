import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';

import '../logging/shu_log.dart';
import 'atrust_auth_chain.dart';
import 'auth_constants.dart';

/// aTrust 的登录会话：把「上海大学统一身份认证换来的 aTrust 会话」交给协议核心。
///
/// aTrust 网关本身就是一个 OAuth 客户端 —— `authConfig` 里
/// `authType == 'auth/httpsOauth2'` 那一项指向 newsso。浏览器上的流程是：
///
/// 1. 门户 302 到 `newsso.shu.edu.cn/oauth/authorize?...`；
/// 2. 用户登录后 SSO 302 回
///    `atrust.shu.edu.cn/passport/v1/auth/httpsOauth2?code=...`；
/// 3. aTrust 服务端拿这个 `code` 自己去 newsso 换 token，然后下发 `sid`。
///
/// 第 1、2 步由 [ShuATrustAuthChain] 用原生 HTTP 走完。
///
/// 但**光把 `sid` 塞给协议核心是不够的**：上大的网关只提供
/// `auth/httpsOauth2`，父类的本地密码分支（`auth/psw`）跑不通；而真正建隧道
/// 还差一步父类才知道的东西 —— `fetchAuthConfig` → `fetchOnlineInfo` →
/// `fetchClientResource`（后者算出 L3 节点组与虚拟 IP 分配）。
///
/// 所以这里不绕过父类，而是在它前面补上 OAuth2：Cookie 交给协议核心自己的
/// 客户端之后，`super.login()` 会看到 `isLogin == 1`，跳过密码认证，直接收尾。
class ATrustSSOLoginSession extends ATrustLoginSession {
  ATrustSSOLoginSession({
    required this.chain,
    this.target = ShuOAuthTargets.atrust,
  });

  /// OAuth2 链路。与账号层共用同一个实例 —— 它持有网关的 Cookie 与 csrf，
  /// 换过一次之后（`isLogin == 1`）再走也不会重复登录。
  final ShuATrustAuthChain chain;

  /// 本次登录要用的 OAuth 客户端注册信息。
  final ShuOAuthTarget target;

  /// 走 OAuth2 拿到网关会话，再交给协议核心收尾。
  @override
  Future<ATrustAuthenticatedSession> login(ATrustLoginOptions options) async {
    // ① OAuth2：code → ticket → reportEnv → authCheck 链。
    //    设备号必须用隧道那一份（`options.deviceId`），否则网关会把一次会话
    //    与一台设备判成两台机器。
    await chain.signIn(target, deviceId: options.deviceId);

    // ② 网关下发的全部 Cookie 原样交给协议核心，它才会认出 `isLogin == 1`。
    sessionClient.restoreCookies([
      for (final entry in chain.cookieJar.entries)
        ATrustCookie(
          name: entry.key,
          value: entry.value,
          domain: options.server.host,
          path: '/',
          secure: true,
          hostOnly: true,
        ),
    ]);

    // ③ 收尾：`isLogin == 1` 时父类不会碰密码，只做这三件事。
    final api = ATrustApiClient(client: sessionClient);
    final config = await _authConfig(api, options.server);
    if (!config.isLoggedIn) {
      throw const ATrustApiException(
        '统一身份认证已通过，但 aTrust 网关未承认这次会话（isLogin != 1）',
      );
    }
    final csrfToken = config.csrfToken;
    if (csrfToken == null || csrfToken.isEmpty) {
      throw const ATrustApiException('aTrust CSRF token is missing');
    }
    final sessionApi = ATrustSessionApi(
      server: options.server,
      csrfToken: csrfToken,
      client: sessionClient,
    );
    final onlineInfo = await sessionApi.fetchOnlineInfo();
    final resourceEnvelope = await api.fetchClientResource(
      server: options.server,
      csrfToken: csrfToken,
    );
    final sid = sessionClient.sid;
    if (sid == null || sid.isEmpty) {
      throw const ATrustApiException('authenticated session SID is missing');
    }
    return ATrustAuthenticatedSession(
      username: onlineInfo.username,
      sid: sid,
      resource: const ATrustResourceParser().parse(
        resourceEnvelope,
        serverHost: options.server.host,
      ),
      antiMitm: config.antiMitm,
    );
  }

  /// 取 `authConfig`，并让 anti-MITM 校验「只上报、不致命」。
  ///
  /// 协议核心的 [ATrustApiClient.fetchAuthConfig] 一旦校验失败就抛
  /// [FormatException]，直接把整条登录掐断；而上大的网关恰好稳定地
  /// 「挑战对得上、响应签名对不上」，于是每次都死在这一句。
  ///
  /// 参考实现（`zju-connect` 的 `authConfigContext`）对同一个校验：
  ///
  /// ```go
  /// if err := s.checkAntiMITMAuthConfig(ctx, resp, re.Data.AntiMITM, csrf); err != nil {
  ///     // Official desktop and Android clients report this through their
  ///     // event/UI layer, but their authentication callers continue.
  ///     log.Printf("aTrust anti-MITM check failed: %v", err)
  /// }
  /// ```
  ///
  /// 注释说得很直白：**官方客户端也只是把它记进事件/UI，认证流程照常继续**。
  /// 所以这里用 SDK 自带的 `enforceAntiMitm` 开关对齐这个语义 —— 先按原样
  /// 校验一次（能过就过，不改变任何行为），过不了再降级重读。
  ///
  /// 代价是这条路上去掉了响应签名与证书固定的检查；网关会话本身仍由
  /// 统一身份认证的授权码建立，且全程 HTTPS。真机上若要恢复严格校验，
  /// 把这个降级分支删掉即可。
  Future<ATrustAuthConfig> _authConfig(ATrustApiClient api, Uri server) async {
    try {
      return await api.fetchAuthConfig(server);
    } on FormatException catch (error) {
      ShuLog.w(
        ShuLogTag.atrust,
        'aTrust anti-MITM 校验未通过 · $error · 按参考实现的语义继续认证流程',
      );
      return ATrustApiClient(
        client: sessionClient,
        enforceAntiMitm: false,
      ).fetchAuthConfig(server);
    }
  }
}
