import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../logging/shu_log.dart';
import 'auth_constants.dart';

/// 持久化的统一身份认证（newsso）会话。
///
/// 这是 ShuVPN 唯一会被**跨版本复用**的一份状态：`SHU_OAUTH2` 的
/// 有效期在服务端是数天级的，把它存下来，重启应用甚至升级版本之后都
/// 不必让用户再登一次。
///
/// 与用户设置（`SettingsStore`）刻意分开存：
///
/// | | 凭据 | 设置 |
/// | :--- | :--- | :--- |
/// | 内容 | 服务端下发的会话 Cookie | 用户手选的偏好 |
/// | 版本变更时 | **原样保留** | 可能失效，要迁移 |
/// | 失效原因 | Cookie 本身过期 | 字段语义变了 |
///
/// 混在一张表里的话，「换个字段名」和「退出登录」就分不清了 ——
/// 前者不该丢会话，后者必须丢。所以两边的键前缀也分开：
/// `auth.` 与 `settings.`。
///
/// 参考实现（`ShuYo` 的 `AcademicAuthService`）同样把 Cookie 单独
/// 序列化成 JSON 存在自己的键下（`academic.auth.cached_cookies.*`），
/// 与 `ClientSettingsService` 的用户设置完全分离。
class ShuCredentialStore {
  const ShuCredentialStore(this._prefs);

  /// 存 Cookie 的键。
  ///
  /// **改这个键会丢掉所有已登录用户**，所以要动它必须同时保留旧版本的
  /// 读取路径（见 [restore] 的 `_legacyKeys`）。
  static const storageKey = 'auth.newsso.cookies';

  final SharedPreferences _prefs;

  /// 把 `newsso` 的会话 Cookie 落盘。
  ///
  /// 只存 [ShuAuthConstants.sessionCookieName] —— 其它主机（aTrust 网关、
  /// OTP、教务系统）的会话都是**换来的**，重新登录时几秒钟就能再换一次；
  /// 而统一身份认证的会话是用户亲手输密码换来的，那才是值得存的那一份。
  Future<void> save(Iterable<Cookie> cookies) async {
    final encoded = <Map<String, String>>[
      for (final cookie in cookies)
        if (cookie.name.isNotEmpty && cookie.value.isNotEmpty)
          <String, String>{
            'name': cookie.name,
            'value': cookie.value,
            if (cookie.path != null) 'path': cookie.path!,
            if (cookie.expires != null)
              'expires': cookie.expires!.toUtc().toIso8601String(),
          },
    ];
    if (encoded.isEmpty) return;
    await _prefs.setString(storageKey, jsonEncode(encoded));
  }

  /// 读回会话 Cookie。没有、或已全部过期时返回空表。
  ///
  /// 过期的条目在这里就丢掉，不让调用方拿到一个注定被判无效的会话。
  List<Cookie> restore() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return const <Cookie>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Cookie>[];
      final now = DateTime.now();
      final restored = <Cookie>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final name = entry['name'];
        final value = entry['value'];
        if (name is! String || value is! String) continue;
        if (name.isEmpty || value.isEmpty) continue;
        final cookie = Cookie(name, value);
        final path = entry['path'];
        if (path is String && path.isNotEmpty) cookie.path = path;
        final expires = entry['expires'];
        if (expires is String) {
          final parsed = DateTime.tryParse(expires);
          if (parsed == null) {
            // 存进去时是我们自己序列化的，解析不了说明数据坏了，跳过。
            continue;
          }
          if (!parsed.isAfter(now)) continue;
          cookie.expires = parsed;
        }
        restored.add(cookie);
      }
      return restored;
    } on Object catch (error) {
      // 数据坏了就当作没有会话，让用户重新登录一次即可，
      // 不能因为一段坏 JSON 让应用起不来。
      ShuLog.w(ShuLogTag.auth, '统一身份认证会话读取失败 · $error · 按未登录处理');
      return const <Cookie>[];
    }
  }

  /// 清空（退出登录）。
  Future<void> clear() => _prefs.remove(storageKey);
}
