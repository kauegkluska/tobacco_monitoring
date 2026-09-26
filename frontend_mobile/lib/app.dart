import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/api.dart';
import 'core/background.dart';
import 'core/discovery.dart';
import 'core/app_scope.dart';
import 'core/models.dart';
import 'core/prefs.dart';
import 'core/theme.dart';
import 'pages/login_page.dart';
import 'pages/shell.dart';
import 'widgets/common.dart';
import 'widgets/server_dialog.dart';

class TobaccoMonitorApp extends StatefulWidget {
  const TobaccoMonitorApp({this.api, this.prefs, super.key});

  /// Permite injetar dependências nos testes.
  final ApiClient? api;
  final AppPrefs? prefs;

  @override
  State<TobaccoMonitorApp> createState() => _TobaccoMonitorAppState();
}

enum _Session { loading, signedOut, signedIn, serverDown }

class _TobaccoMonitorAppState extends State<TobaccoMonitorApp> {
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final ApiClient api = widget.api ?? ApiClient();
  late final AppPrefs prefs = widget.prefs ?? AppPrefs();
  _Session session = _Session.loading;
  String? startupError;

  @override
  void initState() {
    super.initState();
    api.onSessionExpired = _onSessionExpired;
    _start();
  }

  Future<void> _start() async {
    setState(() => session = _Session.loading);
    await Future.wait([api.load(), prefs.load()]);
    if (!api.isAuthenticated) {
      setState(() => session = _Session.signedOut);
      return;
    }
    try {
      UserProfile.fromJson(await api.get('/users/me') as Map<String, dynamic>);
      if (mounted) _signedIn();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        startupError = error.message;
        session = error.status == 401 ? _Session.signedOut : _Session.serverDown;
      });
    }
  }

  void _signedIn() {
    setState(() => session = _Session.signedIn);
    // Retoma os avisos com o app fechado, se o usuário os ativou.
    BackgroundMonitor.sync(prefs, signedIn: true);
  }

  void _onSessionExpired() {
    if (session != _Session.signedIn) return;
    BackgroundMonitor.stop();
    // Fecha formulários e diálogos abertos antes de voltar para o login.
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
    setState(() => session = _Session.signedOut);
    messengerKey.currentState?.showSnackBar(const SnackBar(content: Text('Sua sessão expirou. Entre novamente.')));
  }

  /// O computador pode ter ganhado outro IP: procura o servidor na rede e tenta de novo.
  Future<void> _discoverServer() async {
    final previous = api.baseUrl;
    final found = await discoverAndSave(api);
    if (!mounted) return;
    if (found == null) {
      messengerKey.currentState?.showSnackBar(const SnackBar(
        content: Text('Nenhum servidor encontrado na rede. Confira se o backend está ligado e se o celular está no mesmo Wi-Fi.'),
      ));
      return;
    }
    if (found != previous) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text('Servidor encontrado em ${Uri.parse(found).authority}.')));
    }
    await _start();
  }

  Future<void> _logout() async {
    await BackgroundMonitor.stop();
    await api.logout();
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
    if (mounted) setState(() => session = _Session.signedOut);
  }

  Widget _home() {
    return switch (session) {
      _Session.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
      _Session.signedOut => LoginPage(onAuthenticated: _signedIn),
      _Session.signedIn => HomeShell(onLogout: _logout),
      _Session.serverDown => _ServerDownPage(
          message: startupError ?? 'Servidor indisponível.',
          onRetry: _start,
          onChangeServer: () => setState(() => session = _Session.signedOut),
          onDiscover: discoverySupported ? _discoverServer : null,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      api: api,
      prefs: prefs,
      child: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => MaterialApp(
          title: 'Monitor de Estufa',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: messengerKey,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: prefs.themeMode,
          locale: const Locale('pt', 'BR'),
          supportedLocales: const [Locale('pt', 'BR')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: _home(),
        ),
      ),
    );
  }
}

class _ServerDownPage extends StatelessWidget {
  const _ServerDownPage({required this.message, required this.onRetry, required this.onChangeServer, this.onDiscover});

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onChangeServer;
  final Future<void> Function()? onDiscover;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off, size: 56, color: context.colors.muted),
                const SizedBox(height: 14),
                Text('Servidor indisponível', style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center, style: TextStyle(color: context.colors.textSecondary)),
                const SizedBox(height: 20),
                FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Tentar de novo')),
                if (onDiscover != null) ...[
                  const SizedBox(height: 8),
                  BusyButton(label: 'Procurar servidor na rede', icon: Icons.wifi_find, style: BusyButtonStyle.outlined, onPressed: onDiscover!),
                ],
                const SizedBox(height: 8),
                TextButton(onPressed: onChangeServer, child: const Text('Alterar servidor')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
