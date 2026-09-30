/// 统一身份认证与各业务系统的固定参数。
///
/// 数值来源于 [shu-sso-poc] 的抓包与实测；学校侧变更需要同步更新这里。
///
/// [shu-sso-poc]: file:///../../SHU-POC/shu-sso-poc
library;

class ShuAuthConstants {
  const ShuAuthConstants._();

  /// 统一身份认证（SSO）站点，`authorize` 与业务系统回调都在这里。
  static const ssoBase = 'https://newsso.shu.edu.cn';

  /// SSO 判定「未登录」时跳转的登录页路径片段。
  ///
  /// `params` 就藏在这个路径段里 —— 见 [ShuAuthConstants.loginPathMarker]
  /// 的用法（`NativeAuthService._extractParams`）。
  static const loginPathMarker = '/oauth2/login/';

  /// SSO 会话 Cookie 名。
  static const sessionCookieName = 'SHU_OAUTH2';

  /// 租户名，登录请求体里原样提交。
  static const tenant = '上海大学';

  /// OAuth 授权端点路径。
  static const authorizePath = '/oauth/authorize';

  /// 两步验证方式，与 newsso 线格式同名。
  static const methodWeCom = 'wecom';
  static const methodSms = 'sms';

  // ---------------------------------------------------------------- aTrust

  /// aTrust 网关。它自己也是一个 OAuth 客户端，既是授权码的回收方，
  /// 也是会话（`sid`）的签发方。
  static const atrustHost = 'atrust.shu.edu.cn';

  /// aTrust 的 `loginDomain`（`sfDomain`）。
  ///
  /// 正常由网关在 `authConfig` 里下发；这里是兜底值。换域时以网关为准。
  static const atrustLoginDomain = 'customOAuth76881';

  /// aTrust 换票据的端点 —— 授权码交给它，**不是**交回 newsso。
  static const atrustCallbackPath = '/passport/v1/auth/httpsOauth2';

  /// aTrust 回调成功后跳转的落地页（`Location` 里带 `data={"ticket":...}`）。
  static const atrustShortcutPath = '/portal/shortcut.html';

  /// aTrust 网关识别的客户端 UA。
  ///
  /// 网关会按 UA 判定客户端类型，不伪装成官方客户端会被直接拒绝；
  /// 与 `zju-connect` 的 `auth.UserAgent` 逐字一致。
  static const atrustUserAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'aTrustTray/2.4.10.50 Chrome/83.0.4103.94 Electron/9.0.2 Safari/537.36 '
      'aTrustTray-Linux-Plat-Ubuntu-x64 SPCClientType';

  /// 填给 SDK `SangforConnectOptions.username` 的占位值。
  ///
  /// 上大的 aTrust 走 OAuth2：身份由统一身份认证下发的授权码决定，
  /// 网关从来不接收账号名 —— `zju-connect` 在 OAuth2 分支里**从不发送
  /// 用户名**（账号密码参数根本不参与请求）。但 SDK 的
  /// `SangforConnectOptions` 把 `username` 声明成 `required`，
  /// `validate()` 还会拒绝空串，所以必须填一个。
  ///
  /// 这个值不会出现在任何请求里，也不该被当成登录信息 —— 所以刻意取一个
  /// 一眼就是占位的字面量，而不是伪造一个学号去误导日志。
  static const oauthPlaceholderUsername = 'sso/oracle';

  // ------------------------------------------------------------ 业务系统入口

  /// `params` 的发现入口。
  ///
  /// **关键**：`params` 不是随手拼出来的常量，而是新闻 SO 登录页 URL 路径里的
  /// 一段 base64url。它的内容来自新闻 SO 自己按注册的 OAuth 客户端生成的
  /// 登录链接 —— 唯一可靠的取得方式是**走一遍真实的 302 链**，
  /// 从 `/oauth2/login/<params>` 里把它截下来。
  ///
  /// 之前硬编码过一份（自己编了 `clientName`），服务端直接返回
  /// `{"message":"badRequestParams"}`，因为该客户端根本没有注册。
  ///
  /// 这里用教务系统作入口：它公开可达、不需要任何前置握手，
  /// 且服务端只校验 `params` 的**格式**，不关心它对应哪个业务系统。
  static const paramsEntryUrl = 'https://jwxt.shu.edu.cn';

  // ------------------------------------------------------------ 教务系统

  /// 教务系统站点。
  static const jwxtBase = 'https://jwxt.shu.edu.cn';

  /// 个人信息片段的路径（`zftal-ui-v5` 的 `xtgl` 模块）。
  ///
  /// 它返回的不是整页，而是一小段 HTML —— 见 [ShuJwxtProfileService]。
  static const jwxtProfilePath = '/jwglxt/xtgl/index_cxYhxxIndex.html';

  /// 读档案时的 `Referer`。教务系统会校验来源是同站点。
  static const jwxtReferer = '$jwxtBase/jwglxt/xtgl/index_initMenu.html';

  /// 课表查询页。作用是**先把查询条件播种到服务端会话里**，
  /// 再调 [jwxtScheduleDataPath]。
  static const jwxtScheduleIndexPath =
      '/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html?gnmkdm=N2151&layout=default';

  /// 课表数据接口。POST 表单，返回 JSON。
  ///
  /// 响应里的 `xsxx` 是学生基本信息，`XM` / `XH` / `BJMC` 分别是
  /// **姓名 / 学号 / 班级** —— 学号的权威来源就是这里。
  /// 它与个人档案片段里的名字**天然一致**：同一个 `media-heading` 里那段文字
  /// 本来就是「姓名 学号」而不是「姓名 角色」。
  static const jwxtScheduleDataPath =
      '/jwglxt/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151';

  // ---------------------------------------------------------------- 企业微信

  /// 上海大学企业微信自建应用 appid。
  static const weComAppId = 'wxa8dea949443de641';

  /// 上海大学企业微信自建应用 agentid。
  static const weComAgentId = '1000059';

  /// 企微扫码确认回调地址（newsso 侧的 `/oauth/wecom/qrcode`）。
  static const weComRedirectUri = '$ssoBase/oauth/wecom/qrcode';

  /// 企微扫码会话页面（返回 HTML，内嵌 `qrImg?key=<key>`）。
  static const weComQrConnectBase =
      'https://open.work.weixin.qq.com/wwopen/sso/qrConnect';

  /// 二维码图片地址。
  static const weComQrImgBase =
      'https://open.work.weixin.qq.com/wwopen/sso/qrImg';

  /// 扫码后企微客户端打开的确认页地址。
  static const weComConfirmBase =
      'https://open.work.weixin.qq.com/wwopen/sso/confirm2';

  /// 扫码状态长轮询地址（JSONP）。
  static const weComLongPollBase =
      'https://open.work.weixin.qq.com/wwopen/sso/l/qrConnect';

  /// 企微客户端协议：在企微内拉起内置浏览器打开指定 URL。
  ///
  /// 来源：企微官方 confirm2 页面内联脚本，原文为
  /// `launchWWByScheme("wxwork://sso/jump?url=" + encodeURIComponent(url))`。
  static const weComSchemeJumpBase = 'wxwork://sso/jump?url=';

  /// 承载企微扫码会话的域名，用于构造正确的 Referer/Origin。
  static const weComHost = 'open.work.weixin.qq.com';

  /// 是否属于上海大学域名（含子域）。所有跳转都会过这一层白名单。
  static bool isShuHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'shu.edu.cn' || normalized.endsWith('.shu.edu.cn');
  }
}

/// 一个业务系统在 newsso 侧的 OAuth 注册信息。
///
/// 只登记 [shu-sso-poc] 验证过的字段；新增系统必须先在 POC 里跑通。
///
/// [shu-sso-poc]: file:///../../SHU-POC/shu-sso-poc
class ShuOAuthTarget {
  const ShuOAuthTarget({
    required this.kind,
    required this.clientId,
    required this.clientName,
    required this.scope,
    required this.redirectUri,
    this.generateState = false,
    this.needsStateBootstrap,
    this.followUpUrl,
    this.successUrlContains,
    this.successBodyContains,
    this.landingUrl,
    this.internal = false,
  });

  /// 系统 key，等于域名首段，例如 `otp`。
  final ShuOAuthTargetKind kind;

  /// 业务系统在 newsso 注册的 `client_id`。
  final String clientId;

  /// 展示名，同时用于 `/oauth/authorize` 之外的可读日志。
  final String clientName;

  final String scope;
  final String redirectUri;

  /// 为 true 时由本地生成随机 state 防 CSRF。
  final bool generateState;

  /// 非空时先访问这个地址向系统索要 `state`（存于它的服务端会话里）。
  final String? needsStateBootstrap;

  /// 回调页用 `Refresh` 头而非 302 跳转时，需要手动补访问一次。
  final String? followUpUrl;

  /// 判定换会话成功的 URL 关键词。
  final String? successUrlContains;

  /// 判定换会话成功的正文关键词。
  final String? successBodyContains;

  /// 用户手动打开系统时应当访问的地址。
  final String? landingUrl;

  /// 是否为内部系统。
  ///
  /// 内部系统仍然会**正常交换凭据**（课表、成绩这类功能靠它），
  /// 只是不在账号页里单独列一行 —— 用户不需要知道它，也无从操作它。
  final bool internal;

  /// 供 [encodeOAuthParams] 编码为 `state` 的原始参数。
  Map<String, String> toParams() => {
    'responseType': 'code',
    'clientId': clientId,
    'clientName': clientName,
    'scope': scope,
    'redirectUri': redirectUri,
    'state': '',
  };
}

/// 已接入的三个业务系统。
///
/// **只有 atrust / otp / jwxt** —— 全部参数来自 [shu-sso-poc] 的实测。
///
/// [shu-sso-poc]: file:///../../SHU-POC/shu-sso-poc
abstract final class ShuOAuthTargets {
  // -------------------------------------------------------- 交换顺序
  //
  // 顺序即 `ShuOAuthTargets.all` 的顺序，两件事都依赖它：
  //   1. 凭据交换按这个顺序跑；
  //   2. 账号页那一列凭据行也按这个顺序排。
  //
  // 教务系统排在最前，因为它是唯一会回答「你是谁」的系统 —— 姓名、学号、
  // 专业、学院都从它那里来。用户登录后看到的第一个变化应该是自己的名字，
  // 而不是两个还没连上的隧道状态。

  /// 本科生教务系统。
  ///
  /// 授权请求本就不带 `state`，由本地生成随机 UUID 防 CSRF。
  ///
  /// 标记为 [internal]：凭据照常交换（课表与成绩靠它），但不在账号页露出。
  static const jwxt = ShuOAuthTarget(
    kind: ShuOAuthTargetKind.jwxt,
    clientId: 'Km5t225E8KECKQ6ZDm5K2P6aS2459Cua',
    clientName: '本科生教务系统',
    scope: 'jw',
    redirectUri: 'https://jwxt.shu.edu.cn/sso/shulogin',
    generateState: true,
    successUrlContains: 'jwglxt',
    successBodyContains: '教学管理',
    landingUrl: 'https://jwxt.shu.edu.cn/jwglxt/xtgl/index_initMenu.html',
    internal: true,
  );

  /// OTP 令牌。
  ///
  /// 两个坑：`redirect_uri` 里的双斜杠是注册值，不能"顺手"改单斜杠；
  /// `state` 存在服务端 `ASP.NET_SessionId` 里，必须先 `GET /` 预热。
  static const otp = ShuOAuthTarget(
    kind: ShuOAuthTargetKind.otp,
    clientId: '05Q1L8woQK5350aK1U5o5GKh411ar3h1',
    clientName: 'OTP令牌',
    scope: 'read write',
    // 双斜杠是服务端注册值。
    redirectUri: 'https://otp.shu.edu.cn//Callback.aspx',
    // Callback.aspx 会校验存在 ASP.NET_SessionId 里的 state，必须先访问入口
    // 预热，否则回调报「State验证失败」。
    needsStateBootstrap: 'https://otp.shu.edu.cn/',
    // 回调页用 `Refresh: 0;url=Default.aspx` 而非 302。
    followUpUrl: 'https://otp.shu.edu.cn/Default.aspx',
    successUrlContains: 'Default.aspx',
    successBodyContains: '账户名',
    landingUrl: 'https://otp.shu.edu.cn/Default.aspx',
  );

  /// aTrust VPN 网关。
  ///
  /// aTrust 自己就是一个 OAuth 客户端：授权码交回
  /// `GET /passport/v1/auth/httpsOauth2` 后，它自己拿 code 去换 token 并下发
  /// `sid` cookie —— 客户端不需要参与换 token。
  static const atrust = ShuOAuthTarget(
    kind: ShuOAuthTargetKind.atrust,
    clientId: 'u5kTNw6T59kw3wkrwZ76e44kBec4HTvv',
    clientName: 'aTrust系统',
    scope: '',
    redirectUri: 'https://atrust.shu.edu.cn/passport/v1/auth/httpsOauth2',
    successUrlContains: 'atrust',
    landingUrl: 'https://atrust.shu.edu.cn/portal/',
  );

  /// 全部需要交换凭据的系统，**顺序即交换顺序**。
  ///
  /// 教务系统排第一：它回答「你是谁」。
  static const all = <ShuOAuthTarget>[jwxt, atrust, otp];

  /// 账号页那一列凭据行的顺序。
  ///
  /// 与 [all] 同序 —— 页面上的先后和后台交换的先后一致，看起来才不会
  /// 「上面那行还在转、下面那行已经好了」这种对不上的感觉。
  static const visible = <ShuOAuthTarget>[jwxt, atrust, otp];

  static ShuOAuthTarget? byId(String id) {
    for (final target in all) {
      if (target.kind.id == id) return target;
    }
    return null;
  }
}

/// 系统标识。用枚举而不是字符串，让 `switch` 能穷尽检查。
///
/// [host] 是列表里给用户看的那个东西：系统的名字与它所在的域名。
/// 两个地方共用它 —— 账户管理的凭据行、引导页第 3 页的系统清单 —— 所以
/// 「教务系统」下面写的是哪个域名，在哪儿都是同一个答案。
///
/// 域名与 [ShuOAuthTarget] 里的 `landingUrl` / `redirectUri` 必须同源，
/// 但**不从这里反推**：那些是完整的回调地址（带路径、带查询串），
/// 反推一次就要处理各种拼法；这里写死、由测试钉住一致性。
enum ShuOAuthTargetKind {
  atrust('atrust', 'aTrust 网关', 'atrust.shu.edu.cn', 'SSL VPN 网关，用于建立全局隧道'),
  otp('otp', 'OTP 令牌', 'otp.shu.edu.cn', '动态口令，每 30 秒轮换'),
  jwxt('jwxt', '教务系统', 'jwxt.shu.edu.cn', '课表与成绩，JWGLXT');

  const ShuOAuthTargetKind(
    this.id,
    this.displayName,
    this.host,
    this.description,
  );

  /// 系统 key，等于域名首段，也是持久化与路由里用的标识。
  final String id;

  final String displayName;

  /// 系统所在域名 —— 列表里那一行的副标题。
  final String host;

  final String description;

  static ShuOAuthTargetKind? fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}
