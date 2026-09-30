import 'dart:async';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// aTrust 会将会话绑定到一个 `deviceId`，所以它必须跨重启保持稳定 ——
/// 每次登录换一个新 id，网关就会把同一台手机当成一台新设备。
///
/// 账号层与连接层共用这一个出口：`reportEnv` 上报的设备和隧道握手用的设备
/// 必须是同一个，否则会话与隧道会被判定成两台机器。
class ShuATrustDeviceId {
  const ShuATrustDeviceId(this._preferences);

  /// 持久化键。历史上由 `ConnectionController` 私有维护，这里接管后
  /// 键名保持不变，老用户的设备号不会丢。
  static const storageKey = 'atrust_device_id';

  /// 可以为空 —— 纯 Dart 环境（单元测试）里没有 Preferences，
  /// 此时退化成一次性随机值，不影响链路本身。
  final SharedPreferences? _preferences;

  String get value {
    final preferences = _preferences;
    final existing = preferences?.getString(storageKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = generate();
    if (preferences != null) {
      unawaited(preferences.setString(storageKey, generated));
    }
    return generated;
  }

  /// 32 位十六进制，与 aTrust 桌面客户端下发的形态一致。
  static String generate([Random? random]) {
    final source = random ?? Random.secure();
    return List.generate(
      16,
      (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// 脱敏后的设备标识，供设置页展示。
  ///
  /// 取值的定义在**这里**而不是页面里：设备号是一种敏感标识（它把会话绑在
  /// 一台机器上），要摆到界面上时怎么截断，应当是它自己的属性，而不是每个
  /// 用它的页面各写一遍 `substring`。
  String get masked {
    final raw = value;
    if (raw.length <= 8) return '••••';
    return '${raw.substring(0, 4)}••••${raw.substring(raw.length - 4)}';
  }
}
