import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/credential_service.dart';
import '../auth/jwxt_profile_service.dart';
import '../logging/shu_log.dart';

/// 上一次核对通过时，账户页看到的那些字段。
///
/// 为什么要有快照：账户页上的东西（姓名、学号、各系统连上没有）**只能靠
/// 网络问出来**，而问一次的代价不小 —— 其中一项真的去建了一条 aTrust
/// 隧道再断开。每次启动都问一遍，用户看到的就是「一打开应用，账户页那几行
/// 先变成未连接，几秒后再变回来」，而他根本没打开过那一页。
///
/// 所以：核对的结果落盘，页面先照上次的样子渲染，**等用户真的用到账户页时
/// 再核对**（见 `ShuAccountCenter.verifyIfStale`）。核对发现会话已经失效，
/// 才清掉并提示重新登录；其它失败（网络抖动之类）原样保留上次的结论。
///
/// 与 [ShuCredentialStore] 分开存：
///
/// | | 会话 Cookie | 账户快照 |
/// | :--- | :--- | :--- |
/// | 内容 | 服务端下发的 `SHU_OAUTH2` | 上次核对的展示用结论 |
/// | 丢了会怎样 | 要重新输密码 | 只是少显示几行字 |
/// | 谁负责清 | 退出登录 | 退出登录 / 核对发现失效 |
///
/// 两者的风险差着量级，不该由同一次清理一起承担。
@immutable
class ShuAccountSnapshot {
  const ShuAccountSnapshot({
    this.accountId,
    this.profile,
    this.credentials = const <String, ShuCredentialState>{},
    this.verifiedAt,
  });

  /// 什么都没核对过。
  static const empty = ShuAccountSnapshot();

  /// 学号。权威来源是教务系统的 `XH`，企微扫码那条路也能靠它补上。
  final String? accountId;

  /// 教务系统读到的学生档案（姓名 / 年级 / 学院 / 专业）。
  final ShuJwxtProfile? profile;

  /// 每个系统上次看到的状态。
  final Map<String, ShuCredentialState> credentials;

  /// 上一次**核对成功**的时刻。为 null 表示磁盘上没有可用结论，
  /// 此时 [ShuAccountCenter.verifyIfStale] 会无条件核一次。
  final DateTime? verifiedAt;

  bool get isEmpty =>
      accountId == null &&
      profile == null &&
      credentials.isEmpty &&
      verifiedAt == null;

  Map<String, Object?> toJson() => <String, Object?>{
    if (accountId != null) 'accountId': accountId,
    if (profile != null) 'profile': profile!.toPayload(),
    'credentials': <String, String>{
      for (final entry in credentials.entries) entry.key: entry.value.name,
    },
    if (verifiedAt != null) 'verifiedAt': verifiedAt!.toUtc().toIso8601String(),
  };

  /// 从磁盘上读回的那段 JSON 还原；解析不了就当作没有结论。
  static ShuAccountSnapshot fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final accountId = _text(raw['accountId']);
    final profileRaw = raw['profile'];
    final credentials = <String, ShuCredentialState>{};
    final credentialsRaw = raw['credentials'];
    if (credentialsRaw is Map) {
      for (final entry in credentialsRaw.entries) {
        final key = entry.key;
        final state = _stateOf(entry.value);
        if (key is! String || state == null) continue;
        credentials[key] = state;
      }
    }
    DateTime? verifiedAt;
    final verifiedRaw = raw['verifiedAt'];
    if (verifiedRaw is String) verifiedAt = DateTime.tryParse(verifiedRaw);
    return ShuAccountSnapshot(
      accountId: accountId,
      profile: profileRaw is Map
          ? ShuJwxtProfile.fromPayload(Map<String, Object?>.from(profileRaw))
          : null,
      credentials: credentials,
      verifiedAt: verifiedAt,
    );
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// `refreshing` 是**过程态**，不可能在磁盘上出现（只有一轮跑完才落盘）；
  /// 真读到了就当作「不知道」，别让页面停在「正在获取…」上。
  static ShuCredentialState? _stateOf(Object? raw) {
    if (raw is! String) return null;
    for (final state in ShuCredentialState.values) {
      if (state.name == raw) {
        return state == ShuCredentialState.refreshing
            ? ShuCredentialState.unknown
            : state;
      }
    }
    return null;
  }
}

/// 账户快照的落盘位置。
///
/// 键前缀 `auth.` —— 与 [ShuCredentialStore] 同域，都与「这台设备登的是谁」
/// 有关，而与用户手选的偏好（`settings.`）无关。
class ShuAccountSnapshotStore {
  const ShuAccountSnapshotStore(this._prefs);

  /// 存快照的键。
  ///
  /// **改这个键只会让用户下次多等一轮核对**，不像会话 Cookie 那样要重新
  /// 输密码 —— 这是两份状态分开存的好处之一。
  static const storageKey = 'auth.account.snapshot';

  final SharedPreferences _prefs;

  ShuAccountSnapshot load() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return ShuAccountSnapshot.empty;
    try {
      return ShuAccountSnapshot.fromJson(jsonDecode(raw));
    } on Object catch (error) {
      // 坏数据只当没有结论：页面退回「未登录」，用户重新登一次即可，
      // 不能因为一段坏 JSON 让应用起不来。
      ShuLog.w(ShuLogTag.account, '账户快照读取失败 · $error · 按没有结论处理');
      return ShuAccountSnapshot.empty;
    }
  }

  Future<void> save(ShuAccountSnapshot snapshot) async {
    if (snapshot.isEmpty) return;
    await _prefs.setString(storageKey, jsonEncode(snapshot.toJson()));
  }

  Future<void> clear() => _prefs.remove(storageKey);
}
