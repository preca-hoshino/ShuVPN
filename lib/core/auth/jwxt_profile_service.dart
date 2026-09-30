import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../logging/shu_log.dart';
import 'auth_constants.dart';
import 'auth_cookie_store.dart';
import 'client_user_agent.dart';

/// 从教务系统读到的学生档案。
///
/// 这是账号页里唯一一段「非凭据」的信息 —— 姓名、年级、学院、专业。
/// 它不参与任何认证，只用来让用户确认自己登的是谁，所以整条链路对它是
/// **尽力而为**：解析失败就退回显示学号，绝不影响凭据交换本身。
@immutable
class ShuJwxtProfile {
  const ShuJwxtProfile({
    required this.name,
    this.studentId,
    this.grade,
    this.college,
    this.major,
  });

  /// 姓名，例如 `张三`。
  final String name;

  /// 学号，例如 `25123456`。
  ///
  /// 实测个人信息片段的标题是「姓名 + **学生**」（`张三&nbsp;&nbsp;学生`），
  /// **里面没有学号** —— 所以这个字段大多数时候是 `null`，账户页的学号
  /// 只能来自课表接口的 `xsxx.XH`，也就是 [ShuJwxtIdentity.studentId]。
  ///
  /// 留着它是因为「万一某个院系的模板把学号写在标题里」时不该白丢；
  /// 但**不要再指望它**。
  final String? studentId;

  /// 年级，例如 `2025级`。
  final String? grade;

  /// 学院，例如 `示例学院`。
  final String? college;

  /// 专业，例如 `自动化`。
  final String? major;

  /// 展平进 [ShuSystemCredential.payload]，随凭据一起保存。
  ///
  /// 用 map 而不是给凭据加字段：档案是从教务系统**顺带**读到的，
  /// 不是凭据本身的一部分，混进类型里会让凭据模型承担它不该管的展示职责。
  Map<String, Object?> toPayload() => <String, Object?>{
    'name': name,
    if (studentId != null) 'studentId': studentId,
    if (grade != null) 'grade': grade,
    if (college != null) 'college': college,
    if (major != null) 'major': major,
  };

  /// 从凭据载荷还原；没有姓名时返回 `null`（视为没读到档案）。
  static ShuJwxtProfile? fromPayload(Map<String, Object?> payload) {
    final name = _text(payload['name']);
    if (name == null) return null;
    return ShuJwxtProfile(
      name: name,
      studentId: _text(payload['studentId']),
      grade: _text(payload['grade']),
      college: _text(payload['college']),
      major: _text(payload['major']),
    );
  }

  /// 描述「这次读到了哪几项」，**不含任何值**。
  ///
  /// 姓名与学号都可识别到个人，而这个字符串要进日志、会被复制出去。
  /// 排查「账号页少一行」时真正需要知道的只是「接口没给」还是「没解析出来」，
  /// 所以只报存在性。
  String describeFields() => describePresent(<String, bool>{
    '姓名': name.isNotEmpty,
    '学号': studentId != null,
    '年级': grade != null,
    '学院': college != null,
    '专业': major != null,
  });

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  String toString() => 'ShuJwxtProfile($name, $grade, $college, $major)';
}

/// 教务系统的「个人信息」接口。
///
/// 它是 `zftal-ui-v5` 的一个页面片段，登录态下返回一段极简 HTML：
///
/// ```html
/// <h4 class="media-heading">张三&nbsp;&nbsp;25123456</h4>
/// <p>示例学院 2025级示例专业</p>
/// ```
///
/// 也就是说，整条接口只有两块文本：`media-heading` 里的姓名与学号，
/// 以及 `<p>` 里的「学院 年级+专业」。教务系统没有提供 JSON 版本，
/// 所以只能解析 HTML —— 正则刻意写得宽松，属性顺序、单双引号、
/// 空白数量变化都不会失配。
///
/// 注意：它必须**排在 jwxt 换会话之后**调用，因为 `jwglxt` 的 Cookie
/// 是那一步才进 [ShuCookieStore] 的。
class ShuJwxtProfileService {
  ShuJwxtProfileService({
    required ShuCookieStore cookieStore,
    HttpClient? httpClient,
  }) : _cookies = cookieStore,
       _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 8);
    _client.userAgent = ClientUserAgent.mobileBrowser;
  }

  static const _timeout = Duration(seconds: 15);

  final ShuCookieStore _cookies;
  final HttpClient _client;

  void dispose() => _client.close(force: true);

  /// 读一次档案。会话失效、结构变更、任何非 200 都返回 `null`。
  ///
  /// 失败路径全部降级：这个方法只影响账号页上那几行展示文字，
  /// 不该把整次登录牵连成失败。
  Future<ShuJwxtProfile?> fetch() async {
    final uri = Uri.parse(ShuAuthConstants.jwxtBase).replace(
      path: ShuAuthConstants.jwxtProfilePath,
      queryParameters: <String, String>{
        'xt': 'jw',
        'localeKey': 'zh_CN',
        'gnmkdm': 'index',
        // 时间戳只是防缓存，服务端不校验。
        '_': '${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    try {
      final request = await _client.getUrl(uri);
      request.headers
        ..set(
          HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,*/*;q=0.8',
        )
        ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser)
        ..set(HttpHeaders.refererHeader, ShuAuthConstants.jwxtReferer);
      // 这里**刻意不加** `X-Requested-With: XMLHttpRequest`。
      //
      // 实测：带上它，未登录时正方不回登录页而是直接回空 body 的 `901`；
      // 参考实现（`ShuYo`）也只在 **POST 取课表 JSON** 时加这个头，
      // GET 页面一律不加。没有它，请求至少会拿到一份完整 HTML，
      // 解析器能自己判断里面是不是登录页。
      final cookieHeader = _cookies.headerFor(uri);
      if (cookieHeader.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      final response = await request.close().timeout(_timeout);
      try {
        _cookies.save(uri, response.cookies);
      } on Object {
        // 畸形的 Set-Cookie 不该让读档案失败。
      }
      final body = await _readBody(response);
      if (response.statusCode != 200) {
        ShuLog.w(
          ShuLogTag.jwxt,
          '教务个人档案 · HTTP ${response.statusCode} · ${uri.path}'
          ' · 本次不显示档案',
        );
        return null;
      }
      final profile = parseJwxtProfile(body);
      if (profile == null) {
        // 结构变了或掉回了登录页。把片段开头打出来，下一次就不用靠猜。
        ShuLog.w(
          ShuLogTag.jwxt,
          '教务个人档案：未解出姓名，返回 #${body.length} 字符，'
          '开头：${_preview(body)}',
        );
      } else {
        // 姓名之外的字段可能缺，所以把「拿到了哪几项」记下来 ——
        // 账号页上少一行时，第一个要回答的就是「接口没给」还是「没解析出来」。
        ShuLog.i(ShuLogTag.jwxt, '教务个人档案：${profile.describeFields()}');
      }
      return profile;
    } on Object catch (error) {
      ShuLog.w(ShuLogTag.jwxt, '教务个人档案请求失败（$error），本次不显示档案。');
      return null;
    }
  }

  /// 用课表数据接口补一次身份信息（姓名 / 学号 / 班级）。
  ///
  /// 这是 ShuYo 取学号的方式：`POST .../xskbcx_cxXsgrkb.html` 返回的 JSON 里
  /// 有一个 `xsxx` 块，`XM` / `XH` / `BJMC` 就是**姓名 / 学号 / 班级**。
  ///
  /// 为什么档案片段之外还要这一条：个人信息片段的标题实测是「姓名 + 学生」，
  /// **本来就带学号是奢望** —— 学号只能从这里取。
  ///
  /// 调用前必须先取一次课表页：那个请求会在服务端会话里播种查询条件，
  /// 直接 POST 数据接口会被当成越权访问。任何失败都返回 `null`，
  /// 由调用方决定要不要退回片段里解出来的值。
  Future<ShuJwxtIdentity?> fetchScheduleIdentity() async {
    try {
      // ① 先要课表页。它有两个作用：
      //
      //    1. 把查询条件播种到服务端会话里（直接 POST 会被当成越权）；
      //    2. 把**当前学期的编码**（`xnm` / `xqm`）读回来。
      //
      //    第 2 点最容易漏：`xskbcx_cxXsgrkb.html` 只认真实学期编码，
      //    传空串时正方不报错，而是悄悄回一份没有 `xsxx` 的课表 ——
      //    表现就是「学号一栏永远空着」。参考实现（ShuYo）在 POST 之前
      //    一定会先解析这两个值，并且把它当硬前置。
      final indexUri = Uri.parse(
        ShuAuthConstants.jwxtBase + ShuAuthConstants.jwxtScheduleIndexPath,
      );
      final indexResponse = await _get(indexUri);
      final indexBody = await _readBody(indexResponse);
      if (indexResponse.statusCode != 200) {
        ShuLog.w(
          ShuLogTag.jwxt,
          '教务课表页 · HTTP ${indexResponse.statusCode} · 读不到学期参数',
        );
        return null;
      }
      final term = parseScheduleTerm(indexBody);
      if (term.year.isEmpty || term.term.isEmpty) {
        ShuLog.w(
          ShuLogTag.jwxt,
          '教务课表页 · 未解出学期参数 xnm=${term.year} xqm=${term.term} · '
          '开头 ${_preview(indexBody)}',
        );
      } else {
        ShuLog.d(
          ShuLogTag.jwxt,
          '教务课表页 · 学期 xnm=${term.year} xqm=${term.term}',
        );
      }

      // ② 再要数据。学期参数用刚从课表页里读到的那一对。
      final dataUri = Uri.parse(
        ShuAuthConstants.jwxtBase + ShuAuthConstants.jwxtScheduleDataPath,
      );
      final request = await _client.postUrl(dataUri);
      request.headers
        ..set(HttpHeaders.acceptHeader, '*/*')
        ..set(HttpHeaders.refererHeader, indexUri.toString())
        ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser)
        // ShuYo 只在这个 POST 上加，GET 页面一律不加。
        ..set('X-Requested-With', 'XMLHttpRequest')
        ..contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
      final cookieHeader = _cookies.headerFor(dataUri);
      if (cookieHeader.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      request.write(
        <String, String>{
          'xnm': term.year,
          'xqm': term.term,
          'kzlx': 'ck',
          'xsdm': '',
          'kclbdm': '',
          'kclxdm': '',
        }.entries.map((e) => '${e.key}=${e.value}').join('&'),
      );
      final response = await request.close().timeout(_timeout);
      final body = await _readBody(response);
      if (response.statusCode != 200) {
        ShuLog.w(
          ShuLogTag.jwxt,
          '教务课表数据 · HTTP ${response.statusCode} · 读不到身份信息',
        );
        return null;
      }
      final identity = parseScheduleIdentity(body);
      if (identity == null) {
        ShuLog.w(
          ShuLogTag.jwxt,
          '教务课表数据 · 未解出 xsxx · 返回 ${body.length} 字符 · '
          '开头 ${_preview(body)}',
        );
      } else {
        // 学号是敏感信息，这里只报「拿到了哪几项」。
        ShuLog.i(ShuLogTag.jwxt, '教务课表身份 · ${identity.describeFields()}');
      }
      return identity;
    } on Object catch (error) {
      ShuLog.w(
        ShuLogTag.jwxt,
        '教务课表接口读取身份信息失败 · $error · 退回档案片段里的值',
      );
      return null;
    }
  }

  /// 发起一次带 Cookie 的 GET（课表页预热用）。
  Future<HttpClientResponse> _get(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers
      ..set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,*/*;q=0.8',
      )
      ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser)
      ..set(HttpHeaders.refererHeader, ShuAuthConstants.jwxtReferer);
    final cookieHeader = _cookies.headerFor(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    final response = await request.close().timeout(_timeout);
    try {
      _cookies.save(uri, response.cookies);
    } on Object {
      // 畸形的 Set-Cookie 不该让这条链路失败。
    }
    return response;
  }

  /// 读响应体。
  ///
  /// 实测这个端点的响应头是 `text/html;charset=UTF-8`，所以按 UTF-8 解。
  /// 这里保留一层兵库：万一遇上非法 UTF-8，`utf8.decoder` 会**抛异常**，
  /// 那时退回逐字节映射（中文会是乱码，但姓名之外全是数字与全角空格，
  /// 不影响解析）。
  static Future<String> _readBody(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      bytes.addAll(chunk);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes);
    }
  }

  /// 片段开头，供日志定位（截断到一行）。
  static String _preview(String body) {
    final flattened = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flattened.isEmpty) return '(空)';
    return flattened.length <= 200
        ? flattened
        : '${flattened.substring(0, 200)}…';
  }
}

/// 从个人信息片段里解出档案。取不到姓名就返回 `null`。
///
/// ```html
/// <h4 class="media-heading">张三&nbsp;&nbsp;学生</h4>
/// <p>示例学院 2025级示例专业</p>
/// ```
///
/// ⚠ 标题里的第二段**是角色不是学号**（实测如此）。学院/年级/专业从 `<p>` 里
/// 按关键词取，位置变了也不会解错；**学号请走 [ShuJwxtIdentity]**。
///
/// 按「含关键词」而不是按位置取字段，是因为这段 `<p>` 的排列顺序由教务系统
/// 自己决定，位置一变按顺序解就会把学院名当成专业名。
ShuJwxtProfile? parseJwxtProfile(String html) {
  if (html.isEmpty) return null;

  final heading = _plainText(_headingPattern.firstMatch(html)?.group(1));
  final parts = heading.split(' ').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final name = parts.first;
  final studentId = parts.skip(1).where(_studentIdPattern.hasMatch).firstOrNull;

  final info = _infoPattern
      .allMatches(html)
      .map((match) => _plainText(match.group(1)))
      .firstWhere(
        (text) => text.contains('学院') || text.contains('级'),
        orElse: () => '',
      );

  var college = '';
  var grade = '';
  var major = '';
  for (final token in info.split(' ')) {
    if (token.isEmpty) continue;
    if (college.isEmpty && (token.contains('学院') || token.endsWith('系'))) {
      college = token;
      continue;
    }
    final year = _gradePattern.firstMatch(token);
    if (grade.isEmpty && year != null) {
      grade = year.group(1)!;
      final rest = token.substring(year.end);
      if (major.isEmpty && rest.isNotEmpty) major = rest;
      continue;
    }
    if (major.isEmpty) major = token;
  }

  return ShuJwxtProfile(
    name: name,
    studentId: studentId,
    grade: grade.isEmpty ? null : grade,
    college: college.isEmpty ? null : college,
    major: major.isEmpty ? null : major,
  );
}

/// 从课表接口的 `xsxx` 块里读到的身份信息。
///
/// 只留账户页真正要用的三项。`xsxx` 里还有几十个字段（专业、学院、
/// 校区……），但那些**档案片段已经有更好的版本**，不必重复取。
@immutable
class ShuJwxtIdentity {
  const ShuJwxtIdentity({this.name, this.studentId, this.className});

  final String? name;
  final String? studentId;
  final String? className;

  bool get isEmpty => name == null && studentId == null && className == null;

  /// 同 [ShuJwxtProfile.describeFields]：只报读到了哪几项，不报值。
  String describeFields() => describePresent(<String, bool>{
    '姓名': name != null,
    '学号': studentId != null,
    '班级': className != null,
  });
}

/// 把「哪几项有值」拼成一句给日志用的话。
///
/// 故意不做成某个类的方法：`describeFields` 在两个模型上语义相同，
/// 共用一个实现就不会出现一处格式改了、另一处没跟着改。
String describePresent(Map<String, bool> fields) {
  final present = <String>[
    for (final entry in fields.entries)
      if (entry.value) entry.key,
  ];
  return present.isEmpty ? '一项都没读到' : '读到 ${present.join("、")}';
}

/// 从课表数据的 JSON 里解出 `xsxx`。
///
/// 结构参考 ShuYo 的 `AcademicTerm.fromJson`：
/// ```json
/// { "kbList": [ ... ], "xsxx": { "XM": "张三", "XH": "25123456", "BJMC": "..." } }
/// ```
///
/// 键名是**大写**的（`XM` / `XH` / `BJMC`），与正方其它接口的命名一致。
/// 解析不出来就返回 `null` —— 这个接口是兜底，不是主路径。
ShuJwxtIdentity? parseScheduleIdentity(String body) {
  if (body.isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      ShuLog.w(ShuLogTag.jwxt, '教务课表数据 · 顶层不是 JSON 对象');
      return null;
    }
    final info = decoded['xsxx'];
    if (info is! Map) {
      // 学期参数错了正方也会回 200 + 一份没有 `xsxx` 的课表，所以这里
      // 把实际拿到的键名打出来 —— 否则只能看到一句「没解出身份信息」。
      ShuLog.w(
        ShuLogTag.jwxt,
        '教务课表数据 · 没有 xsxx 块 · 实际键 '
        '${decoded.keys.take(12).join(", ")}',
      );
      return null;
    }
    final identity = ShuJwxtIdentity(
      name: _text(info['XM']),
      studentId: _text(info['XH']),
      className: _text(info['BJMC']),
    );
    return identity.isEmpty ? null : identity;
  } on FormatException {
    // 会话失效时正方会回一段 HTML 或空体，不是 JSON。
    return null;
  }
}

/// 课表页里读到的学期编码。
///
/// 两个值就是课表查询表单里的 `xnm` / `xqm`，**必须**原样回填给数据接口。
/// 空串会让正方回一份没有 `xsxx` 的课表 —— 服务端不报错，只是不给身份信息。
@immutable
class ShuJwxtTerm {
  const ShuJwxtTerm({required this.year, required this.term});

  /// 学年编码，例如 `2025`。
  final String year;

  /// 学期编码，例如 `12`（`12` 是第一学期，`3` 是第二学期）。
  final String term;

  bool get isEmpty => year.isEmpty || term.isEmpty;
}

/// 从课表查询页的 HTML 里解出 `xnm` / `xqm`。
///
/// 优先读 `<select id="xnm">` 里 `selected` 的 `<option value=…>`，
/// 读不到再退回同名 `<input value=…>` —— 教务系统两个模板都出现过。
ShuJwxtTerm parseScheduleTerm(String html) {
  if (html.isEmpty) return const ShuJwxtTerm(year: '', term: '');
  return ShuJwxtTerm(
    year: _selectedValue(html, 'xnm') ?? _inputValue(html, 'xnm') ?? '',
    term: _selectedValue(html, 'xqm') ?? _inputValue(html, 'xqm') ?? '',
  );
}

/// `<select id="…">` 里被选中的那个 `<option>` 的 `value`。
String? _selectedValue(String html, String id) {
  final select = RegExp(
    '<select[^>]*id=["\']$id["\'][^>]*>(.*?)</select>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html)?.group(1);
  if (select == null) return null;
  final option = RegExp(
    r'<option[^>]*\bselected\b[^>]*>.*?</option>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(select)?.group(0);
  if (option == null) return null;
  return RegExp(
    r'''\bvalue\s*=\s*["']([^"']*)["']''',
    caseSensitive: false,
  ).firstMatch(option)?.group(1);
}

/// `<input name="…">` 的 `value`。
String? _inputValue(String html, String name) {
  final input = RegExp(
    '<input[^>]*name=["\']$name["\'][^>]*>',
    caseSensitive: false,
  ).firstMatch(html)?.group(0);
  if (input == null) return null;
  return RegExp(
    r'''\bvalue\s*=\s*["']([^"']*)["']''',
    caseSensitive: false,
  ).firstMatch(input)?.group(1);
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 剥掉标签与实体，把一段 HTML 压成一行纯文本。
String _plainText(String? fragment) {
  if (fragment == null) return '';
  return fragment
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

final _headingPattern = RegExp(
  r'''class=["']media-heading["'][^>]*>(.*?)</h4>''',
  dotAll: true,
);

final _infoPattern = RegExp(r'<p[^>]*>(.*?)</p>', dotAll: true);

/// `2025级自动化` 里的 `2025级`。
final _gradePattern = RegExp(r'^(\d{4}级)');

/// 标题里可能出现的学号：纯数字段。
///
/// ⚠ 实测这个位置是**角色**（`学生`）而不是学号，所以它基本总是匹配不到 ——
/// 学号请用 [ShuJwxtIdentity.studentId]（课表接口的 `xsxx.XH`）。
/// 保留这个宽松匹配只为兼容「某些院系模板确实把学号写在标题里」的情况，
/// 所以不设长度下限。
final _studentIdPattern = RegExp(r'^\d+$');
