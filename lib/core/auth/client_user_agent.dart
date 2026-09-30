import 'package:flutter/foundation.dart';

/// 发起原生认证请求时使用的 User-Agent。
///
/// newsso 与各业务系统都会按 UA 分流，改写会拿到不同的页面，
/// 所以这里固定用移动浏览器的值。
class ClientUserAgent {
  const ClientUserAgent._();

  static const android =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  static const ios =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 '
      'Mobile/15E148 Safari/604.1';

  static String get mobileBrowser => forPlatform(defaultTargetPlatform);

  @visibleForTesting
  static String forPlatform(TargetPlatform platform) {
    return platform == TargetPlatform.iOS ? ios : android;
  }
}
