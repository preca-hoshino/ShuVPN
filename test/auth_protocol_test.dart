// 统一身份认证协议层的离线单测。
//
// 这里覆盖的是「登录报参数错误」那个 bug 的根因：`params` 不能硬编码，
// 必须从真实登录页 URL 的路径段里截取。其余是编码格式与解析逻辑。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/core/auth/auth_constants.dart';
import 'package:shuvpn/core/auth/auth_cookie_store.dart';
import 'package:shuvpn/core/auth/atrust_device_id.dart';
import 'package:shuvpn/core/auth/credential_service.dart';
import 'package:shuvpn/core/auth/jwxt_profile_service.dart';
import 'package:shuvpn/core/auth/native_auth_service.dart';
import 'package:shuvpn/core/auth/otp_service.dart';
import 'package:shuvpn/core/auth/wecom_auth_service.dart';
import 'package:shuvpn/core/logging/shu_log.dart';

void main() {
  group('encodeOAuthParams', () {
    test('produces base64url without padding', () {
      final encoded = encodeOAuthParams(<String, String>{
        'responseType': 'code',
        'clientId': 'abc',
        'clientName': '本科生教务系统',
        'scope': 'jw',
        'redirectUri': 'https://jwxt.shu.edu.cn/sso/shulogin',
        'state': '',
      });
      // base64url 字符集：不含 `+` 或 `/`，且没有 `=` 填充。
      expect(encoded, isNot(contains('+')));
      expect(encoded, isNot(contains('/')));
      expect(encoded, isNot(contains('=')));
      // 能解回来，且顺序与输入一致。
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      final json = utf8.decode(base64Url.decode(padded));
      expect(json.indexOf('responseType'), lessThan(json.indexOf('clientId')));
      expect(json.indexOf('clientId'), lessThan(json.indexOf('clientName')));
      expect(json, contains('本科生教务系统'));
    });

    test('matches the format the WeCom redeem endpoint expects', () {
      // 企微扫码的 state 必须是教务参数，否则 /oauth/wecom/qrcode
      // 返回 badRequestParams。
      final state = ShuWeComAuthService.weComRedeemState;
      expect(state, isNot(contains('=')));
      final padded = state.padRight((state.length + 3) ~/ 4 * 4, '=');
      final json = utf8.decode(base64Url.decode(padded));
      expect(json, contains(ShuOAuthTargets.jwxt.clientId));
      expect(json, contains('本科生教务系统'));
    });
  });

  group('RSA password encryption', () {
    test('returns base64 of exactly one 1024-bit block', () {
      final encrypted = ShuPasswordEncryptor.encrypt('hunter2');
      final bytes = base64.decode(encrypted);
      expect(bytes.length, 128);
    });

    test('is randomised by PKCS#1 v1.5 padding', () {
      final first = ShuPasswordEncryptor.encrypt('same-password');
      final second = ShuPasswordEncryptor.encrypt('same-password');
      expect(first, isNot(second));
    });

    test('rejects a password longer than the modulus allows', () {
      // 1024 位模数减去 11 字节的 PKCS#1 v1.5 开销 = 117 字节。
      expect(
        () => ShuPasswordEncryptor.encrypt('x' * 200),
        throwsA(isA<Object>()),
      );
    });
  });

  group('system registry', () {
    test('exactly the three systems the user asked for', () {
      expect(
        ShuOAuthTargets.all.map((target) => target.kind.id).toList(),
        <String>['jwxt', 'atrust', 'otp'],
      );
    });

    test('the academic system leads, because it answers "who am I"', () {
      // 顺序即交换顺序。教务系统排第一，账号页那块姓名/学号才有东西可显示。
      expect(ShuOAuthTargets.all.first, same(ShuOAuthTargets.jwxt));
      expect(ShuOAuthTargets.visible.first, same(ShuOAuthTargets.jwxt));
    });

    test('otp keeps its double-slash redirect_uri', () {
      // 双斜杠是服务端注册值，改成单斜杠会让 state 校验失败。
      expect(
        ShuOAuthTargets.otp.redirectUri,
        'https://otp.shu.edu.cn//Callback.aspx',
      );
      expect(
        ShuOAuthTargets.otp.needsStateBootstrap,
        'https://otp.shu.edu.cn/',
      );
      expect(
        ShuOAuthTargets.otp.followUpUrl,
        'https://otp.shu.edu.cn/Default.aspx',
      );
    });

    test('only jwxt generates a random state', () {
      expect(ShuOAuthTargets.jwxt.generateState, isTrue);
      expect(ShuOAuthTargets.atrust.generateState, isFalse);
      expect(ShuOAuthTargets.otp.generateState, isFalse);
    });

    test('aTrust redirect points at its own passport endpoint', () {
      expect(
        ShuOAuthTargets.atrust.redirectUri,
        'https://atrust.shu.edu.cn/passport/v1/auth/httpsOauth2',
      );
    });

    test('byId resolves every registered id', () {
      for (final target in ShuOAuthTargets.all) {
        expect(ShuOAuthTargets.byId(target.kind.id), same(target));
      }
      expect(ShuOAuthTargets.byId('webvpn'), isNull);
    });

    test('the displayed host matches the system it names', () {
      // 账号页的凭据行与引导页第 3 页的清单都把 `kind.host` 当副标题印出来。
      // 它是**手写的**（见枚举文档：不从完整回调地址反推），所以必须有东西
      // 钉住它 —— 否则改了 `landingUrl` 却忘了改这一个，界面上会指着别的域名，
      // 而那是排障时最容易信错的一句话。
      for (final target in ShuOAuthTargets.all) {
        final urls = <String?>[target.landingUrl, target.redirectUri];
        for (final url in urls) {
          expect(
            Uri.parse(url!).host,
            target.kind.host,
            reason: '${target.kind.id} 的 ${target.kind.host} 与实际地址不一致',
          );
        }
      }
    });
  });

  group('login page params discovery', () {
    test('the entry point is a SHU host over https', () {
      // params 的来源必须是一个真实可 302 的入口，不能是拼出来的常量。
      final entry = Uri.parse(ShuAuthConstants.paramsEntryUrl);
      expect(entry.scheme, 'https');
      expect(ShuAuthConstants.isShuHost(entry.host), isTrue);
    });

    test('host whitelist rejects lookalike domains', () {
      expect(ShuAuthConstants.isShuHost('jwxt.shu.edu.cn'), isTrue);
      expect(ShuAuthConstants.isShuHost('shu.edu.cn'), isTrue);
      // 经典的绕过写法：把 shu.edu.cn 放在子域位置。
      expect(ShuAuthConstants.isShuHost('shu.edu.cn.evil.com'), isFalse);
      expect(ShuAuthConstants.isShuHost('notshu.edu.cn'), isFalse);
    });
  });

  group('cookie store', () {
    test('scopes cookies to the host that set them', () {
      final store = ShuCookieStore();
      store.save(Uri.parse('https://newsso.shu.edu.cn/oauth/userLogin'), [
        Cookie(ShuAuthConstants.sessionCookieName, 'secret'),
      ]);
      expect(store.contains(ShuAuthConstants.sessionCookieName), isTrue);
      expect(
        store.headerFor(Uri.parse('https://newsso.shu.edu.cn/oauth/authorize')),
        '${ShuAuthConstants.sessionCookieName}=secret',
      );
      // 其它主机拿不到。
      expect(store.headerFor(Uri.parse('https://otp.shu.edu.cn/')), isEmpty);
    });

    test('overwrites the same name/domain/path', () {
      final store = ShuCookieStore();
      final uri = Uri.parse('https://otp.shu.edu.cn/');
      store.save(uri, [Cookie('ASP.NET_SessionId', 'first')]);
      store.save(uri, [Cookie('ASP.NET_SessionId', 'second')]);
      expect(store.headerFor(uri), 'ASP.NET_SessionId=second');
    });

    test('an empty value clears the cookie', () {
      final store = ShuCookieStore();
      final uri = Uri.parse('https://atrust.shu.edu.cn/');
      store.save(uri, [Cookie('sid', 'value')]);
      store.save(uri, [Cookie('sid', '')]);
      expect(store.valueFor('atrust.shu.edu.cn', 'sid'), isNull);
    });

    test('valueFor ignores case and matches subdomains', () {
      final store = ShuCookieStore();
      store.save(Uri.parse('https://atrust.shu.edu.cn/'), [
        Cookie('sid', 'abc'),
      ]);
      expect(store.valueFor('ATRUST.SHU.EDU.CN', 'sid'), 'abc');
      // 子域也可以看到父域的 cookie。
      expect(store.valueFor('portal.atrust.shu.edu.cn', 'sid'), 'abc');
    });

    test('looks up a cookie set on a different portal', () {
      final store = ShuCookieStore();
      store.save(Uri.parse('https://otp.shu.edu.cn/'), [
        Cookie('ASP.NET_SessionId', 'x'),
      ]);
      // 同名 cookie 不会跨主机串门。
      expect(store.valueFor('jwxt.shu.edu.cn', 'ASP.NET_SessionId'), isNull);
    });

    test('adopting external cookies makes the session visible', () {
      final store = ShuCookieStore();
      store.save(Uri.parse('https://newsso.shu.edu.cn/'), [
        Cookie(ShuAuthConstants.sessionCookieName, 'from-wecom'),
      ]);
      expect(
        store.namesFor('newsso.shu.edu.cn'),
        contains(ShuAuthConstants.sessionCookieName),
      );
      store.clear();
      expect(store.hasSsoSession, isFalse);
    });
  });

  group('error messages', () {
    test('translates the codes the server actually returns', () {
      expect(
        ShuNativeAuthService.messageForCode('badPassword'),
        contains('密码'),
      );
      expect(
        ShuNativeAuthService.messageForCode('invalidCode'),
        contains('验证码'),
      );
      expect(ShuNativeAuthService.messageForCode('userLocked'), contains('锁定'));
      expect(
        ShuNativeAuthService.messageForCode('ipLimitExceeded'),
        contains('频繁'),
      );
      expect(ShuNativeAuthService.messageForCode('senderror'), contains('频繁'));
    });

    test('badRequestParams explains what actually went wrong', () {
      // 这个就是硬编码 params 时会拿到的错误。
      final message = ShuNativeAuthService.messageForCode('badRequestParams');
      expect(message, contains('参数'));
    });

    test('an unknown code is still surfaced, not swallowed', () {
      final message = ShuNativeAuthService.messageForCode('somethingNew');
      expect(message, contains('somethingNew'));
    });
  });

  group('aTrust OAuth2 chain', () {
    // 这一段锁的是「aTrust 凭据一直换不到」的根因：授权码要交给 aTrust，
    // 而且换票据的地址必须带上网关下发的 sfDomain。
    test('the exchange is registered against the gateway, not newsso', () {
      expect(
        ShuOAuthTargets.atrust.redirectUri,
        'https://${ShuAuthConstants.atrustHost}'
        '${ShuAuthConstants.atrustCallbackPath}',
      );
      expect(ShuOAuthTargets.atrust.redirectUri, contains('httpsOauth2'));
    });

    test('falls back to the login domain the gateway reports', () {
      expect(ShuAuthConstants.atrustLoginDomain, isNotEmpty);
      expect(ShuAuthConstants.atrustShortcutPath, '/portal/shortcut.html');
    });

    test('the device id is stable and persists', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final first = ShuATrustDeviceId(preferences).value;
      expect(first, hasLength(32));
      // 第二次读到的必须是同一个 —— 换了设备号，网关会当成另一台手机。
      expect(ShuATrustDeviceId(preferences).value, first);
      expect(preferences.getString(ShuATrustDeviceId.storageKey), first);
    });

    test('a device id can be generated without preferences', () {
      final generated = ShuATrustDeviceId(null).value;
      expect(generated, hasLength(32));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(generated), isTrue);
    });
  });

  group('OTP page parsing', () {
    // 对齐 shu-otp-poc/sso/otp.py：口令、账户名、剩余秒数、周期。
    const page = '''
      <html><body>
        <span id="DataList1_LabelNum_0">193746</span>
        <span id="DataList1_LabelAccount_0">zhangsan</span>
        <script>let remainingSeconds = 23;
const totalSeconds = 30;</script>
      </body></html>
      ''';

    test('reads the code, account, remaining seconds and period', () {
      final parsed = parseOtpPage(page);
      expect(parsed, isNotNull);
      expect(parsed!.code, '193746');
      expect(parsed.account, 'zhangsan');
      expect(parsed.remaining, const Duration(seconds: 23));
      expect(parsed.period, 30);
    });

    test('handles non-zero list indices', () {
      final parsed = parseOtpPage(
        '<span id="DataList1_LabelNum_3">555111</span>',
      );
      expect(parsed?.code, '555111');
    });

    test('tolerates style attributes and single quotes', () {
      // 站点给 span 加属性、或换成单引号，解析都不该跪。
      final parsed = parseOtpPage(
        "<span id='DataList1_LabelNum_0' style='color:red'>680421</span>",
      );
      expect(parsed?.code, '680421');
    });

    test('returns null when the page has no token node', () {
      // 会话失效时 OTP 会返回登录页，此时不能瞎报一个码。
      expect(parseOtpPage('<html><body>请登录</body></html>'), isNull);
    });

    test('defaults to 30 seconds when the script is missing', () {
      final parsed = parseOtpPage(
        '<span id="DataList1_LabelNum_0">193746</span>',
      );
      expect(parsed?.remaining, const Duration(seconds: 30));
      expect(parsed?.period, 30);
    });

    // 下面四条是后加的容错。每一条都对应一种「页面看起来正常、却取不到码」
    // 的真实写法 —— 取不到码在界面上只会显示成一句「交换失败」。

    test('tolerates a wrapper element around the token', () {
      final parsed = parseOtpPage(
        '<span id="DataList1_LabelNum_0"><b>680421</b></span>',
      );
      expect(parsed?.code, '680421');
    });

    test('tolerates non-breaking spaces around the token', () {
      final parsed = parseOtpPage(
        '<span id="DataList1_LabelNum_0">&nbsp;680421&nbsp;</span>',
      );
      expect(parsed?.code, '680421');
    });

    test('falls back to a value attribute', () {
      // WebForms 换控件类型时会变成 input。
      final parsed = parseOtpPage(
        '<input id="DataList1_LabelNum_0" value="680421" />',
      );
      expect(parsed?.code, '680421');
    });

    test('reads the script without requiring let/const', () {
      final parsed = parseOtpPage(
        '<span id="DataList1_LabelNum_0">193746</span>'
        '<script>var remainingSeconds = 7; window.totalSeconds = 60;</script>',
      );
      expect(parsed?.remaining, const Duration(seconds: 7));
      expect(parsed?.period, 60);
    });

    test('an account node that is missing only leaves the name empty', () {
      // 账户名是展示信息，取不到不该让整次取码失败。
      final parsed = parseOtpPage(
        '<span id="DataList1_LabelNum_0">193746</span>',
      );
      expect(parsed?.account, '');
      expect(parsed?.code, '193746');
    });
  });

  group('OTP Refresh header', () {
    // 这个头允许带跳转指令、也允许带引号，只取前导整数。
    test('reads a bare number', () {
      expect(parseRefreshSeconds('14'), 14);
      expect(parseRefreshSeconds(' 14 '), 14);
    });

    test('reads a number followed by a url directive', () {
      expect(parseRefreshSeconds('14;url=/Default.aspx'), 14);
      expect(parseRefreshSeconds('"14; url=/Default.aspx"'), 14);
    });

    test('returns null for junk, absence and zero', () {
      expect(parseRefreshSeconds(null), isNull);
      expect(parseRefreshSeconds(''), isNull);
      expect(parseRefreshSeconds('soon'), isNull);
      // 0 表示「立刻刷新」，那时候页面里那个值更可信。
      expect(parseRefreshSeconds('0'), isNull);
    });
  });

  group('credential model', () {
    test('only available credentials count as usable', () {
      expect(
        const ShuSystemCredential(
          systemId: 'otp',
          state: ShuCredentialState.available,
        ).isUsable,
        isTrue,
      );
      expect(
        const ShuSystemCredential(
          systemId: 'otp',
          state: ShuCredentialState.expired,
        ).isUsable,
        isFalse,
      );
    });

    test('failures carry a code and a message', () {
      final failed = ShuSystemCredential.failed(
        'atrust',
        code: 'atrustNoSid',
        message: '未下发会话凭证',
      );
      expect(failed.state, ShuCredentialState.failing);
      expect(failed.errorCode, 'atrustNoSid');
      expect(failed.errorMessage, '未下发会话凭证');
    });

    test('copyWith can clear a previous error', () {
      final failed = ShuSystemCredential.failed('otp', code: 'x', message: 'y');
      final retried = failed.copyWith(
        state: ShuCredentialState.refreshing,
        clearError: true,
      );
      expect(retried.errorCode, isNull);
      expect(retried.errorMessage, isNull);
      expect(retried.state, ShuCredentialState.refreshing);
    });
  });

  group('mask', () {
    test('keeps a short secret unreadable', () {
      expect(mask('abc'), '••••');
    });

    test('keeps only the head and tail of a long secret', () {
      final masked = mask('0123456789abcdef');
      expect(masked, startsWith('0123'));
      expect(masked, endsWith('cdef'));
      expect(masked, contains('••••'));
      expect(masked.length, lessThan('0123456789abcdef'.length));
    });
  });

  group('jwxt profile parsing', () {
    // 这一段锁的是账号页第一块的数据来源：教务系统的个人信息片段只有
    // 两段文本，姓名在 `media-heading` 里，其余三项挤在一个 `<p>` 里。
    const page = '''
<input type="hidden" name="xxdm1" value="10280" id="xxdm1"/>
<div class="media">
  <a class="pull-left" href="#">
    <img class="media-object" alt="110x110"
         src="/zftal-ui-v5-1.0.2/assets/images/user_logo.jpg"
         style="width: 110px; height: 110px;">
  </a>
  <div class="media-body">
    <h4 class="media-heading">张三&nbsp;&nbsp;25123456</h4>
    <p>示例学院 2025级示例专业</p>
  </div>
</div>
''';

    test(
      'reads the name from the heading, and a numeric second word as the id',
      () {
        expect(parseJwxtProfile(page)?.name, '张三');
        expect(parseJwxtProfile(page)?.studentId, '25123456');
      },
    );

    test('does not mistake a role suffix for a student id', () {
      // 服务端如果改回「姓名 学生」，第二段不能被当成学号。
      final profile = parseJwxtProfile(
        '<h4 class="media-heading">王五&nbsp;&nbsp;学生</h4><p>示例学院 2025级示例专业</p>',
      );
      expect(profile?.name, '王五');
      expect(profile?.studentId, isNull);
    });

    test('splits the info line into college, grade and major', () {
      final profile = parseJwxtProfile(page);
      expect(profile?.college, '示例学院');
      expect(profile?.grade, '2025级');
      expect(profile?.major, '示例专业');
    });

    test('survives a reordered info line', () {
      // 按位置解会把学院名当成专业名 —— 只有按关键词解才经得起顺序变化。
      final profile = parseJwxtProfile(
        '<h4 class="media-heading">赵六 25123457</h4>'
        '<p>2024级 示例工程学院 示例工程</p>',
      );
      expect(profile?.name, '赵六');
      expect(profile?.college, '示例工程学院');
      expect(profile?.grade, '2024级');
      expect(profile?.major, '示例工程');
    });

    test('returns null when the session has lapsed', () {
      // 会话失效时这个片段是登录跳转，不能报一个空档案。
      expect(parseJwxtProfile('<html><body>请登录</body></html>'), isNull);
      expect(parseJwxtProfile(''), isNull);
    });

    test('keeps the fields it could read when the rest is missing', () {
      final profile = parseJwxtProfile(
        '<h4 class="media-heading">钱七</h4><p>2023级信息工程</p>',
      );
      expect(profile?.name, '钱七');
      expect(profile?.studentId, isNull);
      expect(profile?.grade, '2023级');
      expect(profile?.major, '信息工程');
      expect(profile?.college, isNull);
    });

    test('round-trips through the credential payload', () {
      const original = ShuJwxtProfile(
        name: '张三',
        studentId: '25123456',
        grade: '2025级',
        college: '示例学院',
        major: '示例专业',
      );
      final restored = ShuJwxtProfile.fromPayload(original.toPayload());
      expect(restored?.name, original.name);
      expect(restored?.studentId, original.studentId);
      expect(restored?.grade, original.grade);
      expect(restored?.college, original.college);
      expect(restored?.major, original.major);
    });

    test('a payload without a name is not a profile', () {
      expect(ShuJwxtProfile.fromPayload(const <String, Object?>{}), isNull);
      expect(
        ShuJwxtProfile.fromPayload(const <String, Object?>{'name': '  '}),
        isNull,
      );
    });

    test('a role suffix is not a student id', () {
      // 实测教务系统的标题就是「姓名 + 学生」。学号不在这个片段里，
      // 只能靠课表接口的 `xsxx.XH` —— 所以这里必须解出 null 而不是
      // 把「学生」当成某种奇怪的学号。
      final profile = parseJwxtProfile(
        '<h4 class="media-heading">张三&nbsp;&nbsp;学生</h4>'
        '<p>示例学院 2025级示例专业</p>',
      );
      expect(profile?.name, '张三');
      expect(profile?.studentId, isNull);
    });
  });

  group('jwxt schedule identity', () {
    test('reads the current term out of the schedule page', () {
      // 课表查询页里被选中的那一对学期编码，必须原样回填给数据接口。
      const page = '''
<select name="xnm" id="xnm" class="form-control">
  <option value="2024">2024-2025</option>
  <option value="2025" selected>2025-2026</option>
</select>
<select name="xqm" id="xqm" class="form-control">
  <option value="3">第二学期</option>
  <option value="12" selected>第一学期</option>
</select>
''';
      final term = parseScheduleTerm(page);
      expect(term.year, '2025');
      expect(term.term, '12');
      expect(term.isEmpty, isFalse);
    });

    test('falls back to hidden inputs when there is no select', () {
      const page =
          '<input type="hidden" name="xnm" value="2024">'
          '<input type="hidden" name="xqm" value="3">';
      final term = parseScheduleTerm(page);
      expect(term.year, '2024');
      expect(term.term, '3');
    });

    test('reports an empty term instead of guessing', () {
      // 解不出来时必须如实说空 —— 传空串给数据接口只会换来一份没有
      // `xsxx` 的课表，那正是「学号一栏永远空着」的原因。
      expect(parseScheduleTerm('').isEmpty, isTrue);
      expect(parseScheduleTerm('<html>请登录</html>').isEmpty, isTrue);
    });

    test('reads name, id and class from the xsxx block', () {
      const body =
          '{"kbList":[],"xsxx":'
          '{"XM":"张三","XH":"25123456","BJMC":"示例专业 2501"}}';
      final identity = parseScheduleIdentity(body);
      expect(identity?.name, '张三');
      expect(identity?.studentId, '25123456');
      expect(identity?.className, '示例专业 2501');
    });

    test('a schedule without xsxx is not an identity', () {
      // 学期参数错了正方就是这个样子：200 + 一份没有 `xsxx` 的课表。
      expect(parseScheduleIdentity('{"kbList":[]}'), isNull);
      expect(parseScheduleIdentity('<html>请登录</html>'), isNull);
      expect(parseScheduleIdentity(''), isNull);
    });

    test('a non-string XH is ignored rather than stringified', () {
      // 正方偶尔把学号发成数字。`_text` 只认字符串，所以这里要落到 null，
      // 而不是悄悄变成 "25123456" 让上层以为拿到了。
      final identity = parseScheduleIdentity(
        '{"xsxx":{"XM":"张三","XH":25123456}}',
      );
      expect(identity?.name, '张三');
      expect(identity?.studentId, isNull);
    });
  });

  group('redirect following keeps mid-hop cookies', () {
    // 这一段锁的是「教务档案一直 901」的根因。
    //
    // `dart:io` 的 `followRedirects = true` 不会把中间跳转响应的
    // `Set-Cookie` 带给下一跳（它没有 cookie jar）；而教务系统正是在
    // `/sso/shulogin?code=…` 那一跳才下发 `JSESSIONID`，丢了它后面全是
    // 未登录 —— 正方对 Ajax 请求直接回空 body 的 `901`。
    //
    // 这里用一个本地两跳 302 的服务复现：`/a` 种 `hopa`，`/b` 种 `hopb`，
    // 落点把收到的 Cookie 回显出来。
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        final path = request.uri.path;
        if (path == '/a' || path == '/b') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.setCookieHeader,
              path == '/a' ? 'hopa=yes' : 'hopb=yes',
            )
            ..headers.set(
              HttpHeaders.locationHeader,
              path == '/a' ? '/b' : '/landing',
            )
            ..close();
          return;
        }
        final seen = request.headers[HttpHeaders.cookieHeader] ?? <String>[];
        request.response
          ..write(seen.join('; '))
          ..close();
      });
    });

    tearDown(() => server.close(force: true));

    test('a manual hop loop collects every Set-Cookie on the way', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      // 手动跟随：每一跳都把 Set-Cookie 收进一个 jar。
      final jar = <String, String>{};
      var current = Uri.parse('http://127.0.0.1:${server.port}/a');
      var body = '';
      for (var hop = 0; hop < 8; hop++) {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        if (jar.isNotEmpty) {
          request.headers.set(
            HttpHeaders.cookieHeader,
            jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
          );
        }
        final response = await request.close();
        for (final cookie in response.cookies) {
          jar[cookie.name] = cookie.value;
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) {
          body = await response.transform(utf8.decoder).join();
          break;
        }
        await response.drain<void>();
        current = current.resolve(location);
      }
      expect(jar.keys, containsAll(<String>['hopa', 'hopb']));
      expect(body, contains('hopa=yes'));
      expect(body, contains('hopb=yes'));
    });

    test('auto-following drops them, which is why we do not use it', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/a'),
      );
      request.followRedirects = true;
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      // 落点什么都收不到。这条断言是**故意的**：如果哪天 dart:io 修了
      // 这个行为，这条测试会红，提醒我们回来重新评估 `_follow` 是否还需要。
      expect(body, isEmpty);
    });
  });
}
