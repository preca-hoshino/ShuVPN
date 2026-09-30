import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../logging/shu_log.dart';
import 'auth_constants.dart';
import 'auth_cookie_store.dart';
import 'native_auth_service.dart';

/// aTrust 侧换来的会话。
class ShuATrustSession {
  const ShuATrustSession({
    required this.username,
    required this.sid,
    required this.loginDomain,
    required this.ticket,
  });

  /// 网关 `onlineInfo` 返回的账号名。
  final String username;

  /// 会话 Cookie 的值 —— 之后建立隧道就靠它。
  final String sid;

  /// 网关下发的登录域（`sfDomain`）。
  final String loginDomain;

  /// 上报过的登录票据。
  final String ticket;
}

/// 上海大学 aTrust 统一身份认证（OAuth2）登录链路。
///
/// 实现对齐 `zju-connect` 的 `client/atrust/auth/*`。整条链路的关键在于
/// **`code` 不发给 newsso，而是交给 aTrust**：
///
/// ```
/// GET https://atrust.shu.edu.cn/passport/v1/auth/httpsOauth2
///       ?sfDomain=customOAuth76881&code=<CODE>&state=null
///  → 302 https://atrust.shu.edu.cn/portal/shortcut.html?data={"ticket":"..."}
/// ```
///
/// aTrust 自己在服务端拿这个 code 去 newsso 核销，再把 `ticket` 放在 302 的
/// `Location` 里。接着上报票据（`reportEnv`）、走完后续认证链
/// （`authCheck`）、读一次 `onlineInfo`，`sid` 才会落进 Cookie。
///
/// 之前这里把 newsso 302 回来的 `.../httpsOauth2?code=XXX` 直接当成回调地址
/// 去跟随（**少了 `sfDomain`**），aTrust 认不出是哪个登录域，于是既拿不到
/// ticket 也拿不到 `sid` —— 这就是 aTrust 凭据一直交换失败的根因。
class ShuATrustAuthChain {
  ShuATrustAuthChain({
    required ShuCookieStore cookieStore,
    required String deviceId,
    required HttpClient httpClient,
  }) : _cookies = cookieStore,
       // ignore: prefer_initializing_formals
       _deviceId = deviceId,
       _client = httpClient;

  final ShuCookieStore _cookies;
  final HttpClient _client;

  /// 当前登录使用的设备号。由 [signIn] 指定，保证与隧道用的是同一个。
  String _deviceId;

  /// 本次登录使用的 `sfDomain`。
  ///
  /// 以网关在 `authConfig` 里下发的为准，拿不到时才退回本地登记值 ——
  /// 建隧道时 `ATrustConnector` 也要求传它，两边必须是同一个。
  String _loginDomain = ShuAuthConstants.atrustLoginDomain;

  /// 当前生效的 `sfDomain`。
  String get loginDomain => _loginDomain;

  static const _host = ShuAuthConstants.atrustHost;
  static final Uri _base = Uri.parse('https://$_host');
  static final Uri _baseUrl = Uri.parse('https://$_host/');

  /// 网关按 UA 判定客户端类型，必须伪装成桌面客户端。
  static const _userAgent = ShuAuthConstants.atrustUserAgent;

  /// 每个端点都要带的公共查询串。网关会校验 `platform`，传错直接 422。
  static const _sharedQuery = <String, String>{
    'clientType': 'SDPClient',
    'platform': 'Linux',
    'lang': 'en-US',
  };

  static const _timeout = Duration(seconds: 15);

  /// `x-sdp-rid`：服务端地址的 base64。所有请求都带同一个值。
  static final String _rid = base64Encode(utf8.encode(_base.authority));

  /// 网关下发的会话 Cookie。
  ///
  /// **这些必须原样带回去**：`reportEnv` 之所以回 403，就是因为在那之前
  /// 一张 Cookie 都没被保存过（我此前把 `dart:io` 按域名解析的 Set-Cookie
  /// 当成唯一来源，而这些响应正是只靠 `Set-Cookie` 下发状态的）。
  /// 这里按「收到即保存」处理，不再依赖解析器能否认出域名。
  final Map<String, String> _jar = <String, String>{};

  /// 当前持有的网关 Cookie（`name → value`）。
  ///
  /// 交给协议核心时要用它 —— 只有原样带上这些，网关才会认出
  /// `isLogin == 1`。
  Map<String, String> get cookieJar => Map<String, String>.unmodifiable(_jar);

  /// 当前是否已建立网关会话。
  bool get isLoggedIn => _isLoggedIn;

  /// 走完一遍 OAuth2 登录，返回 aTrust 的会话。
  ///
  /// [deviceId] 必须与之后建隧道时用的那个一致 —— `reportEnv` 上报的设备
  /// 和隧道握手的设备不同的话，网关会把一次会话与一台设备判成两台机器。
  Future<ShuATrustSession> signIn(
    ShuOAuthTarget target, {
    required String deviceId,
  }) async {
    _deviceId = deviceId;
    ShuLog.i(ShuLogTag.atrust, 'aTrust 认证链开始 · deviceId ${mask(deviceId)}');
    final config = await _fetchAuthConfig();
    final method = config.method;
    ShuLog.d(
      ShuLogTag.atrust,
      'authConfig: isLogin=${config.isLoggedIn ? 1 : 0} '
      'authType=${method.authType}',
    );

    // `sfDomain` 由网关下发，硬编码会在网关换域时静默失败。
    final loginDomain = method.loginDomain.isNotEmpty
        ? method.loginDomain
        : ShuAuthConstants.atrustLoginDomain;
    _loginDomain = loginDomain;
    ShuLog.d(ShuLogTag.atrust, '登录域 sfDomain = $loginDomain');

    var ticket = '';
    if (!config.isLoggedIn) {
      // ① 向 newsso 要授权码。② code → ticket 由 aTrust 服务端代劳。
      final code = await _authorizationCode(target, method);
      ShuLog.d(ShuLogTag.atrust, '已取得授权码 · ${code.length} 字符');
      ticket = await _redeemTicket(
        code: code,
        sfDomain: loginDomain,
        csrfToken: config.csrfToken,
      );
      ShuLog.d(ShuLogTag.atrust, '已换取票据 · ${ticket.length} 字符');
      // ③ 用 `mod=1` 刷新一次配置 —— 这正是 zju-connect 在 httpsOauth2
      //    之后做的那一步（`authConfig(true, false)`）。少了它会 403：
      //    网关此时还没把这个 ticket 与客户端会话绑定起来。
      await _authConfigAfterLogin();
      ShuLog.d(ShuLogTag.atrust, 'authConfig mod=1 完成 · csrf 已刷新');
      // ④ 上报票据。
      await _reportEnvironment(ticket: ticket, csrfToken: _csrfToken);
      ShuLog.d(ShuLogTag.atrust, 'reportEnv 完成');

      // ⑤ 后续认证链。**只能在这个窗口里跑** —— 它是登录握手的一部分，
      //    网关只接受「刚上报完票据」的那一次 `authCheck`。
      await _runAuthChain(csrfToken: _csrfToken);
      ShuLog.d(ShuLogTag.atrust, 'authCheck 链完成');
    } else {
      ShuLog.d(ShuLogTag.atrust, '网关报告已登录 isLogin=1 · 跳过整段握手');
    }

    // ⑥ 账号名；`sid` 也在这之后才在 Cookie 里。
    //
    // 注意这里**不能**再无条件跑认证链：会话已经是活的（`isLogin == 1`）时
    // 网关会直接拒绝 `authCheck`，原话是
    // 「The current account is already logged in. Please refresh and try again」。
    // 这正是「账号层登录过一遍、连接层又 signIn 一次」时会踩的坑 ——
    // 参考实现同样只在 `isLogin != 1` 的分支里调 `continueAuth`，
    // 已登录时直接 `onlineInfo()` 收尾。
    final username = await _onlineInfo(csrfToken: _csrfToken);
    ShuLog.d(ShuLogTag.atrust, 'onlineInfo 完成 · 账号名 ${mask(username)}');

    final sid =
        _cookies.valueFor(_host, 'sid') ??
        _cookie('sid') ??
        _cookies.valueFor(_host, 'sid-legacy') ??
        _cookie('sid-legacy');
    if (sid == null || sid.isEmpty) {
      ShuLog.e(ShuLogTag.atrust, 'aTrust 未下发会话凭证（sid）');
      throw const ShuAuthException('atrustNoSid', 'aTrust 未下发会话凭证（sid）');
    }
    ShuLog.i(ShuLogTag.atrust, 'aTrust 会话已就绪 · sid ${mask(sid)}');
    return ShuATrustSession(
      username: username,
      sid: sid,
      loginDomain: loginDomain,
      ticket: ticket,
    );
  }

  /// 当前生效的 csrf token（每次配置响应都会刷新它）。
  String _csrfToken = '';

  /// `authConfig` 是否处于「已登录」状态，用于尽早发现会话失效。
  bool _isLoggedIn = false;

  String? _cookie(String name) {
    final value = _jar[name];
    return value == null || value.isEmpty ? null : value;
  }

  // --------------------------------------------------------------- ① 取配置

  /// `GET /passport/v1/public/authConfig`。
  ///
  /// 三个参数的组合与 zju-connect 的 `authConfig(mod, needTicket)` 一一对应：
  /// - 首次探测：`mod=false, needTicket=true`
  /// - 换票之后：`mod=true`（这一步会顺带刷新 csrf token）
  Future<_ATrustConfig> _fetchAuthConfig({
    bool mod = false,
    bool needTicket = true,
  }) async {
    final uri = _base.replace(
      path: '/passport/v1/public/authConfig',
      queryParameters: {
        ..._sharedQuery,
        if (mod) 'mod': '1',
        'needTicket': needTicket ? '1' : '0',
      },
    );
    final json = await _json('GET', uri, csrfToken: _csrfToken);
    final data = _map(json['data']);
    final security = _map(data['security']);
    final csrfToken =
        _string(data['csrfToken']) ?? _string(security['csrfToken']) ?? '';
    if (csrfToken.isNotEmpty) _csrfToken = csrfToken;
    if (csrfToken.isEmpty && _csrfToken.isEmpty) {
      throw const ShuAuthException('atrustNoCsrf', 'aTrust 未下发会话令牌（csrfToken）');
    }
    final isLogin = _int(data['isLogin']) == 1;
    _isLoggedIn = isLogin;
    final methods = <_ATrustAuthMethod>[
      for (final item in _list(data['authServerInfoList']))
        _ATrustAuthMethod.fromMap(_map(item)),
    ];
    return _ATrustConfig(
      isLoggedIn: isLogin,
      methods: methods,
      csrfToken: _csrfToken,
    );
  }

  // ------------------------------------------------------------- ② 要授权码

  /// 换到票据之后重新取一次配置（`mod=1`）。
  ///
  /// 实测这一步是 `reportEnv` 能成功的前置条件：它让网关把上一步拿到的
  /// ticket 与客户端会话关联起来，并顺带下发新的 csrf token 与 Cookie。
  ///
  /// 它是**硬前置**：失败就必须中止，不能退回去继续上报票据 ——
  /// 那样网关只会回一个 403。
  Future<void> _authConfigAfterLogin() async {
    await _fetchAuthConfig(mod: true, needTicket: false);
  }

  /// 要授权码。
  ///
  /// 两处必须做对，否则 newsso 只会丢回登录页、不给 `code`：
  ///
  /// 1. **请求头里必须带 `SHU_OAUTH2`**。这张 Cookie 属于 newsso，
  ///    不归 aTrust 的 jar 管 —— 只发自己的 jar 就是在匿名请求。
  /// 2. **走线上登记的 `redirectUri`**，不要用 `loginUrl`。那个地址只是给
  ///    浏览器「点开登录页」用的，它带的 `state` 是网关的会话状态，
  ///    换不到我们会消费的 `code`；`/oauth/authorize` + 我们的
  ///    `client_id`/`redirect_uri` 才是注册过的那条路。
  ///
  /// `loginUrl` 只用来解析「用哪个登录域」，不再直接请求。
  Future<String> _authorizationCode(
    ShuOAuthTarget target,
    _ATrustAuthMethod method,
  ) async {
    final fromGateway = await _tryCodeFromLoginUrl(method.loginUrl);
    if (fromGateway != null) return fromGateway;
    return _codeFromAuthorizer(target);
  }

  /// 按网关下发的 `loginUrl` 取一次 `code`。
  ///
  /// 取不到就返回 `null`，交给 [_shuAuthorize] 走标准路径 ——
  /// 有些网关的 `loginUrl` 已经带上了完整的授权参数，能一步到位；
  /// 但更多时候它只是登录页地址，这时候不该在这里硬失败。
  Future<String?> _tryCodeFromLoginUrl(String loginUrl) async {
    if (loginUrl.isEmpty) return null;
    final uri = Uri.tryParse(loginUrl);
    if (uri == null || uri.host.isEmpty) return null;
    try {
      final response = await _send('GET', uri, followRedirects: false);
      final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
      final status = response.statusCode;
      await response.drain<void>();
      if (status < 300 || status >= 400) return null;
      final code = _codeFromLocation(location);
      return code.isEmpty ? null : code;
    } on Object {
      return null;
    }
  }

  /// 本地登记参数拼出的授权地址。`loginUrl` 缺失时才会走到。
  Future<String> _codeFromAuthorizer(ShuOAuthTarget target) async {
    final callbackUri = await _shuAuthorize(target);
    final code = callbackUri.queryParameters['code'] ?? '';
    if (code.isEmpty) {
      throw const ShuAuthException('authorizeFailed', '统一认证未返回 aTrust 的授权码');
    }
    return code;
  }

  /// 本地拼授权地址并**只请求一次**。
  ///
  /// 不走 `ShuAuthorizeService.authorize`：那个方法自己处理 `state` 预热，
  /// 而 aTrust 的注册信息里没有 `needsStateBootstrap`，这里的差异只在
  /// 「请求头要不要并上 aTrust 的 Cookie」，所以直接请求更清楚。
  Future<Uri> _shuAuthorize(ShuOAuthTarget target) async {
    // newsso 用 `SHU_OAUTH2` 判断「这个浏览器登录过没有」。这张 Cookie 在
    // 共享容器里（账号层登录时写入），必须随请求发出去。
    final uri = Uri.parse(ShuAuthConstants.ssoBase).replace(
      path: ShuAuthConstants.authorizePath,
      queryParameters: {
        'response_type': 'code',
        'client_id': target.clientId,
        'redirect_uri': target.redirectUri,
        if (target.scope.isNotEmpty) 'scope': target.scope,
      },
    );
    final response = await _send('GET', uri, followRedirects: false);
    final status = response.statusCode;
    final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
    await response.drain<void>();

    if (status < 300 || status >= 400 || location.isEmpty) {
      throw ShuAuthException(
        'authorizeFailed',
        '统一认证未返回 aTrust 的授权地址（HTTP $status）',
      );
    }
    // 被弹回登录页 = `SHU_OAUTH2` 没有生效。说清楚是哪一步，
    // 比笼统的「没返回授权码」有用得多。
    if (location.contains(ShuAuthConstants.loginPathMarker)) {
      throw const ShuAuthException(
        'sessionNotReused',
        '统一身份认证会话未能复用，请重新登录校园账户',
      );
    }
    final code = _codeFromLocation(location);
    if (code.isEmpty) {
      throw const ShuAuthException('authorizeFailed', '统一认证未返回 aTrust 的授权码');
    }
    // 授权码是一次性的，直接交回去，不再解析成 Uri 走一遍。
    return uri.resolve(location);
  }

  // ------------------------------------------------------ ② code → ticket

  Future<String> _redeemTicket({
    required String code,
    required String sfDomain,
    required String csrfToken,
  }) async {
    final uri = _base.replace(
      path: ShuAuthConstants.atrustCallbackPath,
      // `state=null` 是字面量字符串，aTrust 端就是这么收的。
      queryParameters: {'sfDomain': sfDomain, 'code': code, 'state': 'null'},
    );
    // 票据就在 302 的 Location 里，绝不能跟随跳转。
    final response = await _send(
      'GET',
      uri,
      followRedirects: false,
      csrfToken: csrfToken,
    );
    final status = response.statusCode;
    final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
    await response.drain<void>();

    if (status < 300 || status >= 400 || location.isEmpty) {
      throw ShuAuthException(
        'atrustTicketFailed',
        'aTrust 未返回登录票据（HTTP $status）${_errInfoMessage(location)}',
      );
    }
    // Location 必须落在本网关的 `/portal/shortcut.html` 上。
    if (!location.contains('//$_host${ShuAuthConstants.atrustShortcutPath}')) {
      throw const ShuAuthException('atrustTicketFailed', 'aTrust 返回了未预期的跳转地址');
    }
    final ticket = _ticketFromLocation(location);
    if (ticket == null || ticket.isEmpty) {
      throw const ShuAuthException(
        'atrustTicketFailed',
        'aTrust 未下发登录票据（ticket）',
      );
    }
    return ticket;
  }

  // -------------------------------------------------------- ③ 上报票据

  Future<void> _reportEnvironment({
    required String ticket,
    required String csrfToken,
  }) async {
    if (ticket.isEmpty) {
      throw const ShuAuthException('atrustTicketFailed', 'aTrust 登录票据为空');
    }
    final uri = _base.replace(
      path: '/controller/v1/public/reportEnv',
      queryParameters: _sharedQuery,
    );
    await _json(
      'POST',
      uri,
      csrfToken: csrfToken,
      body: <String, Object?>{
        'ticket': ticket,
        'deviceId': _deviceId,
        'env': <String, Object?>{
          'endpoint': <String, Object?>{
            'device_id': _deviceId,
            'device': <String, String>{'type': 'browser'},
          },
        },
      },
      operation: '上报登录票据',
    );
  }

  // ------------------------------------------------------ ④ 后续认证链

  /// 后续认证链，最多 8 步（与协议核心同上限）。
  ///
  /// 与 `zju-connect` 的 `continueAuth` 同构：当前 `service` 决定调哪个
  /// 接口，该接口响应体里的 `data.nextService` 给出下一步；空字符串即收敛。
  /// 入口固定是 `authCheck` —— 这个流程里 `nextService` 由登录响应体
  /// （`/passport/v1/auth/psw`）下发，OAuth2 这条路没有那一步。
  Future<void> _runAuthChain({required String csrfToken}) async {
    var step = const _ATrustAuthStep(service: 'auth/authCheck');
    for (var count = 0; count < 8; count++) {
      final next = switch (step.service) {
        'auth/authCheck' => await _authCheck(csrfToken: csrfToken),
        'auth/accessCheck' => await _callStep(
          '/passport/v1/auth/accessCheck',
          csrfToken: csrfToken,
          operation: '环境检查',
        ),
        'auth/preEnhancedAuth' ||
        'auth/enhancedConfirm' ||
        'auth/enhancedDone' => await _callStep(
          '/passport/v1/${step.service}',
          csrfToken: csrfToken,
          operation: step.service,
          query: {if (step.authId != null) 'authId': step.authId!},
        ),
        'auth/bindAuthDevice' => await _callStep(
          '/passport/v1/auth/bindAuthDevice',
          csrfToken: csrfToken,
          operation: '绑定设备',
          query: {
            'deviceId': _deviceId,
            if (step.authId != null) 'authId': step.authId!,
          },
        ),
        _ =>
          // 短信 / TOTP / 图形验证码这些要用户介入。统一身份认证那边已经做过
          // 二次验证，正常不会走到这里；真走到了就说清楚，别弹一个我们接不住的框。
          throw ShuAuthException(
            'atrustChallenge',
            'aTrust 要求额外验证（${step.service}），请稍后重试',
          ),
      };
      if (next.service.isEmpty) return;
      step = next;
    }
    throw const ShuAuthException('atrustAuthChain', 'aTrust 认证步骤过多，已中止');
  }

  Future<_ATrustAuthStep> _authCheck({required String csrfToken}) async {
    final json = await _json(
      'GET',
      _base.replace(
        path: '/passport/v1/auth/authCheck',
        queryParameters: _sharedQuery,
      ),
      csrfToken: csrfToken,
      operation: '认证检查',
    );
    return _ATrustAuthStep.fromMap(_map(json['data']));
  }

  /// 调一个不返回内容的认证步骤，下一步仍以响应体里的 `data` 为准。
  Future<_ATrustAuthStep> _callStep(
    String path, {
    required String csrfToken,
    required String operation,
    Map<String, String> query = const {},
  }) async {
    final json = await _json(
      'GET',
      _base.replace(path: path, queryParameters: {..._sharedQuery, ...query}),
      csrfToken: csrfToken,
      operation: operation,
    );
    return _ATrustAuthStep.fromMap(_map(json['data']));
  }

  Future<String> _onlineInfo({required String csrfToken}) async {
    final json = await _json(
      'GET',
      _base.replace(
        path: '/passport/v1/user/onlineInfo',
        queryParameters: _sharedQuery,
      ),
      csrfToken: csrfToken,
      operation: '读取账号信息',
    );
    return _string(_map(json['data'])['username']) ?? '';
  }

  // ------------------------------------------------------------------ 网络

  /// 发一次请求。返回的响应体由调用方负责读掉，否则连接会泄漏。
  Future<HttpClientResponse> _send(
    String method,
    Uri uri, {
    bool followRedirects = true,
    String? csrfToken,
    Object? body,
  }) async {
    final request = await _client.openUrl(method, uri);
    request.followRedirects = followRedirects;
    request.maxRedirects = 8;
    request.headers
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..set('x-sdp-rid', _rid);
    // 参考实现只在 GET 上声明 Accept；POST 只给 Content-Type。
    if (body == null) {
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    }
    final cookieHeader = _mergedCookieHeader(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    if (csrfToken != null && csrfToken.isNotEmpty) {
      request.headers.set('x-csrf-token', csrfToken);
    }
    // `x-sdp-traceid` 是每次请求自己的跟踪号，放在最后设，保证不被覆盖。
    request.headers.set('x-sdp-traceid', _traceId());
    // 请求头必须在写 body **之前**全部设完。
    //
    // `dart:io` 一旦开始写请求体就会冻结请求头（`_HttpClientRequest`
    // 的 `_writeHeader()` 里调 `_HttpHeaders._finalize()`），此后再 `set`
    // 会抛 `HttpException: HTTP headers are not mutable`。所以
    // `content-type` 与 `write` 只能摆在所有 `set` 之后。
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(_timeout);
    _absorb(response);
    return response;
  }

  /// 把响应里的状态全部收下：以 `Set-Cookie` 为准的会话 Cookie。
  void _absorb(HttpClientResponse response) {
    // 这张表才是权威来源。`dart:io` 的 `response.cookies` 只会认它解析得出
    // 域名的那部分，而 aTrust 大量状态只靠 Set-Cookie 下发。
    final absorbed = <Cookie>[];
    for (final value
        in response.headers[HttpHeaders.setCookieHeader] ?? const <String>[]) {
      final pair = value.split(';').first;
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final name = pair.substring(0, separator).trim();
      final cookieValue = pair.substring(separator + 1).trim();
      if (name.isEmpty || cookieValue.isEmpty) continue;
      _jar[name] = cookieValue;
      absorbed.add(
        Cookie(name, cookieValue)
          ..domain = _host
          ..path = '/',
      );
    }
    // 同时以明确域名写进共享容器：连接层就是靠 `valueFor(host, 'sid')`
    // 把会话交给隧道的，不能指望 `dart:io` 能推出域名。
    if (absorbed.isNotEmpty) _cookies.save(_baseUrl, absorbed);
  }

  /// 适用于 [uri] 的请求头 Cookie：**共享容器与 aTrust jar 合并**。
  ///
  /// 两边缺一不可 ——
  /// - aTrust 的端点在 `atrust.shu.edu.cn` 上，要的是 jar 里的网关会话；
  /// - 向 newsso 换授权码时要的是共享容器里的 `SHU_OAUTH2`。
  ///
  /// 之前只发 jar，去 newsso 就是一次匿名请求，只能被弹回登录页。
  /// 同名时以 jar 为准（容器里可能还留着别的站点的同名 Cookie）。
  String _mergedCookieHeader(Uri uri) => <String, String>{
    ..._cookies.cookiesFor(uri),
    ..._jar,
  }.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');

  Future<Map<String, Object?>> _json(
    String method,
    Uri uri, {
    bool followRedirects = true,
    String? csrfToken,
    Object? body,
    String? operation,
  }) async {
    final response = await _send(
      method,
      uri,
      followRedirects: followRedirects,
      csrfToken: csrfToken,
      body: body,
    );
    final status = response.statusCode;
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_timeout);
    if (status < 200 || status >= 300) {
      throw ShuAuthException(
        'atrustHttp$status',
        '${operation ?? 'aTrust 认证'}失败（HTTP $status）',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on Object {
      throw const ShuAuthException(
        'atrustBadResponse',
        'aTrust 认证服务返回了无法识别的内容',
      );
    }
    if (decoded is! Map) {
      throw const ShuAuthException(
        'atrustBadResponse',
        'aTrust 认证服务返回了无法识别的内容',
      );
    }
    final json = Map<String, Object?>.from(decoded);
    if (_int(json['code']) != 0) {
      throw ShuAuthException(
        'atrustApiFailed',
        '${operation ?? 'aTrust 认证'}失败：'
            '${_string(json['message']) ?? '网关拒绝了这个请求'}',
      );
    }
    return json;
  }

  // ------------------------------------------------------------------ 工具

  static String _traceId() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  /// 从 302 的 `Location` 里取 `code`（授权码是一次性的，只能用在这里）。
  static String _codeFromLocation(String location) {
    if (location.isEmpty) return '';
    final index = location.indexOf('?');
    if (index < 0) return '';
    try {
      return Uri.splitQueryString(location.substring(index + 1))['code'] ?? '';
    } on FormatException {
      return '';
    }
  }

  /// 从 `/portal/shortcut.html?data={"ticket":"..."}` 里解出票据。
  static String? _ticketFromLocation(String location) {
    final index = location.indexOf('?');
    if (index < 0) return null;
    try {
      final data = Uri.splitQueryString(location.substring(index + 1))['data'];
      if (data == null || data.isEmpty) return null;
      final decoded = jsonDecode(data);
      if (decoded is! Map) return null;
      final ticket = decoded['ticket'];
      return ticket is String ? ticket : null;
    } on Object {
      return null;
    }
  }

  /// aTrust 失败时会在 `Location` 里带 `err_info`（JSON），解出来当原因。
  static String _errInfoMessage(String location) {
    final index = location.indexOf('?');
    if (index < 0) return '';
    try {
      final raw = Uri.splitQueryString(
        location.substring(index + 1),
      )['err_info'];
      if (raw == null || raw.isEmpty) return '';
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return '';
      final message = decoded['errorMessage']?.toString() ?? '';
      return message.isEmpty ? '' : '：$message';
    } on Object {
      return '';
    }
  }

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  static List<Object?> _list(Object? value) =>
      value is List ? value : const <Object?>[];

  static String? _string(Object? value) => value is String ? value : null;

  static int _int(Object? value) =>
      value is int ? value : int.tryParse('$value') ?? 0;
}

/// `authConfig` 里的一项认证方式。
class _ATrustAuthMethod {
  const _ATrustAuthMethod({
    required this.authType,
    required this.loginDomain,
    this.loginUrl = '',
  });

  factory _ATrustAuthMethod.fromMap(Map<String, Object?> map) =>
      _ATrustAuthMethod(
        authType: map['authType'] as String? ?? '',
        loginDomain: map['loginDomain'] as String? ?? '',
        loginUrl: map['loginUrl'] as String? ?? '',
      );

  final String authType;
  final String loginDomain;
  final String loginUrl;
}

/// `GET /passport/v1/public/authConfig` 关心的那几个字段。
class _ATrustConfig {
  const _ATrustConfig({
    required this.isLoggedIn,
    required this.methods,
    required this.csrfToken,
  });

  final bool isLoggedIn;
  final List<_ATrustAuthMethod> methods;
  final String csrfToken;

  /// 统一身份认证那一项（上大的网关只提供这一种）。
  _ATrustAuthMethod get method => methods.firstWhere(
    (item) => item.authType == 'auth/httpsOauth2',
    orElse: () => const _ATrustAuthMethod(authType: '', loginDomain: ''),
  );
}

/// `authCheck` 返回的下一步。
class _ATrustAuthStep {
  const _ATrustAuthStep({required this.service, this.authId});

  factory _ATrustAuthStep.fromMap(Map<String, Object?> map) {
    final rawService = map['nextService'] as String?;
    final services = (map['nextServiceList'] as List<Object?>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, Object?>.from(item))
        .toList(growable: false);
    final selected = services.cast<Map<String, Object?>?>().firstWhere(
      (item) => item?['authType'] == rawService,
      orElse: () => services.isEmpty ? null : services.first,
    );
    var service = rawService ?? selected?['authType'] as String?;
    // 协议核心也做了这个归一化。
    if (service == 'auth/sendSms') service = 'auth/sms';
    if ((service == null || service.isEmpty) && selected?['authId'] != null) {
      service = 'auth/sms';
    }
    return _ATrustAuthStep(
      service: service ?? '',
      authId: selected?['authId'] as String?,
    );
  }

  final String service;
  final String? authId;

  bool get isDone => service.isEmpty;
}
