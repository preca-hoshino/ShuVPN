import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/account/account_center.dart';
import '../../core/auth/native_auth_service.dart';
import '../../core/auth/wecom_auth_service.dart';

/// 企业微信扫码登录等待页。
///
/// 结构照搬 ShuYo 的 `WeComScanPage`：展示二维码，支持点击拉起企业微信
/// 确认页；后台长轮询等待扫码，成功后把会话交回 [AccountCenter]。
///
/// 与 ShuYo 的差别只有一处：ShuYo 把换来的 Cookie 交给登录页自己装进
/// WebView，这里直接交给账户中心 —— 后面向三个系统换取授权码要用同一个
/// `SHU_OAUTH2` 会话。
class WeComScanPage extends StatefulWidget {
  const WeComScanPage({super.key});

  @override
  State<WeComScanPage> createState() => _WeComScanPageState();
}

class _WeComScanPageState extends State<WeComScanPage> {
  final _service = ShuWeComAuthService();

  ShuWeComQrSession? _session;
  ShuWeComScanStatus _status = ShuWeComScanStatus.waiting;
  bool _busy = true;
  bool _launchingLink = false;
  bool _cancelled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    // 页面被销毁时取消后台长轮询，避免在后台继续发起网络请求。
    _cancelled = true;
    _service.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final session = await _service.startQrSession();
      if (!mounted) return;
      setState(() {
        _session = session;
        _busy = false;
      });
      unawaited(_waitForScan(session.key));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is ShuAuthException ? error.message : '无法连接企业微信服务，请稍后再试';
      });
    }
  }

  /// 后台长轮询，状态变化时刷新界面，成功后换取目标业务系统回调地址。
  Future<void> _waitForScan(String key) async {
    final result = await _service.waitForScan(
      key,
      isCancelled: () => _cancelled,
      onStatusChanged: (status) {
        if (mounted && status != _status) {
          setState(() => _status = status);
        }
      },
    );
    if (!mounted) return;
    if (!result.isSuccess) {
      setState(() => _error = '二维码已过期或已取消，请重新尝试');
      return;
    }
    try {
      final session = await _service.redeem(
        result.authCode!,
        ShuWeComAuthService.weComRedeemState,
      );
      if (!mounted) return;
      setState(() => _status = ShuWeComScanStatus.succeeded);
      _busy = true;
      // 扫码换到的只是 SSO 会话；三个业务系统还要一个一个去换。
      final account = context.read<AccountCenter>();
      final adopted = await account.adoptWeComSession(
        cookies: session.sessionCookies,
        username: '',
      );
      if (!mounted) return;
      if (!adopted) {
        setState(() {
          _busy = false;
          _error = account.errorMessage ?? '企业微信登录失败';
        });
        return;
      }
      // 只做到这一步：扫码换到的是 SSO 会话，凭据交换交给调用方（登录表单）
      // 统一做。这里再跑一遍会变成两次完整的交换。
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is ShuAuthException ? error.message : '企业微信授权失败，请重新尝试';
      });
    }
  }

  /// 调用系统打开 wxwork:// scheme（或复制链接）。
  Future<void> _openWeCom() async {
    final session = _session;
    if (session == null || _launchingLink) return;
    setState(() => _launchingLink = true);
    try {
      final ok = await launchUrl(
        Uri.parse(session.wxWorkSchemeUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        await Clipboard.setData(ClipboardData(text: session.confirmUrl));
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法打开企业微信，已复制链接，请手动打开')));
        }
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开企业微信，请手动打开企业微信')));
      }
    } finally {
      if (mounted) setState(() => _launchingLink = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        title: const Text('企业微信登录'),
        // 这是压在登录表单上的一层，左上角应当是「返回上一步」而不是关闭。
        leading: IconButton(
          tooltip: '返回',
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                '使用企业微信扫一扫',
                style: ShuYoTextStyles.title(color: colors.textPrimary),
              ),
              const SizedBox(height: 12),
              Text(
                '打开手机企业微信，点击右上角扫码，或点击下方按钮直接唤起企业微信。',
                textAlign: TextAlign.center,
                style: ShuYoTextStyles.body(color: colors.textSecondary),
              ),
              const SizedBox(height: 24),
              if (_busy)
                const SizedBox.square(
                  dimension: 220,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_session != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(ShuRadii.tile),
                  child: Container(
                    width: 220,
                    height: 220,
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: Image.network(
                      _session!.qrImageUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          const Center(
                            child: Icon(Icons.broken_image_outlined, size: 48),
                          ),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              if (_error != null)
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: ShuYoTextStyles.body(color: colors.danger),
                )
              else
                _statusWidget(colors),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _launchingLink ? null : _openWeCom,
                icon: const Icon(Icons.open_in_new),
                label: const Text('打开企业微信登录'),
              ),
              const SizedBox(height: 8),
              Text(
                '扫码确认后请返回本应用',
                style: ShuYoTextStyles.meta(color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusWidget(ShuYoColors colors) {
    final (text, icon) = switch (_status) {
      ShuWeComScanStatus.waiting => ('等待扫码…', Icons.schedule),
      ShuWeComScanStatus.confirmedPending => ('已扫码，请在手机企业微信确认', Icons.android),
      ShuWeComScanStatus.succeeded => ('登录成功', Icons.check_circle),
      ShuWeComScanStatus.expired => ('二维码已过期', Icons.error_outline),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: colors.accent),
        const SizedBox(width: 8),
        Text(text, style: ShuYoTextStyles.label(color: colors.accent)),
      ],
    );
  }
}
