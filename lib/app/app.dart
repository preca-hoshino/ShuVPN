import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/account/account_center.dart';
import '../core/connection/connection_controller.dart';
import '../core/connection/protocol.dart';
import '../core/settings/settings_store.dart';
import 'app_info.dart';
import 'router.dart';
import 'theme.dart';

/// Root widget.
///
/// It owns the three long-lived objects of the app — settings, the connection
/// controller and the account center — and nothing else. Screens read them
/// through `provider`; no screen owns connection state of its own.
class ShuVpnApp extends StatefulWidget {
  const ShuVpnApp({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<ShuVpnApp> createState() => _ShuVpnAppState();
}

class _ShuVpnAppState extends State<ShuVpnApp> {
  /// Built once per app so navigation state cannot leak between instances.
  late final GoRouter _router = createShuRouter();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsStore>.value(value: widget.settings),
        ChangeNotifierProvider<ConnectionController>(
          create: (_) => ConnectionController(
            widget.settings,
            draft: _draft(widget.settings),
          ),
        ),
        ChangeNotifierProvider<AccountCenter>(
          create: (_) =>
              createAccountCenter(preferences: widget.settings.preferences),
        ),
      ],
      child: Consumer<SettingsStore>(
        builder: (context, settings, _) => MaterialApp.router(
          title: ShuAppInfo.name,
          debugShowCheckedModeBanner: false,
          theme: buildShuTheme(Brightness.light),
          darkTheme: buildShuTheme(Brightness.dark),
          themeMode: settings.themeMode,
          routerConfig: _router,
        ),
      ),
    );
  }
}

/// Restores the endpoint so the button is usable straight after a cold start.
///
/// There is only one gateway now, so this is no longer a "which stack" question
/// — it just reads back the host the user last used, and the protocol the user
/// last had enabled.
ConnectionDraft _draft(SettingsStore settings) {
  return ConnectionDraft(
    protocol: settings.firstEnabledProtocol ?? ShuProtocol.atrust,
    server: settings.server,
    loginDomain: settings.loginDomain,
  );
}
