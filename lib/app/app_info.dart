/// Static identity of the app.
///
/// Kept as constants (instead of `package_info_plus`) so the about page, the
/// settings subtitle and the Android build metadata can never drift apart in
/// a way the user would notice. Bump these together with `pubspec.yaml`.
abstract final class ShuAppInfo {
  static const String name = 'ShuVPN';
  static const String version = '0.1.0';
  static const String buildLabel = '1';
  static const String versionLabel = '$version ($buildLabel)';

  static const String tagline = '上大 aTrust RVPN 客户端';
  static const String disclaimer = '本应用与上海大学无隶属关系。';

  static const String repository = 'https://github.com/preca-hoshino/ShuVPN';
}
