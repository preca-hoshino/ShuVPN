import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/shu_log.dart';
import 'auth_constants.dart';
import 'auth_cookie_store.dart';
import 'client_user_agent.dart';
import 'native_auth_service.dart';

/// 从动态口令页面解出来的内容。
class ShuOtpPage {
  const ShuOtpPage({
    required this.code,
    required this.account,
    required this.remaining,
    this.period = defaultPeriod,
  });

  /// 口令轮换周期（秒）。页面里 `const totalSeconds = 30;` 给出。
  static const defaultPeriod = 30;

  /// 口令长度。
  static const codeLength = 6;

  final String code;
  final String account;
  final Duration remaining;
  final int period;

  /// 口令失效时刻（本地时钟）。
  DateTime get expiresAt => DateTime.now().add(remaining);
}

/// 动态口令（OTP 令牌）服务。
///
/// 站点是 ASP.NET WebForms 单页（`https://otp.shu.edu.cn`）：
///
/// - 未登录：`GET /` 返回登录引导，口令节点不存在；
/// - 已登录：`GET /` 直接返回整页 HTML，口令由服务端渲染进 `<span>`。
///
/// 页面里的三处数据（均已实测核对）：
///
/// | 数据 | 位置 | 例 |
/// | :--- | :--- | :--- |
/// | 口令 | `id="DataList1_LabelNum_0"` 的文本 | `956370` |
/// | 账户名 | `id="DataList1_LabelAccount_0"` 的文本 | `25123456` |
/// | 剩余秒数 | `Refresh` 响应头 **或** `let remainingSeconds = N;` | `14` |
///
/// `Refresh` 头与页面内联脚本实测始终一致，本实现优先取响应头。
///
/// **不做本地 TOTP 推算**：口令只从页面读，避免与服务端时钟漂移。
/// 逻辑对齐 `shu-otp-poc/sso/otp.py`。
///
/// ## 这一层为什么写得比「发一个 GET」复杂
///
/// 取口令是一件**在 30 秒窗口里必须成功**的事，而它同时是最容易无声失败
/// 的一步 —— 页面上没有口令节点时解析只会返回 `null`，看起来和「会话失效」
/// 一模一样。所以这里做了四件事：
///
/// 1. **手动逐跳跟随 302**（`followRedirects = false`）。`dart:io` 的自动跟随
///    不维护 cookie jar，中间跳的 `Set-Cookie` 会被丢掉；而 OTP 的
///    `ASP.NET_SessionId` 恰好是在回调那一跳下发的。同一问题在教务系统
///    链路上已经踩过一次（见 `ShuAuthorizeService._follow`）。被踢回统一
///    认证登录页时**立刻判为会话失效**，而不是跟着跳到登录页之后返回一个
///    解不出东西的 200。
/// 2. **容忍非 UTF-8 字节**。`utf8.decoder` 遇到非法字节会**抛异常**
///    （不是返回乱码），一次取码会因此整条失败。改用 `allowMalformed: true`，
///    坏字节变成替换字符而不是异常。
/// 3. **两个候选地址**。`/` 与 `/Default.aspx` 都试一遍 —— IIS 的默认文档
///    通常会把 `/` 落到 `Default.aspx`，但站点重写过默认文档时就未必。
/// 4. **有限重试**。只对网络类失败重试（连接被拒、超时、5xx）；
///    「会话失效」「解不出口令」是结论，重试只会拿到同一个结论。
class ShuOtpService {
  ShuOtpService({required ShuCookieStore cookieStore, HttpClient? httpClient})
    : _cookies = cookieStore,
      _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 8);
    _client.userAgent = ClientUserAgent.mobileBrowser;
  }

  static const base = 'https://otp.shu.edu.cn';
  static final _homeUri = Uri.parse('$base/');

  /// 显式地址。`/` 通常等价，但站点重写过默认文档时只有它一定对。
  static final _defaultUri = Uri.parse('$base/Default.aspx');

  static const _timeout = Duration(seconds: 15);

  /// 逐跳跟随的上限。这条链正常只有一跳（登录页）或零跳。
  static const _maxRedirects = 5;

  /// 网络类失败的重试次数。
  static const _maxAttempts = 3;

  static const _networkErrorCode = 'otpNetwork';

  final ShuCookieStore _cookies;
  final HttpClient _client;

  void dispose() => _client.close(force: true);

  /// 取一次当前口令。
  ///
  /// 网络类失败会重试；「会话失效 / 解不出口令」直接抛出（重试没有意义）。
  Future<ShuOtpPage> fetch() async {
    ShuAuthException? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        return await _fetchOnce();
      } on ShuAuthException catch (error) {
        lastError = error;
        if (error.code != _networkErrorCode) rethrow;
      } on Object catch (error) {
        lastError = ShuAuthException(_networkErrorCode, '动态口令请求失败：$error');
      }
      if (attempt < _maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }
    throw lastError ?? const ShuAuthException(_networkErrorCode, '动态口令请求失败');
  }

  Future<ShuOtpPage> _fetchOnce() async {
    for (final uri in [_defaultUri, _homeUri]) {
      final hop = await _get(uri);
      if (hop.isLoginRedirect) {
        throw const ShuAuthException('otpSessionExpired', '动态口令会话已失效，请重新登录');
      }
      if (hop.status != 200) {
        if (hop.status >= 500) {
          throw ShuAuthException(
            _networkErrorCode,
            '动态口令服务返回 HTTP ${hop.status}',
          );
        }
        continue;
      }
      final parsed = parseOtpPage(hop.body);
      if (parsed == null) {
        // 没有口令节点时**打出实际看到的东西**：区分「会话真的没了」与
        // 「页面结构变了」，否则永远只能看到一句「交换失败」。
        ShuLog.w(
          ShuLogTag.otp,
          'OTP 页面未解出口令 · ${uri.path} · HTTP ${hop.status} · '
          '${hop.body.length} 字符 · 开头 ${_snippet(hop.body)}',
        );
        continue;
      }
      // `Refresh` 头优先；缺失或不可解析时退回页面脚本给出的值。
      final remaining =
          parseRefreshSeconds(hop.refresh) ?? parsed.remaining.inSeconds;
      return ShuOtpPage(
        code: parsed.code,
        account: parsed.account,
        remaining: Duration(seconds: remaining),
        period: parsed.period,
      );
    }
    throw const ShuAuthException('otpParseFailed', '页面里没有找到口令节点（会话可能已失效）');
  }

  /// 取一个页面，**手动逐跳**跟随 302，每跳都把 `Set-Cookie` 收进容器。
  Future<_OtpHop> _get(Uri start) async {
    var current = start;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      // 口令只有 30 秒寿命，任何一层缓存（系统代理、VPN 客户端的 HTTP 缓存）
      // 都可能把上一个窗口的码还回来 —— 那个码解析得出来、看起来完全正常，
      // 但已经死了。加个一次性查询串把它挡掉。
      final request = await _client.getUrl(_noCache(current));
      request.followRedirects = false;
      request.headers
        ..set(
          HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,*/*;q=0.8',
        )
        ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser)
        ..set(HttpHeaders.cacheControlHeader, 'no-cache')
        ..set('Pragma', 'no-cache');
      final cookieHeader = _cookies.headerFor(current);
      if (cookieHeader.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      final response = await request.close().timeout(_timeout);
      // 关键一步：这一跳下发的 Cookie 要在**发出下一跳之前**进容器。
      try {
        _cookies.save(current, response.cookies);
      } on Object {
        // 畸形的 Set-Cookie 不该让取码失败。
      }

      final status = response.statusCode;
      final location = response.headers.value(HttpHeaders.locationHeader);
      final isRedirect = status >= 300 && status < 400 && location != null;
      if (isRedirect) {
        // 换下一跳前必须读掉响应体，否则连接会泄漏。
        await response.drain<void>().timeout(_timeout);
        final next = current.resolve(location);
        if (!ShuAuthConstants.isShuHost(next.host)) {
          throw ShuAuthException(
            'otpUnsafeRedirect',
            '动态口令页跳到了校外地址（${next.host}）',
          );
        }
        // 跳回统一认证登录页 = 会话已经失效。这里就下结论，不必跟到底。
        if (next.toString().contains(ShuAuthConstants.loginPathMarker)) {
          return const _OtpHop.loginRedirect();
        }
        current = next;
        continue;
      }
      return _OtpHop(
        status: status,
        body: await _readBody(response),
        refresh: response.headers.value('refresh'),
      );
    }
    throw const ShuAuthException(
      'otpParseFailed',
      '动态口令页跳转次数过多（超过 $_maxRedirects 跳）',
    );
  }

  /// 读取正文，**容忍非法 UTF-8**。
  ///
  /// `response.transform(utf8.decoder)` 碰到非法字节会抛 `FormatException`，
  /// 一次取码会因此整条失败 —— 而这里只需要能正则出六个数字。
  Future<String> _readBody(HttpClientResponse response) async {
    try {
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk))
          .timeout(_timeout);
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } on Object {
      return '';
    }
  }

  /// 追加一次性查询串，绕开中间层缓存。
  static Uri _noCache(Uri uri) => uri.replace(
    queryParameters: <String, String>{
      ...uri.queryParameters,
      '_': '${DateTime.now().millisecondsSinceEpoch}',
    },
  );

  static String _snippet(String body) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 160 ? flat : '${flat.substring(0, 160)}…';
  }
}

/// 一次取页的结果。
class _OtpHop {
  const _OtpHop({required this.status, required this.body, this.refresh})
    : isLoginRedirect = false;

  /// 被踢回统一认证登录页 —— 会话失效的确定信号。
  const _OtpHop.loginRedirect()
    : status = HttpStatus.found,
      body = '',
      refresh = null,
      isLoginRedirect = true;

  final int status;
  final String body;
  final String? refresh;
  final bool isLoginRedirect;
}

/// 从 `Refresh` 响应头里解出剩余秒数。
///
/// 这个头允许带跳转指令（`14;url=/Default.aspx`），也可能带引号，所以只取
/// **前导整数**。取不到、或值为 0（意味着「立刻刷新」，此时页面里那个值
/// 更可信）时返回 `null`，由调用方退回页面脚本的值。
int? parseRefreshSeconds(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'^\s*"?\s*(\d{1,5})').firstMatch(raw);
  final value = int.tryParse(match?.group(1) ?? '');
  if (value == null || value <= 0) return null;
  return value;
}

/// 从 OTP 的 `Default.aspx` 里解出口令、账户名与剩余秒数。
///
/// 取不到口令节点时返回 `null` —— 会话失效时页面会退回登录引导，
/// 此时不能瞎报一个码。
ShuOtpPage? parseOtpPage(String html) {
  final code =
      _codePattern.firstMatch(html)?.group(1)?.trim() ??
      _codeValuePattern.firstMatch(html)?.group(1)?.trim();
  if (code == null || code.isEmpty) return null;

  final account = _accountPattern.firstMatch(html)?.group(1)?.trim() ?? '';
  final remaining =
      int.tryParse(_remainPattern.firstMatch(html)?.group(1) ?? '') ??
      ShuOtpPage.defaultPeriod;
  final period =
      int.tryParse(_totalPattern.firstMatch(html)?.group(1) ?? '') ??
      ShuOtpPage.defaultPeriod;
  return ShuOtpPage(
    code: code,
    account: account,
    remaining: Duration(seconds: remaining),
    period: period,
  );
}

// 属性顺序和引号写法都可能变，所以用 `[^>]*` 容忍 `style` 之类的属性，
// 引号双写兼容单双两种写法。
//
// `(?:<[^>]+>|&nbsp;|&#160;|[\s\u00A0])*` 是**后加的容错**：换模板时口令
// 外面常常多裹一层标签，或者中间的空白换成了不换行空格。原来的写法要求
// 数字紧贴 `>`，那样只要多一层 `<span>` 就整个解不出来。
final _codePattern = RegExp(
  r'''id=["']DataList1_LabelNum_\d+["'][^>]*>(?:<[^>]+>|&nbsp;|&#160;|[\s\u00A0])*(\d{4,8})''',
);

/// 兜底：WebForms 换控件类型时口令可能落在 `value` 属性里。
final _codeValuePattern = RegExp(
  r'''id=["']DataList1_LabelNum_\d+["'][^>]*value=["'](\d{4,8})["']''',
);

final _accountPattern = RegExp(
  r'''id=["']DataList1_LabelAccount_\d+["'][^>]*>(?:<[^>]+>|&nbsp;|&#160;|[\s\u00A0])*([^<]*?)\s*<''',
);

// 不再要求 `let` / `const` 前缀：模板换写法（`var`、`window.x =`、末尾换成
// `)`）时正则不该整条失配。
final _remainPattern = RegExp(r'remainingSeconds\s*=\s*(\d+)\s*[;,)]');
final _totalPattern = RegExp(r'totalSeconds\s*=\s*(\d+)\s*[;,)]');
