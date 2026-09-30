/// The single SHU gateway this app talks to.
///
/// 只有两个常量，都是**出厂值**（默认值），不是「唯一合法的值」：用户可以在
/// 设置 → aTrust 协议里改服务器地址与登录域，[SettingsStore] 读不到用户改过的
/// 值时就回落到这里。
///
/// 那个「一个应用只服务一所学校」的判断也体现在这里 —— 换学校就是换这两行，
/// 而不是加一个「请选择学校」的下拉框。
///
/// EasyConnect 的协议核心仍然链在包里（`flutter_sangfor_easy_connect`），
/// 但它在界面上是被封住的那一个：上大部署暴露的是 aTrust，同时摆两个协议栈
/// 只会问用户一个他答不上来的问题。要解封，改的是设置页上那个开关。
abstract final class ShuEndpoint {
  const ShuEndpoint._();

  /// aTrust 网关的域名。服务器地址的出厂值。
  static const host = 'atrust.shu.edu.cn';

  /// The `loginDomain` that `GET /passport/v1/public/authConfig` reports for
  /// the unified-identity method on this gateway.
  static const loginDomain = 'customOAuth76881';
}
