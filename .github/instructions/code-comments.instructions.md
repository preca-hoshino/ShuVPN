---
description: "Use when writing, editing, or reviewing comments in source code: which comments to write, where they belong, and the required tone and format for doc comments (`///`), implementation comments (`//`), and TODOs. Minimal, professional comments based on Effective Dart, the Google style guides, and .NET conventions — no narration, no filler, no restating code, no commented-out code."
applyTo: "**"
---

# 代码注释规范

先假定不写。删掉它会让后来的人做错事，才写。
依据 Effective Dart: Documentation、Google C++ Style Guide 的 Comments、.NET 编码约定。

## 该写的四类

- 不变量与前置条件：调用顺序、必须成对出现的调用。
- 反直觉的写法：魔数、看似多余的判断、删掉就会坏的原因。
- 外部约束：平台 API 行为、上游 SDK 的坑、协议字节布局。
- 取舍与代价：为什么不用更显然的方案。

能改代码就不写注释，优先用具名常量、enum、具名参数、可空类型。

## 不写的

- 复述代码：`i++; // 自增`、`// 遍历列表`、给每条语句配一句说明。
- 与上下文重复：把类名、参数名、签名再解释一遍。
- 变更日志：`// 改成…`、`// 新增…`、`// 第 N 次更新`。历史归 git。
- 分区横幅、被注释掉的死代码、空 TODO。
- 装饰：`⚠️`、`✅`、`-->`、强调用的 `**`。
- 真实姓名、学号、口令、Cookie、device id。示例用 `张三` / `25123456` / `example.com`。

## 两类注释

|      | 文档注释 `///`                      | 实现注释 `//`        |
| :--- | :---------------------------------- | :------------------- |
| 位置 | 声明之前，注解之前                  | 被解释的那段代码上方 |
| 回答 | 这个成员是什么、怎么用              | 这里为什么这么做     |
| 开头 | 第三人称动词 / 名词短语 / `Whether` | 陈述句               |

覆盖方法只写覆盖特有的部分，构造函数不写「构造本对象」。getter 与 setter 只写一处。
私有成员不必逐条写文档，调用方看不懂时才补。

## 文档注释

```dart
/// 删除 [path] 指向的文件。
///
/// 文件不存在时抛 [IOError]，存在但无权限时抛 [PermissionError]。
void delete(String path) { ... }
```

- 首句是一句话摘要，单独成段。`dart doc` 拿它当列表短摘要。
- 有副作用的用第三人称动词，是属性的用名词短语，布尔用 `Whether`。
- 参数、返回值、异常用散文写，不写 `@param`。
- 用 `[方括号]` 引用同作用域标识符。
- 不重复上下文：类名、签名、父类都在眼前。

## 句子与格式

- 按句子写：首字母大写、句末句号。含行内注释与 TODO。
- 一句话一件事。不用语气词（「其实」「居然」「压根」）、感叹号、自问自答。
- 不出现「我们 / 你」。
- 行内注释放在被解释的那一行上方，不贴行尾；注释符后留一个空格。
- 长解释用 `///` 加空行分段，不用 `/* */`。
- 需要大段散文才说得清的，那是文档该收的东西，不堆在代码里。

## 触及即清理

改到哪一块，就清理那一块的复述型与口水型注释，只删口水不删结论。外部约束、出处、
代价先落到代码或一条新注释里再删原句。边界是本次改动触及的函数/类，不跨范围扫射，
不为改注释扩大 diff。

## 对照

```dart
// 错：复述加口水。
// 这里我们把设置里的等级装到日志上，因为如果不提前装的话后面可能就会有问题
ShuLog.instance.configure(level: level);

// 对：只写代价。
/// 必须早于任何一条日志写入。缓冲区按写入时的阈值丢弃记录，装晚了会把
/// 启动阶段的日志永久丢掉。
ShuLog.instance.configure(level: level);

// 错：参数含义靠注释解释。
calculate(values, 7, false);

// 对：让调用点自明。
calculate(values, precision: 7, useCache: false);
```
