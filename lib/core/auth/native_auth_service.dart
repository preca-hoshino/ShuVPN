import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../logging/shu_log.dart';
import 'auth_constants.dart';
import 'auth_cookie_store.dart';
import 'client_user_agent.dart';

/// 两步验证方式。
enum ShuVerificationMethod {
  wecom(ShuAuthConstants.methodWeCom, '企业微信'),
  sms(ShuAuthConstants.methodSms, '手机号');

  const ShuVerificationMethod(this.wireName, this.label);

  final String wireName;
  final String label;

  static ShuVerificationMethod? fromWire(String? value) => switch (value) {
    ShuAuthConstants.methodWeCom => wecom,
    ShuAuthConstants.methodSms => sms,
    _ => null,
  };
}

/// 需要两步验证时的信息：可用的方式，以及每种方式投递到的账号（脱敏）。
class ShuLoginChallenge {
  const ShuLoginChallenge({required this.methods});

  /// 方式 → 目标账号，例如 `{wecom: '张三', sms: '138****8888'}`。
  final Map<ShuVerificationMethod, String> methods;

  bool get isEmpty => methods.isEmpty;

  String describe(ShuVerificationMethod method) {
    final target = methods[method];
    if (target == null || target.isEmpty) return '发送至统一身份认证绑定的账号';
    return method == ShuVerificationMethod.wecom
        ? '发送至企业微信账号 $target'
        : '发送至手机号 $target';
  }
}

/// 登录结果：要么直接拿到回调地址，要么需要两步验证。
class ShuLoginResult {
  const ShuLoginResult({this.challenge, this.callbackUri});

  final ShuLoginChallenge? challenge;
  final Uri? callbackUri;
}

/// 统一身份认证失败。
class ShuAuthException implements Exception {
  const ShuAuthException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// newsso 的密码加密：RSA PKCS#1 v1.5 后 base64。
///
/// 公钥来自登录 chunk 里的 `Pe` 常量；见 [ShuAuthConstants] 的说明。
class ShuPasswordEncryptor {
  const ShuPasswordEncryptor._();

  static const _rsaModulusHex =
      'e5fda0a0465f5fff838df4c7b0a159d5e7c38b394d802c18b614a739c88b1f4a'
      '98af2b17bb03a162b498c7bdadd6a4cee0bd53a29cc7a1a7a89fd9434891b68d'
      'fa99567f9230a84571b0d6697a2c5ce06b1b63d757124dd6b518f0192c832f24'
      'b3104487fe4a49568c4eee28d162a53eda8491c1304d78f3a4d47f8b450a2481';

  static String encrypt(String password) {
    final publicKey = RSAPublicKey(
      BigInt.parse(_rsaModulusHex, radix: 16),
      BigInt.from(65537),
    );
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(password)));
    return base64Encode(encrypted);
  }
}

/// 把 OAuth 参数编码成 newsso 前端使用的 **base64url（去掉 `=` 填充）**。
///
/// 例：`eyJyZXNwb25zZVR5cGUiOiJjb2RlIiwi...`（含 `_` 不含 `/`，无 padding）。
///
/// > 注意与 WebVPN 的 `state` 不同 —— 那个是标准 base64（带填充）。
String encodeOAuthParams(Map<String, String> params) {
  final raw = jsonEncode(params);
  return base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
}

/// 原生统一身份认证服务。
///
/// 走的是与浏览器完全一致的原生 HTTP 链路：
///
/// 1. 从 [ShuAuthConstants.paramsEntryUrl] 出发跟随 302，在
///    `/oauth2/login/<params>` 处停下并**截取路径里的 `params`** —— 这一步是
///    整条链路的地基，`params` 缺失或伪造都会得到 `badRequestParams`；
/// 2. `POST /oauth/userLogin`（密码 RSA 加密）→ 可选两步验证；
/// 3. 拿到 [ShuLoginResult.callbackUri] 后交给 WebView 完成最后一跳。
///
/// 登录成功后 SSO 下发 `SHU_OAUTH2`（HttpOnly，host-scoped 于 newsso），
/// 因此最后一步必须在 WebView 里做 —— dart:io 的 Cookie 无法写入 WebView。
class ShuNativeAuthService {
  ShuNativeAuthService({HttpClient? httpClient, ShuCookieStore? cookieStore})
    : _client = httpClient ?? HttpClient(),
      _cookieStore = cookieStore ?? ShuCookieStore() {
    _client.connectionTimeout = const Duration(seconds: 8);
    _client.userAgent = ClientUserAgent.mobileBrowser;
  }

  final HttpClient _client;
  final ShuCookieStore _cookieStore;

  /// 供 WebView 装入的 Cookie 快照。
  List<({Cookie cookie, String domain, String path})> get cookies =>
      _cookieStore.entries;

  // ------------------------------------------------------- 登录挑战的状态
  //
  // 两步验证要把第 ① 步的原参数原样回传，所以这里必须暂存。

  Uri? _loginUri;
  String? _params;
  String? _username;
  String? _encryptedPassword;

  void dispose() => _client.close(force: true);

  /// 把外部流程（企业微信扫码）取得的会话 Cookie 并入本次认证会话。
  ///
  /// 企微扫码走的是独立的 `ShuWeComAuthService`，不会经过本类的 [login]，
  /// 因此 [_cookieStore] 是空的。必须在 [installCookiesInWebView] 之前并入，
  /// 否则 WebView 加载 callbackUri 时会因缺少会话被重定向回登录页。
  void adoptSessionCookies(
    Iterable<({Cookie cookie, String domain, String path})> cookies,
  ) {
    for (final entry in cookies) {
      if (entry.cookie.name.isEmpty || entry.cookie.value.isEmpty) continue;
      final scoped = Cookie(entry.cookie.name, entry.cookie.value)
        ..domain = entry.domain
        ..path = entry.path;
      _cookieStore.save(Uri.parse('https://${entry.domain}'), [scoped]);
    }
  }

  /// 把原生会话的 Cookie 装进 WebView。
  ///
  /// 装完必须回读确认 —— Android 的 `CookieManager.setCookie` 在平台层是
  /// fire-and-forget，写入后立刻导航会用到尚未提交的旧会话。
  Future<void> installCookiesInWebView() async {
    final manager = WebViewCookieManager();
    final domains = <String>{};
    final expectedByDomain = <String, Map<String, String>>{};
    for (final stored in _cookieStore.entries) {
      final cookie = stored.cookie;
      if (cookie.value.isEmpty) continue;
      domains.add(stored.domain);
      expectedByDomain.putIfAbsent(
        stored.domain,
        () => <String, String>{},
      )[cookie.name] = cookie.value;
      await manager.setCookie(
        WebViewCookie(
          name: cookie.name,
          value: _webViewCookieValue(cookie.value),
          domain: stored.domain,
          path: stored.path,
        ),
      );
    }
    if (domains.isEmpty) return;

    for (var attempt = 0; attempt < 6; attempt++) {
      await Future<void>.delayed(
        attempt == 0
            ? const Duration(milliseconds: 150)
            : const Duration(milliseconds: 300),
      );
      var allVisible = true;
      for (final domain in domains) {
        List<WebViewCookie> visible;
        try {
          visible = await manager.getCookies(
            domain: Uri.parse('https://$domain'),
          );
        } on Object {
          allVisible = false;
          continue;
        }
        final expected = expectedByDomain[domain] ?? const <String, String>{};
        for (final entry in expected.entries) {
          final hasExpectedValue = visible.any(
            (cookie) =>
                cookie.name == entry.key &&
                _cookieValueMatches(entry.value, cookie.value),
          );
          if (!hasExpectedValue) allVisible = false;
        }
      }
      if (allVisible) {
        // Chromium 的 network service 可能还在提交中；放一拍再导航。
        if (defaultTargetPlatform == TargetPlatform.android) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        return;
      }
    }

    // 部分 Android WebView 版本对已转义的会话 Cookie 处理不同，
    // 回退成原始线上值再写一次。
    if (defaultTargetPlatform == TargetPlatform.android) {
      for (final stored in _cookieStore.entries) {
        final cookie = stored.cookie;
        if (cookie.value.isEmpty) continue;
        await manager.setCookie(
          WebViewCookie(
            name: cookie.name,
            value: cookie.value,
            domain: stored.domain,
            path: stored.path,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// 第 ① 步：密码登录。
  ///
  /// 返回的 [ShuLoginResult] 要么带 `callbackUri`（直接成功），
  /// 要么带 `challenge`（需要两步验证）。
  Future<ShuLoginResult> login({
    required String username,
    required String password,
  }) {
    return _runStage('credentials', () async {
      _clearChallenge();
      // 先发现真实登录页，从路径里截出 params —— 硬编码会 badRequestParams。
      final loginUri = await _discoverLoginUri();
      final params = _extractParams(loginUri);
      // `params` 是服务端下发的一次性串，只报长度不报内容。
      ShuLog.d(ShuLogTag.auth, '登录 · 已发现认证入口 · params ${params.length} 字符');
      final encryptedPassword = ShuPasswordEncryptor.encrypt(password);
      ShuLog.d(ShuLogTag.auth, '登录 · POST /oauth/userLogin');
      final response = await _jsonRequest(
        'POST',
        loginUri.resolve('/oauth/userLogin'),
        body: {
          'username': username,
          'password': encryptedPassword,
          'tenantId': ShuAuthConstants.tenant,
          'params': params,
        },
        referer: loginUri,
      );
      _requireSuccess(response);
      ShuLog.d(
        ShuLogTag.auth,
        '登录 · 响应 twoStepRequired=${response['twoStepRequired'] == true}',
      );

      if (response['twoStepRequired'] == true) {
        // 会话尚未建立，把上下文暂存后交回 UI。
        _loginUri = loginUri;
        _params = params;
        _username = username;
        _encryptedPassword = encryptedPassword;
        final methods = _parseMethods(response['twoStepMethods']);
        if (methods.isEmpty) {
          throw const ShuAuthException('noTwoStepMethod', '学校未返回可用的验证方式');
        }
        ShuLog.i(
          ShuLogTag.auth,
          '登录 · 学校要求两步验证 · '
          '${methods.keys.map((m) => m.label).join("、")}',
        );
        return ShuLoginResult(challenge: ShuLoginChallenge(methods: methods));
      }

      final callbackUri = _callbackFrom(loginUri, response);
      ShuLog.d(ShuLogTag.auth, '登录 · 已拿到业务系统回调地址 ${callbackUri.host}');
      _clearChallenge();
      return ShuLoginResult(callbackUri: callbackUri);
    });
  }

  /// 第 ② 步：发送验证码。必须在 [login] 返回了 challenge 之后调用。
  Future<void> sendCode(ShuVerificationMethod method) {
    return _runStage('send-code', () async {
      final loginUri = _requireChallenge();
      ShuLog.i(ShuLogTag.auth, '两步验证 · 请求发送验证码 · ${method.label}');
      final response = await _jsonRequest(
        'POST',
        loginUri.resolve('/oauth/twoStep/send'),
        body: {'method': method.wireName},
        referer: loginUri,
      );
      _requireSuccess(response);
      ShuLog.d(ShuLogTag.auth, '两步验证 · 发送接口已返回成功');
    });
  }

  /// 第 ③ 步：校验验证码，成功时返回业务系统回调地址。
  Future<Uri> verifyCode({
    required ShuVerificationMethod method,
    required String code,
  }) {
    return _runStage('verify-code', () async {
      final loginUri = _requireChallenge();
      ShuLog.i(
        ShuLogTag.auth,
        '两步验证 · 提交验证码 · ${method.label} · ${code.trim().length} 位',
      );
      final response = await _jsonRequest(
        'POST',
        loginUri.resolve('/oauth/twoStep/verify'),
        body: {
          'username': _username,
          'password': _encryptedPassword,
          'tenantId': ShuAuthConstants.tenant,
          'params': _params,
          'code': code,
          'method': method.wireName,
        },
        referer: loginUri,
      );
      _requireSuccess(response);
      final callbackUri = _callbackFrom(loginUri, response);
      ShuLog.i(ShuLogTag.auth, '两步验证 · 通过 · 已拿到回调地址 ${callbackUri.host}');
      _clearChallenge();
      return callbackUri;
    });
  }

  // --------------------------------------------------------- 发现与网络请求

  /// 跟随 302 链找到真实的 SSO 登录页，返回其完整地址。
  ///
  /// 登录页形如 `https://newsso.shu.edu.cn/oauth2/login/<params>`；
  /// [ShuAuthConstants.paramsEntryUrl] 会 302 到这里。
  Future<Uri> _discoverLoginUri() async {
    var uri = Uri.parse(ShuAuthConstants.paramsEntryUrl);
    _validateUri(uri);
    for (var redirects = 0; redirects < 16; redirects++) {
      final response = await _request('GET', uri);
      final next = _redirectTarget(response, uri);
      await response.drain<void>();
      if (next == null) {
        if (uri.path.contains(ShuAuthConstants.loginPathMarker)) {
          ShuLog.d(ShuLogTag.auth, '登录入口 · 经过 $redirects 跳后停在登录页');
          return uri;
        }
        throw const ShuAuthException('loginPageNotFound', '无法取得统一认证登录入口');
      }
      // 命中登录页后还要再走一跳：SSO 会在这一跳把 params 补全。
      if (next.path.contains(ShuAuthConstants.loginPathMarker)) {
        final loginPage = await _request('GET', next);
        final loginRedirect = _redirectTarget(loginPage, next);
        await loginPage.drain<void>();
        return loginRedirect ?? next;
      }
      uri = next;
    }
    throw const ShuAuthException('tooManyRedirects', '认证入口跳转次数过多');
  }

  /// 从登录页路径里截出 `params`（`/oauth2/login/` 之后的部分）。
  String _extractParams(Uri loginUri) {
    const marker = ShuAuthConstants.loginPathMarker;
    final index = loginUri.path.indexOf(marker);
    if (index < 0) {
      throw const ShuAuthException('missingParams', '认证地址缺少登录参数');
    }
    final params = loginUri.path.substring(index + marker.length);
    if (params.isEmpty) {
      throw const ShuAuthException('missingParams', '认证地址缺少登录参数');
    }
    return params;
  }

  Uri _callbackFrom(Uri loginUri, Map<String, dynamic> response) {
    final redirect = response['redirectUri']?.toString();
    if (redirect == null || redirect.isEmpty) {
      throw const ShuAuthException('missingRedirect', '登录成功，但学校未返回授权地址');
    }
    final callbackUri = loginUri.resolve(redirect);
    _validateUri(callbackUri);
    return callbackUri;
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    Uri? referer,
  }) async {
    final response = await _request(
      method,
      uri,
      body: body == null ? null : jsonEncode(body),
      referer: referer,
    );
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } on Object {
      throw ShuAuthException(
        'invalidResponse',
        '学校认证服务返回了无法识别的内容（HTTP ${response.statusCode}）',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = json['message']?.toString() ?? 'http${response.statusCode}';
      throw ShuAuthException(code, messageForCode(code));
    }
    return json;
  }

  Future<HttpClientResponse> _request(
    String method,
    Uri uri, {
    String? body,
    Uri? referer,
  }) async {
    _validateUri(uri);
    final request = await _client.openUrl(method, uri);
    request.followRedirects = false;
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
      ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser);
    final cookieHeader = _cookieStore.headerFor(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    if (referer != null) {
      request.headers.set(HttpHeaders.refererHeader, referer.toString());
      request.headers.set('Origin', '${referer.scheme}://${referer.authority}');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    _cookieStore.save(uri, response.cookies);
    return response;
  }

  Uri? _redirectTarget(HttpClientResponse response, Uri current) {
    if (response.statusCode < 300 || response.statusCode >= 400) return null;
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) return null;
    var next = current.resolve(location);
    // 部分校园网关会先回一个 http 的规范化地址，浏览器会立刻升级回 https；
    // 这里照做，保证整条认证链路都是加密的。
    if (next.scheme == 'http' && ShuAuthConstants.isShuHost(next.host)) {
      next = next.replace(scheme: 'https');
    }
    _validateUri(next);
    return next;
  }

  Future<T> _runStage<T>(String stage, Future<T> Function() operation) async {
    try {
      return await operation();
    } on ShuAuthException {
      rethrow;
    } on TimeoutException {
      throw const ShuAuthException('timeout', '连接学校认证服务超时，请使用校园网访问');
    } on SocketException {
      throw const ShuAuthException('network', '无法连接学校认证服务，请检查网络');
    } on HandshakeException {
      throw const ShuAuthException('tls', '与学校认证服务的证书校验失败');
    } on Object catch (error) {
      throw ShuAuthException('unknown', '登录失败：$error');
    }
  }

  // ------------------------------------------------------------------ 工具

  Map<ShuVerificationMethod, String> _parseMethods(Object? raw) {
    final methods = <ShuVerificationMethod, String>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final method = ShuVerificationMethod.fromWire(entry.key.toString());
        if (method != null) methods[method] = entry.value?.toString() ?? '';
      }
    }
    return methods;
  }

  void _requireSuccess(Map<String, dynamic> response) {
    final code = response['message']?.toString();
    if (code != 'success') {
      final key = code ?? 'unknown';
      throw ShuAuthException(key, messageForCode(key));
    }
  }

  Uri _requireChallenge() {
    final uri = _loginUri;
    if (uri == null ||
        _params == null ||
        _username == null ||
        _encryptedPassword == null) {
      throw const ShuAuthException('challengeExpired', '登录状态已失效，请重新输入账号密码');
    }
    return uri;
  }

  void _clearChallenge() {
    _loginUri = null;
    _params = null;
    _username = null;
    _encryptedPassword = null;
  }

  /// 丢弃暂存的两步验证上下文（退出登录时调用）。
  void clearChallenge() => _clearChallenge();

  void _validateUri(Uri uri) {
    if (uri.scheme != 'https' || !ShuAuthConstants.isShuHost(uri.host)) {
      throw const ShuAuthException('unsafeRedirect', '认证服务返回了非上海大学的跳转地址');
    }
  }

  /// 把原生 `Set-Cookie` 的值转成 WebView 需要的形态。
  ///
  /// `webview_flutter_android` 会在 `setCookie` 内部再做一次转义，而原生
  /// Set-Cookie 已经是线上表示，所以要先解掉一层，否则会话 Cookie 会被
  /// 双重编码后服务端拒绝。
  String _webViewCookieValue(String value) {
    if (defaultTargetPlatform != TargetPlatform.android) return value;
    try {
      return Uri.decodeComponent(value);
    } on FormatException {
      return value;
    }
  }

  static bool _cookieValueMatches(String expected, String actual) {
    if (expected == actual) return true;
    try {
      return Uri.decodeComponent(actual) == expected;
    } on FormatException {
      return false;
    }
  }

  /// newsso 的错误码 → 中文说明。基于 POC 实测集合。
  static String messageForCode(String code) => switch (code) {
    'badPassword' => '学号或密码错误',
    'userNotFound' => '未找到该校园账户',
    'invalidCode' => '验证码错误或已失效',
    'userLocked' => '账户已被锁定，请稍后重试',
    'ipLimitExceeded' => '登录请求过于频繁，请稍后重试',
    'sendError' || 'senderror' => '验证码发送过于频繁，请切换验证方式或稍后再试',
    'userNotAllowed' => '该账户暂时无法登录此服务',
    'internalServerError' => '学校认证服务暂时不可用',
    // 这个客户端没有在 newsso 注册，或 params 被伪造。
    'badRequestParams' => '登录参数无效，请升级应用后重试',
    _ => '登录失败，请稍后重试（$code）',
  };
}

/// 产生随机 32 位十六进制串，用于 jwxt 的 CSRF state。
String randomHex32([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(
    16,
    (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
