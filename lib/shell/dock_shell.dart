import 'package:flutter/material.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/account/account_center.dart';
import '../core/connection/connection_controller.dart';
import '../core/logging/shu_log.dart';
import 'floating_dock.dart';

/// Hosts the three dock destinations.
///
/// [StatefulNavigationShell] keeps one `Navigator` per branch and an
/// `IndexedStack` on top of them, so the connect page's live connector, SOCKS5
/// listener and log buffer survive every tab switch.
class DockShell extends StatefulWidget {
  const DockShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<DockShell> createState() => _DockShellState();
}

class _DockShellState extends State<DockShell> {
  @override
  void initState() {
    super.initState();
    // The controller must never touch BuildContext; the shell hands it the two
    // things that would otherwise force context into it: a code prompt and the
    // live unified-identity session that the aTrust OAuth path needs.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = context.read<ConnectionController>();
      controller.challengePrompt = _promptCode;
      final account = context.read<AccountCenter>();
      controller.ssoSessionProvider = () => account.authSession;
      ShuLog.d(
        ShuLogTag.conn,
        'dock shell 就绪 · 已注入验证码输入与统一认证会话提供者 · '
        '已登录=${account.signedIn}',
      );
      // 不再注入账号名：aTrust 这条链路是 OAuth2，网关不接收它。连接参数里的
      // `username` 只是一个满足 SDK 校验的占位值
      // （`ShuAuthConstants.oauthPlaceholderUsername`）。
      //
      // 这里**不做**任何凭据核对。以前每次启动都会静默重跑一轮交换，代价是
      // 一打开应用就发一串请求 —— 其中一项真的要建一次 aTrust 隧道。而用户
      // 大多只是来连隧道的，根本没打开过账户页。核对挪到账户页真正被打开时
      // （`AccountCenter.verifyIfStale`），结论则用磁盘快照先顶上。
    });
  }

  Future<String> _promptCode(String title, String message) async {
    final code = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CodeDialog(title: title, message: message),
    );
    if (code == null || code.trim().isEmpty) {
      throw SangforException(SangforErrorCode.cancelled, '用户取消了「$title」输入');
    }
    return code.trim();
  }

  void _onSelect(int index) {
    final shell = widget.navigationShell;
    final isCurrent = index == shell.currentIndex;

    // Tapping the middle item while already on the connect page is the same
    // gesture as the orb. From any other page it only navigates, so a stray tap
    // can never tear a working tunnel down.
    if (isCurrent && ShuTab.values[index] == ShuTab.connect) {
      context.read<ConnectionController>().toggle();
      return;
    }
    shell.goBranch(index, initialLocation: isCurrent);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Lets the frosted dock float over the scrolling content instead of
      // sitting on an opaque bar.
      extendBody: true,
      body: widget.navigationShell,
      bottomNavigationBar: FloatingDock(
        currentIndex: widget.navigationShell.currentIndex,
        onSelect: _onSelect,
      ),
    );
  }
}

/// Code entry dialog for SMS / TOTP challenges.
///
/// The [TextEditingController] lives in this widget's state rather than in the
/// caller: disposing it right after `showDialog` returns would run while the
/// route is still animating out, which trips an assertion in the framework.
class _CodeDialog extends StatefulWidget {
  const _CodeDialog({required this.title, required this.message});

  final String title;
  final String message;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.message.isNotEmpty) Text(widget.message),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '验证码'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
