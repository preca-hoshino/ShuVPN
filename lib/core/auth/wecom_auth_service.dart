import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/shu_log.dart';
import 'auth_constants.dart';
import 'auth_cookie_store.dart';
import 'client_user_agent.dart';
import 'native_auth_service.dart';

/// 企业微信扫码登录过程中的会话信息。
class ShuWeComQrSession {
  const ShuWeComQrSession({
    required this.key,
    required this.qrImageUrl,
    required this.confirmUrl,
    required this.wxWorkSchemeUrl,
  });

  /// 企微扫码会话标识，用于长轮询与确认页地址。
  final String key;

  /// 二维码图片地址（可直接作为 `Image.network` 的源）。
  final String qrImageUrl;

  /// 扫码后企微内置浏览器打开的确认页地址。
  final String confirmUrl;

  /// 包装后的 scheme 跳转地址（`wxwork://sso/jump?url=...`），
  /// 在外部浏览器/短信中打开可拉起企业微信。
  final String wxWorkSchemeUrl;
}

/// 长轮询扫码状态。
enum ShuWeComScanStatus {
  /// 尚未扫码。
  waiting,

  /// 已扫码，等待手机确认。
  confirmedPending,

  /// 已确认，取得 auth_code。
  succeeded,

  /// 二维码已过期或已取消。
  expired,
}

/// 扫码长轮询结果。
class ShuWeComScanResult {
  const ShuWeComScanResult._({required this.status, this.authCode});

  const ShuWeComScanResult.waiting()
    : this._(status: ShuWeComScanStatus.waiting);

  const ShuWeComScanResult.confirmedPending()
    : this._(status: ShuWeComScanStatus.confirmedPending);

  const ShuWeComScanResult.succeeded(String authCode)
    : this._(status: ShuWeComScanStatus.succeeded, authCode: authCode);

  const ShuWeComScanResult.expired()
    : this._(status: ShuWeComScanStatus.expired);

  final ShuWeComScanStatus status;
  final String? authCode;

  bool get isSuccess => status == ShuWeComScanStatus.succeeded;
}

/// 企业微信扫码的最终结果。
class ShuWeComSessionResult {
  const ShuWeComSessionResult({required this.sessionCookies});

  /// 本次流程收集到的全部 Cookie，必须写入 WebView，
  /// 否则加载 callback 时 SSO 会认为未登录并重定向回登录页。
  final List<({Cookie cookie, String domain, String path})> sessionCookies;
}

/// 企业微信扫码登录服务。
///
/// **阶段一：用企微换 SSO 会话**
/// 1. `GET /wwopen/sso/qrConnect` → HTML 内嵌 `qrImg?key=<key>`；
/// 2. 长轮询 `GET /wwopen/sso/l/qrConnect` → JSONP `jsonpCallback({...})`，
///    状态机 `QRCODE_SCAN_NEVER → QRCODE_SCAN_ING → QRCODE_SCAN_SUCC`；
/// 3. `GET /oauth/wecom/qrcode?code=<auth_code>&state=<params>&appid=...`
///    → 302 + `SHU_OAUTH2` 会话 Cookie。
///
/// 注意 [ShuWeComAuthService.weComRedeemState] 固定使用**教务系统**的参数 ——
/// 企微自建应用只绑定教务系统，`/oauth/wecom/qrcode` 用它校验请求合法性；
/// 换成其他参数会返回 `{"message":"badRequestParams"}`。目标系统的差异在
/// 阶段二（`ShuAuthorizeService`）处理。
class ShuWeComAuthService {
  ShuWeComAuthService({HttpClient? httpClient, ShuCookieStore? cookieStore})
    : _client = httpClient ?? HttpClient(),
      _cookies = cookieStore ?? ShuCookieStore() {
    _client.connectionTimeout = const Duration(seconds: 8);
    _client.userAgent = ClientUserAgent.mobileBrowser;
  }

  final HttpClient _client;
  final ShuCookieStore _cookies;

  static const _normalTimeout = Duration(seconds: 15);
  static const _longPollTimeout = Duration(seconds: 45);

  final List<Cookie> _lastResponseCookies = [];

  /// 最近一次响应下发的 Cookie（诊断用）。
  List<Cookie> get lastResponseCookies =>
      List<Cookie>.unmodifiable(_lastResponseCookies);

  static final _qrImgKeyPattern = RegExp(r'qrImg\?key=([0-9a-fA-F]+)');
  static final _jsonpPattern = RegExp(r'jsonpCallback\((\{.*?\})\)');

  void dispose() => _client.close(force: true);

  /// 把本次流程收集到的 Cookie 交给调用方，用于装入 WebView。
  List<({Cookie cookie, String domain, String path})> get cookieJar =>
      _cookies.entries;

  /// 编码 OAuth 参数为 base64url 无填充字符串。
  ///
  /// 必须使用 base64url 无 `=` 填充，否则企微/SSO 返回 `badRequestParams`。
  static String encodeOAuthParams(Map<String, String> params) {
    final json = jsonEncode(params);
    return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  }

  /// 企微扫码换取 SSO 会话时固定使用的 `state` —— 教务系统参数。
  static String get weComRedeemState =>
      encodeOAuthParams(ShuOAuthTargets.jwxt.toParams());

  /// 发起企微扫码会话，返回二维码与唤起链接。
  Future<ShuWeComQrSession> startQrSession() async {
    final uri = Uri.parse(ShuAuthConstants.weComQrConnectBase).replace(
      queryParameters: {
        'appid': ShuAuthConstants.weComAppId,
        'agentid': ShuAuthConstants.weComAgentId,
        'redirect_uri': ShuAuthConstants.weComRedirectUri,
        'state': weComRedeemState,
        'lang': 'zh',
        'version': '1.2.7',
        'login_type': 'jssdk',
      },
    );
    final response = await _get(uri, host: _RequestHost.weCom);
    final body = await utf8.decodeStream(response).timeout(_normalTimeout);
    final match = _qrImgKeyPattern.firstMatch(body);
    if (match == null) {
      ShuLog.w(ShuLogTag.auth, '企微扫码 · 二维码页未匹配到 qrImg?key · ${body.length} 字符');
      throw const ShuAuthException('qrcodeKeyNotFound', '未能获取企业微信登录二维码，请稍后重试');
    }
    final key = match.group(1)!;
    final confirmUrl =
        '${ShuAuthConstants.weComConfirmBase}?k=$key&notretry=yes';
    return ShuWeComQrSession(
      key: key,
      qrImageUrl: '${ShuAuthConstants.weComQrImgBase}?key=$key',
      confirmUrl: confirmUrl,
      wxWorkSchemeUrl:
          '${ShuAuthConstants.weComSchemeJumpBase}'
          '${Uri.encodeComponent(confirmUrl)}',
    );
  }

  /// 长轮询等待用户扫码确认，直到成功、过期或达到超时时间。
  ///
  /// [onStatusChanged] 会在状态变化时回调（用于界面展示）；
  /// [isCancelled] 返回 true 时提前终止轮询（例如页面被 dispose），
  /// 避免在后台持续发起网络请求。
  Future<ShuWeComScanResult> waitForScan(
    String key, {
    Duration timeout = const Duration(seconds: 180),
    void Function(ShuWeComScanStatus status)? onStatusChanged,
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    ShuLog.i(ShuLogTag.auth, '企微扫码 · 开始长轮询 · 最多 ${timeout.inSeconds} 秒');
    var lastStatus = ShuWeComScanStatus.waiting;
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() ?? false) {
        ShuLog.i(ShuLogTag.auth, '企微扫码 · 页面提前离场 · 停止轮询');
        return const ShuWeComScanResult.expired();
      }
      final result = await _pollOnce(key);
      // 只在状态**发生变化**时记一行：轮询每秒一次，逐次记会把缓冲区填满。
      if (result.status != lastStatus) {
        lastStatus = result.status;
        ShuLog.i(ShuLogTag.auth, '企微扫码 · 状态 ${result.status.name}');
      }
      onStatusChanged?.call(result.status);
      if (result.status == ShuWeComScanStatus.succeeded ||
          result.status == ShuWeComScanStatus.expired) {
        return result;
      }
      await Future<void>.delayed(
        result.status == ShuWeComScanStatus.confirmedPending
            ? const Duration(milliseconds: 500)
            : const Duration(seconds: 1),
      );
    }
    ShuLog.w(ShuLogTag.auth, '企微扫码 · 长轮询超时');
    return const ShuWeComScanResult.expired();
  }

  /// 阶段一：把企微 `auth_code` 换成 SSO 会话。
  ///
  /// [state] 必须为 [weComRedeemState]，且必须携带 `appid`。
  Future<ShuWeComSessionResult> redeem(String authCode, String state) async {
    final uri = Uri.parse('${ShuAuthConstants.ssoBase}/oauth/wecom/qrcode')
        .replace(
          queryParameters: {
            'code': authCode,
            'state': state,
            'appid': ShuAuthConstants.weComAppId,
          },
        );
    final response = await _get(uri, host: _RequestHost.sso);
    final statusCode = response.statusCode;
    final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
    // 失败判定：Location 含 message=wecomAuthFailed，或响应体含
    // badRequestParams（缺 appid / state 非 base64url 时都会命中）。
    if (statusCode < 300 ||
        statusCode >= 400 ||
        location.contains('wecomAuthFailed')) {
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_normalTimeout);
      ShuLog.w(
        ShuLogTag.auth,
        '企微扫码 · auth_code 换会话失败 · HTTP $statusCode · '
        '${text.contains('badRequestParams') ? 'badRequestParams' : 'wecomAuthFailed'}',
      );
      throw ShuAuthException(
        'redeemFailed',
        text.contains('badRequestParams')
            ? '企业微信授权失败，请重新尝试'
            : '企业微信授权失败（HTTP $statusCode）',
      );
    }
    await response.drain<void>();
    ShuLog.i(
      ShuLogTag.auth,
      '企微扫码 · 已换到 SSO 会话 · 收集到 ${_cookies.entries.length} 条 Cookie',
    );
    return ShuWeComSessionResult(sessionCookies: _cookies.entries);
  }

  // ------------------------------------------------------------------ 内部

  /// 单次长轮询请求，返回扫码状态。
  Future<ShuWeComScanResult> _pollOnce(String key) async {
    final uri = Uri.parse(ShuAuthConstants.weComLongPollBase).replace(
      queryParameters: {
        'callback': 'jsonpCallback',
        'key': key,
        'redirect_uri': ShuAuthConstants.weComRedirectUri,
        'appid': ShuAuthConstants.weComAppId,
        '_': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    HttpClientResponse response;
    try {
      response = await _get(
        uri,
        host: _RequestHost.weCom,
        accept:
            'text/javascript, application/javascript, '
            'application/ecmascript, */*; q=0.01',
        extraHeaders: const {'x-requested-with': 'XMLHttpRequest'},
        timeout: _longPollTimeout,
      );
    } on Object {
      // 长轮询单个请求超时（约 40s）不视为失败，继续下一次轮询。
      return const ShuWeComScanResult.waiting();
    }
    final body = await utf8.decodeStream(response).timeout(_longPollTimeout);
    final match = _jsonpPattern.firstMatch(body);
    if (match == null) return const ShuWeComScanResult.waiting();
    try {
      final json = jsonDecode(match.group(1)!) as Map<String, dynamic>;
      return _parseStatus(
        json['status']?.toString() ?? '',
        json['auth_code']?.toString() ?? '',
      );
    } on Object {
      return const ShuWeComScanResult.waiting();
    }
  }

  ShuWeComScanResult _parseStatus(String status, String authCode) {
    switch (status) {
      case 'QRCODE_SCAN_SUCC':
        return authCode.isNotEmpty
            ? ShuWeComScanResult.succeeded(authCode)
            : const ShuWeComScanResult.confirmedPending();
      case 'QRCODE_SCAN_ING':
        return const ShuWeComScanResult.confirmedPending();
      case 'QRCODE_SCAN_ERR':
      case 'QRCODE_SCAN_OVERDUE':
      case 'QRCODE_SCAN_CANCEL':
        return const ShuWeComScanResult.expired();
      default:
        return const ShuWeComScanResult.waiting();
    }
  }

  /// 发起请求并按 [host] 选择请求头。
  ///
  /// 默认头指向 SSO 站点，只有企微扫码相关请求才覆盖成企微域的头，
  /// 否则企微侧可能拒绝。
  Future<HttpClientResponse> _get(
    Uri uri, {
    required _RequestHost host,
    String? accept,
    Map<String, String> extraHeaders = const {},
    Duration timeout = _normalTimeout,
  }) async {
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.headers
      ..set(
        HttpHeaders.acceptHeader,
        accept ?? 'text/html,application/xhtml+xml,*/*;q=0.8',
      )
      ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser);
    switch (host) {
      case _RequestHost.weCom:
        request.headers
          ..set(HttpHeaders.refererHeader, ShuAuthConstants.weComQrConnectBase)
          ..set('Origin', 'https://${ShuAuthConstants.weComHost}');
      case _RequestHost.sso:
        request.headers
          ..set(HttpHeaders.refererHeader, ShuAuthConstants.ssoBase)
          ..set('Origin', ShuAuthConstants.ssoBase);
    }
    for (final entry in extraHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final cookieHeader = _cookies.headerFor(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    final response = await request.close().timeout(timeout);
    // 统一收下所有响应下发的 Set-Cookie，模拟浏览器 Session 行为。
    final cookies = _parseCookies(response);
    _lastResponseCookies
      ..clear()
      ..addAll(cookies);
    _cookies.save(uri, cookies);
    return response;
  }

  /// 宽松解析 `Set-Cookie`。
  ///
  /// `dart:io` 的 [HttpClientResponse.cookies] 会对每条 Set-Cookie 做严格校验，
  /// 遇到企微扫码域下发的非法值（例如含逗号）会**整体**抛出
  /// [FormatException]。这里逐条解析，跳过不符合 RFC 6265 的条目 ——
  /// 这些 Cookie 只属于企微扫码域，本流程并不需要它们。
  static List<Cookie> _parseCookies(HttpClientResponse response) {
    final cookies = <Cookie>[];
    final values = response.headers[HttpHeaders.setCookieHeader];
    if (values == null) return cookies;
    for (final value in values) {
      try {
        cookies.add(Cookie.fromSetCookieValue(value));
      } on FormatException {
        // 跳过非法条目。
      }
    }
    return cookies;
  }
}

/// 请求所属站点，决定 Referer/Origin。
enum _RequestHost { weCom, sso }
