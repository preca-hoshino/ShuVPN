import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/shu_log.dart';
import 'auth_constants.dart';
import 'auth_cookie_store.dart';
import 'client_user_agent.dart';
import 'native_auth_service.dart';

/// 一次换会话的 HTTP 结果，供系统实现自行判定。
class ShuSystemResponse {
  const ShuSystemResponse({
    required this.statusCode,
    required this.body,
    required this.finalUri,
    required this.header,
  });

  final int statusCode;
  final String body;
  final Uri finalUri;

  /// 大小写不敏感的头读取器。
  final String? Function(String name) header;

  bool hasBody(String needle) => body.contains(needle);

  bool hasUrl(String needle) => finalUri.toString().contains(needle);
}

/// 阶段二：用已建立的 SSO 会话向业务系统换取授权码，并完成换会话。
///
/// 与 [ShuNativeAuthService] 共享同一个 [ShuCookieStore]，
/// 因此 `SHU_OAUTH2` 会话只建立一次。
class ShuAuthorizeService {
  ShuAuthorizeService({
    required ShuCookieStore cookieStore,
    HttpClient? httpClient,
  }) : _cookies = cookieStore,
       _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 8);
    _client.userAgent = ClientUserAgent.mobileBrowser;
  }

  final ShuCookieStore _cookies;
  final HttpClient _client;

  /// 上一次成功拿到的 `state`，按系统缓存。
  ///
  /// 引导页只在**未登录**时才会 302 出 `state`；会话已经建立时它直接回业务
  /// 页面（200），拿不到任何跳转。这不是错误，只是「这次不需要重新授权」，
  /// 所以缓存一份，下次同一条链上有东西可用。
  final Map<String, String> _stateCache = <String, String>{};

  static const _normalTimeout = Duration(seconds: 15);

  /// 手动跟随 302 的跳数上限。参考实现用 10，这里留同样的余量。
  static const _maxRedirects = 10;

  void dispose() => _client.close(force: true);

  /// 向 [target] 换取授权码，返回其 302 的落地地址。
  ///
  /// 先按目标系统的策略准备 `state`，再请求 `/oauth/authorize`。
  Future<Uri> authorize(ShuOAuthTarget target) async {
    final state = await _prepareState(target);
    final uri = Uri.parse(ShuAuthConstants.ssoBase).replace(
      path: ShuAuthConstants.authorizePath,
      queryParameters: {
        'response_type': 'code',
        'client_id': target.clientId,
        'redirect_uri': target.redirectUri,
        if (target.scope.isNotEmpty) 'scope': target.scope,
        if (state.isNotEmpty) 'state': state,
      },
    );
    final response = await _get(uri);
    final statusCode = response.statusCode;
    final location = response.headers.value(HttpHeaders.locationHeader);
    await response.drain<void>();
    if (statusCode < 300 || statusCode >= 400 || location == null) {
      throw ShuAuthException(
        'authorizeFailed',
        '统一认证未返回${target.clientName}的授权地址（HTTP $statusCode）',
      );
    }
    // 会话未被复用时会跳回登录页，说明 SHU_OAUTH2 没有生效。
    if (location.contains(ShuAuthConstants.loginPathMarker)) {
      throw const ShuAuthException('sessionNotReused', '统一认证会话未能复用，请重新登录');
    }
    final callbackUri = uri.resolve(location);
    _validateRedirect(callbackUri, target.redirectUri);
    return callbackUri;
  }

  /// 把一次性授权码交回业务系统的回调地址，完成换会话。
  ///
  /// 返回落地结果，由调用方按 [ShuOAuthTarget] 的成功关键词判定。
  Future<ShuSystemResponse> redeem(
    ShuOAuthTarget target,
    Uri callbackUri,
  ) async {
    final followed = await _follow(callbackUri);
    var response = followed.response;
    var landed = followed.finalUri;
    var body = await _readBody(response);

    // 部分系统的回调页用 `Refresh` 头跳转而非 302，需手动补访问一次。
    final followUp = target.followUpUrl;
    if (followUp != null && !_matches(target, landed, body)) {
      final retry = await _follow(Uri.parse(followUp));
      response = retry.response;
      landed = retry.finalUri;
      body = await _readBody(response);
    }

    return ShuSystemResponse(
      statusCode: response.statusCode,
      body: body,
      finalUri: landed,
      header: response.headers.value,
    );
  }

  /// 判定换会话是否成功。
  bool isLoggedIn(ShuOAuthTarget target, ShuSystemResponse result) =>
      _matches(target, result.finalUri, result.body);

  // ------------------------------------------------------------------ 内部

  bool _matches(ShuOAuthTarget target, Uri landed, String body) {
    final urlMatch = target.successUrlContains;
    final bodyMatch = target.successBodyContains;
    if (urlMatch != null && landed.toString().contains(urlMatch)) return true;
    if (bodyMatch != null && body.contains(bodyMatch)) return true;
    return false;
  }

  /// 按目标系统准备 `state`。
  ///
  /// **不再把「引导页必须返回 302」当成硬前置**。这件事曾经让 OTP 的凭据
  /// 交换时好时坏：`otp` 是唯一配了 [ShuOAuthTarget.needsStateBootstrap] 的
  /// 系统，而它的引导地址就是站点根 —— 会话有效时根路径直接返回业务页面
  /// （200），于是「上一轮刚成功过」反而成了「这一轮必然失败」。
  ///
  /// 现在按三级回落，每一步都能把流程带下去：
  ///
  /// 1. 引导响应的 `Location` 里有 `state` → 用它（正常路径）；
  /// 2. 引导页正文里写着登录链接或隐藏域 → 从里面取；
  /// 3. 都不行 → 沿用上次成功过的值；再没有则用空串继续。
  ///
  /// 空 `state` 不是错误：服务端本来就允许不带（`jwxt` 那条链的 state 是
  /// 本地生成的）。真出问题会在 `authorize` 那儿以 `sessionNotReused` 报
  /// 出来，那时报的是**真实原因**，而不是一句含糊的「取不到授权参数」。
  Future<String> _prepareState(ShuOAuthTarget target) async {
    final bootstrap = target.needsStateBootstrap;
    if (bootstrap != null) {
      final discovered = await _discoverState(target, bootstrap);
      if (discovered != null && discovered.isNotEmpty) {
        _stateCache[target.kind.id] = discovered;
        return discovered;
      }
      final cached = _stateCache[target.kind.id];
      if (cached != null && cached.isNotEmpty) {
        ShuLog.d(
          ShuLogTag.auth,
          '${target.clientName} 的引导页未返回 state · 沿用上次的缓存值',
        );
        return cached;
      }
      ShuLog.w(
        ShuLogTag.auth,
        '${target.clientName} 的引导页既无 state 也无缓存 · 按空 state 继续',
      );
      return '';
    }
    if (target.generateState) {
      // jwxt 的授权请求不带 state，本地生成随机值防 CSRF。
      return randomHex32();
    }
    return '';
  }

  /// 访问引导地址并从中找 `state`。任何异常都当作「没找到」。
  Future<String?> _discoverState(ShuOAuthTarget target, String url) async {
    HttpClientResponse response;
    try {
      response = await _get(Uri.parse(url));
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.auth, '${target.clientName} 的授权参数引导请求失败 · $error');
      return null;
    }
    final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
    // 预热请求本身也可能带 Set-Cookie，必须读掉响应体，否则连接会泄漏。
    final body = await _readBody(response);
    return _stateFromLocation(location) ?? _stateFromBody(body);
  }

  /// 从跳转地址里取 `state`。
  String? _stateFromLocation(String location) {
    if (location.isEmpty) return null;
    final value = Uri.tryParse(location)?.queryParameters['state'];
    return (value != null && value.isNotEmpty) ? value : null;
  }

  /// 从引导页正文里取 `state`。
  ///
  /// 页面把登录链接写在 HTML 里是常见写法（`/oauth2/login/<params>?state=…`），
  /// 也可能放在表单的隐藏域中。
  String? _stateFromBody(String body) {
    if (body.isEmpty) return null;
    final link = _loginLinkPattern.firstMatch(body)?.group(1);
    if (link != null) {
      // HTML 转义后的 `&amp;` 会让查询串解析错位，先还原。
      final decoded = link.replaceAll('&amp;', '&');
      final value = Uri.tryParse(decoded)?.queryParameters['state'];
      if (value != null && value.isNotEmpty) return value;
    }
    final field = _stateFieldPattern.firstMatch(body)?.group(1);
    return (field != null && field.isNotEmpty) ? field : null;
  }

  Future<HttpClientResponse> _get(
    Uri uri, {
    bool followRedirects = false,
  }) async {
    final request = await _client.getUrl(uri);
    request.followRedirects = followRedirects;
    request.maxRedirects = 16;
    request.headers
      ..set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,*/*;q=0.8',
      )
      ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser)
      ..set(HttpHeaders.refererHeader, ShuAuthConstants.ssoBase)
      ..set('Origin', ShuAuthConstants.ssoBase);
    final cookieHeader = _cookies.headerFor(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    final response = await request.close().timeout(_normalTimeout);
    _cookies.save(uri, response.cookies);
    return response;
  }

  Future<String> _readBody(HttpClientResponse response) async {
    try {
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(_normalTimeout);
    } on Object {
      return '';
    }
  }

  /// 手动跟随 302 链，**每一跳都把 `Set-Cookie` 收进 [ShuCookieStore]**。
  ///
  /// 为什么不能交给 `HttpClient.followRedirects = true`：
  /// `dart:io` 的 `_HttpClientResponse.redirect()` 只把**上一跳的请求头**
  /// 复制给下一跳（同源时保留 `Cookie`），**从不把中间跳转响应的
  /// `Set-Cookie` 并进去** —— 它没有 cookie jar。
  ///
  /// 这个坑对教务系统是致命的：`/sso/shulogin?code=…` 下发 `JSESSIONID`，
  /// 紧接着一跳才落到 `jwglxt/…`。自动跟随会把那个 `JSESSIONID` 丢掉，
  /// 于是后续请求全是未登录 —— 正方对 AjAx 请求不回登录页，**直接回
  /// 空 body 的 `901`**。
  ///
  /// 实测（本地两跳 302 的探针）：
  /// ```text
  /// 自动跟随  -> 落点收到的 Cookie: ""            ← 中间跳全丢
  /// 手动逐跳  -> 落点收到的 Cookie: "hopa; hopb"  ← 收全了
  /// ```
  ///
  /// 参考实现（`ShuYo`）在整个教务系统链路上都是
  /// `request.followRedirects = false` + 手写跳转循环。
  Future<({HttpClientResponse response, Uri finalUri})> _follow(
    Uri start,
  ) async {
    var current = start;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final request = await _client.getUrl(current);
      request.followRedirects = false;
      request.headers
        ..set(
          HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,*/*;q=0.8',
        )
        ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser)
        ..set(HttpHeaders.refererHeader, ShuAuthConstants.ssoBase)
        ..set('Origin', ShuAuthConstants.ssoBase);
      final cookieHeader = _cookies.headerFor(current);
      if (cookieHeader.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      final response = await request.close().timeout(_normalTimeout);
      // 关键一步：这一跳下发的 Cookie 要在**发出下一跳之前**进 jar。
      _cookies.save(current, response.cookies);

      final location = response.headers.value(HttpHeaders.locationHeader);
      final isRedirect =
          response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null;
      if (!isRedirect || hop == _maxRedirects) {
        // 落地（或跳数用尽）。调用方按成功关键词判定，失败也交回响应。
        return (response: response, finalUri: current);
      }
      // 换下一跳前必须读掉响应体，否则连接会泄漏。
      await response.drain<void>().timeout(_normalTimeout);
      final next = current.resolve(location);
      // 只跟同源或本校域名。教务系统整条链都在 `jwxt.shu.edu.cn` 上，
      // 所以「同源」已经覆盖正常路径；保留「本校域名」是为了容忍
      // `jwxt → newsso` 这类校内跨子域跳转。校外地址一律不跟。
      if (next.host != start.host && !ShuAuthConstants.isShuHost(next.host)) {
        throw ShuAuthException(
          'unsafeRedirect',
          '业务系统把回调跳到了校外地址（${next.host}）',
        );
      }
      current = next;
    }
    // 不可能到达：循环最后一次迭代（hop == _maxRedirects）必定返回。
    throw const ShuAuthException('tooManyRedirects', '业务系统跳转次数过多');
  }

  /// 校验授权回调地址，防止 SSO 返回任意 https 地址时导航到恶意站点。
  void _validateRedirect(Uri uri, String expectedRedirect) {
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw const ShuAuthException('unsafeRedirect', '统一认证返回了不安全的跳转地址');
    }
    final expected = Uri.parse(expectedRedirect);
    if (uri.host != expected.host || uri.path != expected.path) {
      throw const ShuAuthException('unexpectedRedirect', '统一认证返回了未预期的跳转地址');
    }
  }
}

/// 引导页正文里的登录链接（`/oauth2/login/<params>?state=…`）。
///
/// 第二个备选分支允许 `?state=` 单独出现在链接里（部分模板会先拼路径再补查询串）。
final _loginLinkPattern = RegExp(
  '(${RegExp.escape(ShuAuthConstants.loginPathMarker)}[^"\'\\s<>]+)',
);

/// 表单隐藏域里的 `state`。
final _stateFieldPattern = RegExp(
  r'''name=["']state["'][^>]*value=["']([^"']+)["']''',
);
