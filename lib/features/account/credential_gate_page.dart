import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:provider/provider.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/account/account_center.dart';
import '../../widgets/shu_app_bar.dart';

/// 「正在完成登录」过渡页。
///
/// 结构逐项照搬 ShuYo 的 `WebVpnOAuthCompletionPage`，只有文案不一样（那边
/// 说的是教务系统，这里是校园服务）：
///
/// ```text
/// [顶栏]
///          ○ CircularProgressIndicator      ← 一个居中的进度圈
///          正在完成登录                      ← 18 / w600
///          正在获取凭据（1/3）                 ← 一行次级色状态文案
/// ```
///
/// 失败时把进度圈换成 `error_outline` 与一个「返回」，形状不变。
///
/// 存在的理由和那边一样：身份验证通过只是一半，真正耗时的是**向各个校园系统
/// 换凭据**。这一步必须有视觉交待，否则用户看到的是一个点了没反应的按钮。
///
/// ## 为什么把逐系统的勾去掉
///
/// 原先进度圈下面还有三行「教务系统 / OTP 令牌 / aTrust 隧道」带勾的小清单。
/// 两个原因让它不再是好东西：
///
/// 1. 那三行里有一个系统的**名字本身**是这个应用不该在界面上单独强调的东西，
///    而它换不换得到，在下一页的凭据矩阵里有更准的说法；
/// 2. 交换改成并发之后三行会同时转圈，「换到哪了」这个信息量降成了零 ——
///    真正有用的只剩「完成了几个」，而那个数已经在那行状态文案里了。
class ShuCredentialGate extends StatefulWidget {
  const ShuCredentialGate({
    super.key,
    required this.title,
    required this.acquire,
  });

  /// 顶栏标题，例如「上海大学校园账户」。
  final String title;

  /// 真正要跑的业务：换凭据。返回 false 表示一个系统都没换到。
  final Future<bool> Function() acquire;

  @override
  State<ShuCredentialGate> createState() => _ShuCredentialGateState();
}

class _ShuCredentialGateState extends State<ShuCredentialGate> {
  bool _started = false;
  bool _finished = false;
  bool _succeeded = false;
  String? _error;

  /// 兜底：凭据交换卡住时不能把用户永远锁在这一页。
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    _timeoutTimer = Timer(
      const Duration(seconds: 90),
      () => _fail('获取凭据超时，请检查网络后重新登录'),
    );
    try {
      final ok = await widget.acquire();
      if (!mounted) return;
      if (!ok) {
        _fail(_account.errorMessage ?? '凭据交换失败，请重新登录');
        return;
      }
      _timeoutTimer?.cancel();
      await _succeed();
    } on SangforException catch (error) {
      _fail(error.message);
    } on Object catch (error) {
      _fail('$error');
    }
  }

  AccountCenter get _account => context.read<AccountCenter>();

  /// 先让勾一个一个亮完，再关掉 —— 不然整个过渡页会一闪而过。
  Future<void> _succeed() async {
    if (!mounted || _finished) return;
    setState(() => _succeeded = true);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || _error != null) return;
    _finished = true;
    Navigator.of(context).pop(true);
  }

  void _fail(String message) {
    if (_finished || !mounted || _error != null) return;
    _finished = true;
    _timeoutTimer?.cancel();
    setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    // 进度文案由账户中心播报（「正在获取凭据（1/3）」）。
    final status = context.watch<AccountCenter>().progressLabel ?? '正在准备';
    return PopScope(
      // 交换进行中不许退出，否则回来会看见一个半死的凭据矩阵。
      canPop: _error != null,
      child: Scaffold(
        // 顶栏没有返回键：这一页在跑完之前本来就不该退，而一个点了没反应的
        // 箭头比没有箭头更让人困惑。失败之后退出的入口是下面那颗按钮。
        appBar: ShuAppBar(title: widget.title),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: _error == null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _succeeded
                          ? Icon(
                              Icons.check_circle,
                              size: 48,
                              color: colors.success,
                            )
                          : const CircularProgressIndicator(),
                      const SizedBox(height: 24),
                      Text(
                        _succeeded ? '校园服务已开通' : '正在完成登录',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _succeeded ? '可以开始连接了' : status,
                        textAlign: TextAlign.center,
                        style: ShuYoTextStyles.body(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 44, color: colors.danger),
                      const SizedBox(height: 18),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: ShuYoTextStyles.body(
                          color: colors.textPrimary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('返回'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
