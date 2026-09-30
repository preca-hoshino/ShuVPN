import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../logging/shu_log.dart';
import 'atrust_auth_chain.dart';
import 'atrust_device_id.dart';
import 'authorize_service.dart';
import 'auth_constants.dart';
import 'auth_cookie_store.dart';
import 'credential_service.dart';
import 'credential_store.dart';
import 'native_auth_service.dart';
import 'wecom_auth_service.dart';

/// 一次登录会话的全部原生 HTTP 状态。
///
/// 三个服务共享同一个 [ShuCookieStore]，这是整条链路能工作的前提：
/// `SHU_OAUTH2` 由 [ShuNativeAuthService] 或 [ShuWeComAuthService] 建立，
/// 随后 [ShuAuthorizeService] 必须带着同一个 Cookie 去各业务系统换授权码，
/// 否则会被判定为未登录并跳回登录页。
///
/// 生命周期与账户中心一致 —— 登录、刷新、退出都在这里收口。
class ShuAuthSession {
  ShuAuthSession({HttpClient? httpClient, SharedPreferences? preferences}) {
    _store = preferences == null ? null : ShuCredentialStore(preferences);
    _native = ShuNativeAuthService(
      httpClient: httpClient,
      cookieStore: _cookies,
    );
    _authorizer = ShuAuthorizeService(
      cookieStore: _cookies,
      httpClient: httpClient,
    );
    // 设备号在账号层与隧道层之间共享：`reportEnv` 上报的设备和建隧道用的
    // 设备必须是同一个，否则网关会把一次会话与一台设备判成两台机器。
    _deviceId = ShuATrustDeviceId(preferences).value;
    _atrustChain = ShuATrustAuthChain(
      cookieStore: _cookies,
      deviceId: _deviceId,
      httpClient: httpClient ?? HttpClient(),
    );
    _credentials = ShuCredentialService(
      cookieStore: _cookies,
      authorizer: _authorizer,
      deviceId: _deviceId,
      atrustChain: _atrustChain,
      httpClient: httpClient,
    );
    _restorePersistedSession();
  }

  final ShuCookieStore _cookies = ShuCookieStore();

  /// 持久化的统一身份认证会话；未注入 `preferences` 时为 null（单测）。
  late final ShuCredentialStore? _store;

  // 三个服务共享同一个 Cookie 容器 —— 这正是整条链路能工作的前提。
  late final ShuNativeAuthService _native;
  late final ShuAuthorizeService _authorizer;
  late final ShuCredentialService _credentials;
  late final ShuATrustAuthChain _atrustChain;
  late final String _deviceId;

  ShuNativeAuthService get native => _native;
  ShuAuthorizeService get authorizer => _authorizer;
  ShuCredentialService get credentials => _credentials;

  /// 已登录的 aTrust 链路。
  ///
  /// 连接层用它来建隧道 —— 链路里已经有网关的全部 Cookie 与 csrf token，
  /// `signIn` 会直接命中 `isLogin == 1`，不会重复走一遍 OAuth2。
  ShuATrustAuthChain get atrustChain => _atrustChain;

  /// aTrust 会话绑定的设备号；建隧道时也要用它。
  String get deviceId => _deviceId;

  /// 共享的 Cookie 容器；企微扫码流程也要用它，才能把会话交回这里。
  ShuCookieStore get cookieStore => _cookies;

  /// 是否已经建立 `SHU_OAUTH2` 会话。
  bool get hasSession => _cookies.contains(ShuAuthConstants.sessionCookieName);

  /// 从磁盘恢复会话。
  ///
  /// 只把会话 Cookie 放回 [cookieStore] —— 各业务系统的凭据**不存盘**，
  /// 它们是换来的，而且换了会过期。要拿它们得真的跑一轮核对：
  /// 用户打开账户页时（`AccountCenter.verifyIfStale`）或登录完之后。
  void _restorePersistedSession() {
    final store = _store;
    if (store == null) return;
    final cookies = store.restore();
    if (cookies.isEmpty) return;
    // 域名显式钉在 newsso 上：`SHU_OAUTH2` 是 host-scoped 的，
    // 不能指望 `dart:io` 从 Set-Cookie 文本里推出域名。
    _cookies.save(Uri.parse(ShuAuthConstants.ssoBase), cookies);
    if (!hasSession) return;
    // WebView 也要拿到，否则业务系统回调页在 WebView 里会当成未登录。
    // 失败不影响 HTTP 链路（缓存里的 Cookie 已经够用了）。
    _native.installCookiesInWebView().catchError((Object error) {
      ShuLog.w(ShuLogTag.auth, '恢复会话时写入 WebView Cookie 失败 · $error · 忽略');
    });
  }

  /// 把当前会话落盘。
  ///
  /// 在登录成功、以及一次凭据交换结束之后调 —— `SHU_OAUTH2` 的
  /// `expires` 可能与它实际的服务端有效期不一致，重存一次能拿到最新值。
  Future<void> persistSession() async {
    final store = _store;
    if (store == null || !hasSession) return;
    final cookie = _cookies
        .cookiesFor(Uri.parse(ShuAuthConstants.ssoBase))
        .entries
        .where((entry) => entry.key == ShuAuthConstants.sessionCookieName)
        .map((entry) => Cookie(entry.key, entry.value)..path = '/');
    if (cookie.isEmpty) return;
    await store.save(cookie);
  }

  /// 把会话 Cookie 装进 WebView（业务系统回调页在 WebView 里加载）。
  Future<void> installCookiesInWebView() => _native.installCookiesInWebView();

  /// 清空本地会话状态（退出登录），连带抹掉磁盘上的那一份。
  void clear() {
    _cookies.clear();
    _native.clearChallenge();
    unawaited(_store?.clear() ?? Future<void>.value());
  }

  /// 用企微扫码完成的授权码换取业务系统回调地址。
  ///
  /// 扫码流程有自己的 HTTP 客户端，但必须把 Cookie 并进本会话，
  /// 否则 [ShuAuthorizeService] 拿不到 `SHU_OAUTH2`。
  void adoptCookies(
    Iterable<({Cookie cookie, String domain, String path})> cookies,
  ) => _native.adoptSessionCookies(cookies);

  void dispose() {
    _native.dispose();
    _authorizer.dispose();
    _credentials.dispose();
  }
}
