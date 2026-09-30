import 'package:shared_preferences/shared_preferences.dart';

/// 用户设置的**模式版本**。
///
/// 与凭据分开管理：凭据（`ShuCredentialStore`）跨版本复用，因为它代表
/// 服务端认可的一个会话；设置则可能因为字段语义变化而失效，所以要能
/// 按版本处理。
///
/// 每加一个需要清理 / 重写的版本就往上加一，并在
/// [ShuSettingsStore.migrateIfNeeded] 里补一个 `if (stored < N)` 分支。
///
/// 参考实现（`ShuYo` 的 `AppDataMigrationService`）用的是同一套办法：
/// `currentSchemaVersion` + `client.data.schema.version` 键，
/// 落后就在启动时清理一轮再写回新版本号。
abstract final class ShuSettingsSchema {
  const ShuSettingsSchema._();

  /// 当前版本。
  ///
  /// * 1 —— 首个带版本号的版本。
  /// * 2 —— 数据面拆成三条（系统 VPN / 本机 SOCKS5 / 本机 HTTP），
  ///   并去掉「资源外直连」。
  static const current = 2;

  /// 记录已完成的版本。缺失（0）表示这是从没有版本号的旧版本升上来的。
  static const versionKey = 'settings.schema.version';
}

/// 带版本控制的用户设置。
///
/// 为什么要有版本号：设置是**长期躺在磁盘上**的东西，而代码一直在变。
/// 没有版本号时，一次字段改名就只能靠「兼容读旧键 + 兼容读新键」堆下去，
/// 堆到后来没人说得清哪个键还有用。有版本号就有了一条明确的路径：
/// 「现在存的是第 N 版，第 N 版之前的东西一律按 [migrateIfNeeded] 处理」。
///
/// 键前缀的策略：
///
/// | 域 | 前缀 | 跨版本 |
/// | :--- | :--- | :--- |
/// | 凭据 | `auth.` | **保留** |
/// | 设置 | `settings.` | 可能迁移 |
///
/// 两边分开，是因为「换个设置字段名」与「退出登录」是两件事 ——
/// 前者绝不该丢掉用户的会话。
///
/// 注意 [migrateIfNeeded] **不动 `auth.` 开头的键**。退出登录有它自己的
/// 入口（`AccountCenter.signOut`）。
class ShuSettingsStore {
  ShuSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  /// 需要版本控制时读这个键，而不是「有没有值」——
  /// 一个值存在不代表它是当前语义下的值。
  int get storedVersion => _prefs.getInt(ShuSettingsSchema.versionKey) ?? 0;

  /// 磁盘上的设置是否需要迁移。
  bool get needsMigration => storedVersion < ShuSettingsSchema.current;

  /// 按需迁移，并把版本号推进到当前值。
  ///
  /// 幂等：已经是当前版本时立即返回。必须在**读取任何设置之前**调用。
  Future<void> migrateIfNeeded() async {
    if (!needsMigration) return;
    final from = storedVersion;

    if (from < 1) {
      await _migrateToV1();
    }
    if (from < 2) {
      await _migrateToV2();
    }

    await _prefs.setInt(
      ShuSettingsSchema.versionKey,
      ShuSettingsSchema.current,
    );
  }

  /// v0 → v1：清掉不带版本号的旧版本可能留下的、当前设置已经不再使用的键。
  ///
  /// 现在只清一个演示键。将来每加一个版本，都在这里补一段 —— 但要遵守
  /// 一条：**只清 `settings.` 与 `app.` 开头的键**。`auth.` 开头的属于
  /// 凭据，不在设置的管辖范围内。
  Future<void> _migrateToV1() async {
    // `settings.lastServer` 是曾经用过、后来并入 `settings.server` 的旧键。
    await _prefs.remove('settings.lastServer');
  }

  /// v1 → v2：数据面从两条变成三条。
  ///
  /// 需要清掉的只有一项：**「资源外直连」**。这个开关背后的能力整个撤掉了
  /// （所有目标一律走隧道，不再从底层网络私下出去），磁盘上那个布尔值从此
  /// 不再对应任何行为。留着它不会出错，但会让「用户改过什么」和「代码
  /// 还认什么」多一个对不上的点 —— 而这正是版本号存在的意义。
  ///
  /// 其余旧键**原样保留**：
  ///
  /// * `settings.autoStartProxy` —— 语义从「启用本机代理」窄化成「启用
  ///   SOCKS5 代理」，但值本身继续有效，不丢用户的设置；
  /// * `settings.socksPort` / `settings.socksListen` —— 仍然是 SOCKS5 那一组。
  Future<void> _migrateToV2() async {
    await _prefs.remove('settings.proxyDirectFallback');
  }
}
