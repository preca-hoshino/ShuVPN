import 'dart:io';

/// 原生认证流程在内存中维护的 Cookie 容器。
///
/// 抽成独立类是为了让「企业微信扫码取得的 SSO 会话 Cookie 是否正确并入
/// 后续请求」这一行为可以脱离 WebView 平台单独测试 ——
/// [ShuNativeAuthService] 的安装步骤会创建 `WebViewCookieManager`，
/// 在纯 Dart 单元测试里不可用。
class ShuCookieStore {
  final List<_StoredCookie> _cookies = [];

  /// 并入一批 Cookie。空值、已过期的 Cookie 会被丢弃；
  /// 同名同域同路径的旧 Cookie 会被覆盖。
  void save(Uri source, Iterable<Cookie> cookies) {
    for (final cookie in cookies) {
      final domain =
          (cookie.domain?.isNotEmpty == true ? cookie.domain! : source.host)
              .replaceFirst(RegExp(r'^\.'), '');
      final path = cookie.path?.isNotEmpty == true ? cookie.path! : '/';
      _cookies.removeWhere(
        (stored) =>
            stored.cookie.name == cookie.name &&
            stored.domain == domain &&
            stored.path == path,
      );
      if (cookie.value.isNotEmpty &&
          (cookie.expires == null || cookie.expires!.isAfter(DateTime.now()))) {
        _cookies.add(_StoredCookie(cookie, domain, path));
      }
    }
  }

  /// 构造适用于 [uri] 的 `Cookie` 请求头，顺带清理已过期的条目。
  String headerFor(Uri uri) =>
      cookiesFor(uri).entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');

  /// 适用于 [uri] 的 Cookie（`name → value`），顺带清理已过期的条目。
  ///
  /// 需要与别的来源（例如 aTrust 链路自己的 jar）合并请求头时用这个 ——
  /// 拼字符串再去重不如直接合表。
  Map<String, String> cookiesFor(Uri uri) {
    final now = DateTime.now();
    _cookies.removeWhere(
      (stored) => stored.cookie.expires?.isBefore(now) == true,
    );
    final result = <String, String>{};
    for (final stored in _cookies) {
      if (stored.matches(uri)) result[stored.cookie.name] = stored.cookie.value;
    }
    return result;
  }

  /// 某个主机名下是否存在该名字的 Cookie（不论值）。
  bool contains(String name) =>
      _cookies.any((stored) => stored.cookie.name == name);

  /// 读取某个主机名下某个 Cookie 的值；不存在时返回 `null`。
  ///
  /// aTrust 这类系统把会话凭证放在 Cookie 里而不是响应体里，需要一个出口。
  String? valueFor(String host, String name) {
    for (final stored in _cookies) {
      if (stored.cookie.name != name) continue;
      final normalized = host.toLowerCase();
      if (normalized == stored.domain ||
          normalized.endsWith('.${stored.domain}')) {
        return stored.cookie.value;
      }
    }
    return null;
  }

  /// 某个主机名下当前持有的 Cookie 名（脱敏诊断用）。
  List<String> namesFor(String host) {
    final normalized = host.toLowerCase();
    final names = <String>{};
    for (final stored in _cookies) {
      if (normalized == stored.domain ||
          normalized.endsWith('.${stored.domain}')) {
        names.add(stored.cookie.name);
      }
    }
    return names.toList()..sort();
  }

  /// 清空全部 Cookie（退出登录）。
  void clear() => _cookies.clear();

  /// 当前持有的 Cookie 快照，供安装进 WebView 时使用。
  List<({Cookie cookie, String domain, String path})> get entries => [
    for (final stored in _cookies)
      (cookie: stored.cookie, domain: stored.domain, path: stored.path),
  ];
}

class _StoredCookie {
  const _StoredCookie(this.cookie, this.domain, this.path);

  final Cookie cookie;
  final String domain;
  final String path;

  bool matches(Uri uri) {
    final hostMatches = uri.host == domain || uri.host.endsWith('.$domain');
    // Uri.path 对 "https://host" 形式返回空串，但 HTTP 语义上等价于 "/"。
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    return hostMatches && requestPath.startsWith(path);
  }
}
