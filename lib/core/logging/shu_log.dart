import 'package:flutter/foundation.dart';

/// 日志等级。
///
/// **声明顺序即严重度**：[index] 越小越严重。这条不变量是整个过滤逻辑的
/// 基础 —— 「是否记录」判的是 `level.index <= 当前阈值.index`，
/// 所以往这个枚举里加东西时只能加在正确的一档上，不能随手追加在末尾。
///
/// 四个档位不是随意取的，它们是「一条日志该不该被看见」的四层：
///
/// * [error] —— 用户已经失败了。`_fail()` 与所有 `on ... catch` 的结论走这一档。
/// * [warn] —— 出了问题但被兜住了（会话读不出来按未登录处理、档案读不到
///   就不显示）。这些是**吞掉的异常**，不记下来就永远查不到。
/// * [info] —— 一条流程的生命周期（登录开始、换完一个系统、隧道建立）。
///   出厂默认档，也是「把应用跑一遍就能看懂发生了什么」那一档。
/// * [debug] —— 排障细节：每一跳 HTTP、每个字段的值、每个状态机的转折。
///   量大且含内部结构，只在真的要查问题时才开。
///
/// ## 用语规范（对每一个调用点生效，不是建议）
///
/// 日志是**给排障的人读的仪器输出**，不是随笔。规则：
///
/// 1. **陈述句，不加语气。** 不写“居然”“其实”“压根”“白烧”“就是”，
///    不写感叹号。一句话说完一件事就结束。
/// 2. **不解释，只描述。** 原因属于注释和界面上的提示；日志里写的是
///    「发生了什么」。要写原因时写成一条事实：`被服务端拒绝 code 10000004`。
/// 3. **不用装饰符号。** 不写 `⚠️`、`**强调**`、`—— 分隔线 ——`。
///    分隔符只用 `·`（同一行内）和 `\n`（多行）。
/// 4. **不用括号补充。** 补充说明另起一句或写进注释。唯一例外是
///    「单位 / 类型」这种缩写展开：`（TLS 120 ms）` 这种写法不要，
///    写成 `TLS 120 ms`。
/// 5. **单位与量纲写全。** `1.2 KB`、`120 ms`、`3.1s`、`12 条`。
/// 6. **同一件事只有一个说法。** 见各 tag 的常量定义，不要另造同义词。
///
/// ## 网络包（数据面）
///
/// 逐包与逐连接的输出向 Clash 的连接日志看齐，行头固定是
/// `[协议] 源 --> 目的`，后面跟「匹配到了什么 + 结果」：
///
/// | 等级 | 内容 |
/// | :--- | :--- |
/// | `ERROR` | 发送失败 |
/// | `WARN` | 注定被丢弃：资源表外、TCP 走不了 L3、畸形包、IPv6 |
/// | `INFO` | 每条连接一行建立 + 一行收尾（含字节数与时长） |
/// | `DEBUG` | 逐个包一行（含长度与 TCP 标志） |
///
/// **任何等级都不打原始字节转储**（hex dump）—— 它既读不出结论，又会把
/// 缓冲区的容量换成噪音。
enum ShuLogLevel {
  error('ERROR'),
  warn('WARN'),
  info('INFO'),
  debug('DEBUG');

  const ShuLogLevel(this.label);

  /// 显示用的名字，也是磁盘上存的名字。
  final String label;

  /// 从磁盘读回来。读不到或认不出时按 [ShuLogLevel.info] 处理 ——
  /// 一个不认识的字符串不该让设置页起不来，也不该悄悄变成「全部记录」。
  static ShuLogLevel fromName(String? name) {
    for (final level in ShuLogLevel.values) {
      if (level.label == name || level.name == name) return level;
    }
    return ShuLogLevel.info;
  }
}

/// 一条日志。
///
/// 时间用**本地时钟的墙上时间**而不是单调时钟：这份记录是给人读的，
/// 用户要拿它去和别的系统（网关、教务）的日志对时。
@immutable
class ShuLogRecord {
  const ShuLogRecord({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime time;
  final ShuLogLevel level;

  /// 来源标签（`auth` / `conn` / `jwxt` …）。
  ///
  /// 用字符串而不是枚举：日志的调用点在 `core/` 的十几个文件里，一个枚举
  /// 意味着每加一处来源都要回来改这个文件；而字符串的代价只是拼错，
  /// 拼错的后果也只是这一行的标签不好找。
  final String tag;

  final String message;

  String get timeLabel {
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${three(time.millisecond)}';
  }

  /// 正文的起始列。
  ///
  /// 长度恒定，所以多行消息的续行可以缩进到这里，一眼能看出它们是**同一条**
  /// 记录的一部分（证书指纹不匹配那条就是这么打印的：三行一组）。
  String get _prefix => '$timeLabel ${level.label.padRight(5)} [$tag] ';

  /// 界面上按行渲染、复制到剪贴板时按行拼接。
  ///
  /// 返回列表而不是单个字符串：日志框里每一行都要能独立换行、独立着色，
  /// 交给 `Text` 自己去断行的话，长行会被按宽度折断成看起来像是新记录的
  /// 样子。
  List<String> formatLines() {
    final parts = message.split('\n');
    return <String>[
      '$_prefix${parts.first}',
      for (final line in parts.skip(1)) '${' ' * _prefix.length}$line',
    ];
  }

  /// 复制 / 写控制台用的完整文本。
  String format() => formatLines().join('\n');
}

/// 全应用唯一的日志缓冲区。
///
/// ## 为什么是单例
///
/// 日志的调用点分布在 `lib/core/` 的十几个文件里（认证链、凭据交换、教务
/// 解析、隧道控制），它们**全都没有 `BuildContext`**，也不该为了记一行日志
/// 就凭空多出一个构造参数。参考实现（`ShuYo` 走 logger 包）同样是全局取用。
/// 单例的代价是测试里要显式重置，这一点在 `test/log_test.dart` 里处理。
///
/// ## 与 `debugPrint` 的关系
///
/// 两者**不是替代关系**：
///
/// * 缓冲区是给**用户**看的（设置 → 日志），要在应用里、要能复制、要能清空；
/// * `debugPrint` 是给**开发者**看的（`flutter run` 的控制台、`flutter logs`）。
///
/// 真机上的问题几乎都发生在「开发者不在电脑前」的时候，那时控制台是空的，
/// 只有缓冲区里那份还在。所以 Debug 构建下两者都写，Release 构建只写缓冲区。
///
/// ## 过滤时机
///
/// 等级在**写入时**丢弃：低于当前阈值的记录根本不进缓冲区。这样缓冲区里
/// 每一条都是「此刻的等级愿意看的」，不会被 DEBUG 的噪音挤掉有用的 ERROR。
/// 代价是把等级调低之后看不到之前的历史 —— 这是刻意的取舍。
class ShuLog extends ChangeNotifier {
  ShuLog._();

  /// 进程内唯一实例。
  static final ShuLog instance = ShuLog._();

  /// 缓冲区上限。
  ///
  /// 「一屏能翻完 + 一次完整登录的所有细节都装得下」的量级：一次登录大约
  /// 产生 60～120 行，一次连接再加 30 行左右。后来 VPN 数据面接进来，
  /// DEBUG 档下每一条流还要再占两三行，500 条会在十几条连接之后就开始
  /// 擦掉排障开头那一段，所以放宽到 1000。
  static const int maxRecords = 1000;

  bool _enabled = false;
  ShuLogLevel _level = ShuLogLevel.info;

  final List<ShuLogRecord> _records = <ShuLogRecord>[];

  /// 用户是否打开了日志。
  bool get enabled => _enabled;

  /// 当前的等级阈值。
  ShuLogLevel get level => _level;

  List<ShuLogRecord> get records => List<ShuLogRecord>.unmodifiable(_records);

  int get length => _records.length;

  bool get isEmpty => _records.isEmpty;

  /// 复制到剪贴板的整段文本，一条物理行一项。
  List<String> get lines => <String>[
    for (final record in _records) ...record.formatLines(),
  ];

  /// 由 [SettingsStore] 在启动时、以及两个设置项的 setter 里调用。
  ///
  /// 关掉开关**不清空**已记录的内容：用户拨一下开关只是想让它别再增长，
  /// 顺手把刚才那份排障现场擦掉是另一件事（要清空有 AppBar 上那个按钮）。
  void configure({bool? enabled, ShuLogLevel? level}) {
    final nextEnabled = enabled ?? _enabled;
    final nextLevel = level ?? _level;
    if (nextEnabled == _enabled && nextLevel == _level) return;
    _enabled = nextEnabled;
    _level = nextLevel;
    notifyListeners();
  }

  /// 这个等级现在会被记录吗。
  ///
  /// 存在的唯一理由是**热路径**：VPN 数据面上每秒可能有上千个包，
  /// 拼一个字符串再被 [add] 丢掉，白烧的 CPU 与内存是实打实的。
  /// 逐包日志的调用点必须先问这一句再拼。
  bool allows(ShuLogLevel level) => _enabled && level.index <= _level.index;

  /// 记一条。
  ///
  /// 关掉时连同 `debugPrint` 一起跳过 —— 一个「关了还在刷控制台」的开关
  /// 等于没关。
  void add(ShuLogLevel level, String tag, String message) {
    if (!_enabled) return;
    if (level.index > _level.index) return;
    final record = ShuLogRecord(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );
    _records.add(record);
    final overflow = _records.length - maxRecords;
    if (overflow > 0) _records.removeRange(0, overflow);
    if (kDebugMode) debugPrint(record.format());
    notifyListeners();
  }

  void clear() {
    if (_records.isEmpty) return;
    _records.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------- 快捷方式
  //
  // 调用点写 `ShuLog.w('jwxt', '…')` 就够，不必每次把枚举写全。

  static void e(String tag, String message) =>
      instance.add(ShuLogLevel.error, tag, message);

  static void w(String tag, String message) =>
      instance.add(ShuLogLevel.warn, tag, message);

  static void i(String tag, String message) =>
      instance.add(ShuLogLevel.info, tag, message);

  static void d(String tag, String message) =>
      instance.add(ShuLogLevel.debug, tag, message);
}

/// 日志来源标签的统一写法。
///
/// 写在一处是为了**同一件事只有一个名字**：教务系统叫 `jwxt` 就叫到底，
/// 不要在 A 文件里叫 `jwxt`、B 文件里叫 `academic` —— 那样按标签过滤
/// 会漏掉一半。
abstract final class ShuLogTag {
  const ShuLogTag._();

  /// 统一身份认证（登录、两步验证、WebView Cookie）。
  static const auth = 'auth';

  /// aTrust 网关的 OAuth2 / 认证链。
  static const atrust = 'atrust';

  /// 动态口令。
  static const otp = 'otp';

  /// 教务系统（凭据交换、档案、课表身份）。
  static const jwxt = 'jwxt';

  /// 账户层（登录事务、快照、并发交换）。
  static const account = 'account';

  /// 连接与隧道。
  static const conn = 'conn';

  /// Android `VpnService`。
  static const vpn = 'vpn';

  /// VPN 数据面上的**逐个包**：去了哪、命中哪条资源、结果如何。
  ///
  /// 单独一档而不并进 `vpn`：数据面的行数比控制面多几个数量级，
  /// 混在一起会把「建接口、下发路由」这些一次性的关键事件淹掉。
  static const packet = 'packet';

  /// 本机 SOCKS5 代理。
  static const proxy = 'proxy';

  /// 设置。
  static const settings = 'settings';
}

/// 脱敏：只留首尾各 [keep] 个字符。
///
/// 它存在的唯一理由是**不把凭据写进日志或被复制出去的文本**。sid、ticket、
/// 设备号、账号名都不需要（也不应该）以原样出现在任何一份会离开设备的
/// 字符串里；而在排查时「它长什么样、有没有拿到」又确实有用，所以留首尾。
///
/// 太短的值直接整体打掉：`keep * 2` 以下时首尾已经拼回原值了。
String mask(String value, [int keep = 4]) {
  if (value.length <= keep * 2) return '••••';
  return '${value.substring(0, keep)}••••'
      '${value.substring(value.length - keep)}';
}
