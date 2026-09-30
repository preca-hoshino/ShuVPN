// 设置的模式版本与迁移。
//
// 这一层只在**升级**那一刻跑一次，而那时没有人看着 —— 迁移写错的表现是
// 「用户升完级打开，某个设置莫名其妙变了」，从现象上完全追不到这里。所以
// 每一版迁移的「保留什么、删掉什么」都在这里钉死。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/core/settings/settings_schema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v1 → v2', () {
    test('清掉「资源外直连」—— 那个能力整个撤掉了', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 1,
        'settings.proxyDirectFallback': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ShuSettingsStore(prefs);

      expect(store.needsMigration, isTrue);
      await store.migrateIfNeeded();

      expect(prefs.containsKey('settings.proxyDirectFallback'), isFalse);
      expect(store.storedVersion, ShuSettingsSchema.current);
    });

    test('保留代理与 VPN 的设置，不丢用户改过的值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 1,
        'settings.autoStartProxy': true,
        'settings.socksPort': 1080,
        'settings.socksListen': '0.0.0.0',
        'settings.vpnMtu': 1280,
        'settings.vpnDns': '10.10.0.116',
        'settings.server': 'other.example',
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.getBool('settings.autoStartProxy'), isTrue);
      expect(prefs.getInt('settings.socksPort'), 1080);
      expect(prefs.getString('settings.socksListen'), '0.0.0.0');
      expect(prefs.getInt('settings.vpnMtu'), 1280);
      expect(prefs.getString('settings.vpnDns'), '10.10.0.116');
      expect(prefs.getString('settings.server'), 'other.example');
    });

    test('不碰 auth. 开头的键 —— 那是凭据，不是设置', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 1,
        'auth.session': '{"cookies":[]}',
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.getString('auth.session'), '{"cookies":[]}');
    });

    test('幂等：已经是当前版本时什么都不做', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: ShuSettingsSchema.current,
        // 手工塞一个「上一版残留」的键：它不该被这一轮的迁移碰到。
        'settings.proxyDirectFallback': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ShuSettingsStore(prefs);

      expect(store.needsMigration, isFalse);
      await store.migrateIfNeeded();

      expect(prefs.containsKey('settings.proxyDirectFallback'), isTrue);
    });

    test('v0（没有版本号）会连着跑完 v1 与 v2', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.lastServer': 'old.example',
        'settings.proxyDirectFallback': true,
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.containsKey('settings.lastServer'), isFalse);
      expect(prefs.containsKey('settings.proxyDirectFallback'), isFalse);
      expect(
        prefs.getInt(ShuSettingsSchema.versionKey),
        ShuSettingsSchema.current,
      );
    });
  });
}
