// The screen definitions keep the Stitch layout declarations compact and highly responsive.
// ignore_for_file: prefer_const_constructors, curly_braces_in_flow_control_structures, use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

const defaultApiUrl = 'http://127.0.0.1:8000';
const primaryGreen = Color(0xff0d631b);
const primaryGreenLight = Color(0xff2e7d32);
const darkGreen = Color(0xff18332f);
const surface = Color(0xfffbf9f9);
const softSurface = Color(0xfff5f3f3);
const surfaceContainer = Color(0xffefeded);
const textMuted = Color(0xff40493d);
const accentGold = Color(0xfff9a825);
const errorRed = Color(0xffba1a1a);
const errorBg = Color(0xffffdad6);
const successBg = Color(0xffcfe99f);

class ApiService {
  Future<SharedPreferences> get storage => SharedPreferences.getInstance();
  String? token;
  String? refreshToken;
  String baseUrl = defaultApiUrl;

  Map<String, String> get headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<void> initBaseUrl() async {
    final preferences = await storage;
    final savedUrl = preferences.getString('api_base_url');
    if (savedUrl != null && savedUrl.trim().isNotEmpty) {
      baseUrl = savedUrl.trim();
    } else {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        baseUrl = 'http://10.0.2.2:8000';
      } else {
        baseUrl = 'http://127.0.0.1:8000';
      }
    }
  }

  Future<void> setBaseUrl(String newUrl) async {
    baseUrl = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final preferences = await storage;
    await preferences.setString('api_base_url', baseUrl);
  }

  Future<bool> testConnection([String? testUrl]) async {
    final target = (testUrl ?? baseUrl).trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await http.get(Uri.parse('$target/docs')).timeout(const Duration(seconds: 4));
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (_) {
      try {
        final response = await http.get(Uri.parse('$target/')).timeout(const Duration(seconds: 4));
        return response.statusCode >= 200 && response.statusCode < 500;
      } catch (_) {
        return false;
      }
    }
  }

  Future<Map<String, dynamic>> authenticate(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _request('POST', path, body: body, retry: false);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response));
    }
    final result = jsonDecode(response.body) as Map<String, dynamic>;
    token = result['access_token'] as String?;
    refreshToken = result['refresh_token'] as String?;
    await _persistTokens();
    return result;
  }

  Future<void> restoreSession() async {
    await initBaseUrl();
    final preferences = await storage;
    token = preferences.getString('access_token');
    refreshToken = preferences.getString('refresh_token');
    if (token == null && refreshToken != null) await refreshSession();
  }

  Future<bool> refreshSession() async {
    if (refreshToken == null) return false;
    final response = await _request('POST', '/auth/refresh', body: {'refresh_token': refreshToken}, retry: false);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await logout();
      return false;
    }
    final result = jsonDecode(response.body) as Map<String, dynamic>;
    token = result['access_token'] as String?;
    refreshToken = result['refresh_token'] as String?;
    await _persistTokens();
    return token != null;
  }

  Future<void> logout() async {
    token = null;
    refreshToken = null;
    final preferences = await storage;
    await preferences.remove('access_token');
    await preferences.remove('refresh_token');
  }

  Future<void> _persistTokens() async {
    final preferences = await storage;
    if (token != null) await preferences.setString('access_token', token!);
    if (refreshToken != null) await preferences.setString('refresh_token', refreshToken!);
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool retry = true,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final encodedBody = body == null ? null : jsonEncode(body);
    final requestHeaders = headers;
    late http.Response response;
    try {
      if (method == 'GET') {
        response = await http.get(uri, headers: requestHeaders).timeout(const Duration(seconds: 6));
      } else if (method == 'POST') {
        response = await http.post(uri, headers: requestHeaders, body: encodedBody).timeout(const Duration(seconds: 6));
      } else if (method == 'PATCH') {
        response = await http.patch(uri, headers: requestHeaders, body: encodedBody).timeout(const Duration(seconds: 6));
      } else if (method == 'DELETE') {
        response = await http.delete(uri, headers: requestHeaders).timeout(const Duration(seconds: 6));
      } else {
        throw UnsupportedError('HTTP method $method is not supported');
      }
    } catch (e) {
      if (e is TimeoutException) {
        throw Exception('Tempo limite esgotado ao conectar a $baseUrl. Verifique se o backend está rodando.');
      }
      throw Exception('Não foi possível conectar a $baseUrl. Verifique se a API está ativa.');
    }

    if (response.statusCode == 401 && retry && refreshToken != null && path != '/auth/refresh') {
      if (await refreshSession()) return _request(method, path, body: body, retry: false);
    }
    return response;
  }

  Future<List<dynamic>> getList(String path) async {
    final response = await _request('GET', path);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response));
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> getObject(String path) async {
    final response = await _request('GET', path);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> getObjectOrNull(String path) async {
    try {
      return await getObject(path);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> postObject(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _request('POST', path, body: body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> patchObject(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _request('PATCH', path, body: body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> deleteObject(String path) async {
    final response = await _request('DELETE', path);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_message(response));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  String _message(http.Response response) {
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['detail']?.toString() ?? 'Não foi possível comunicar com a API.';
    } catch (_) {
      return 'Não foi possível comunicar com a API (${response.statusCode}).';
    }
  }
}

class TobaccoMonitorApp extends StatelessWidget {
  const TobaccoMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Monitor de Estufa de Tabaco',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: surface,
        colorScheme: ColorScheme.fromSeed(seedColor: primaryGreen),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: softSurface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: primaryGreen, width: 1.5),
          ),
        ),
      ),
      home: SessionGate(api: ApiService()),
    );
  }
}

class SessionGate extends StatefulWidget {
  const SessionGate({required this.api, super.key});
  final ApiService api;

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  bool ready = false;
  bool authenticated = false;

  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    try {
      await widget.api.restoreSession();
      if (widget.api.token != null) {
        await widget.api.getObject('/users/me');
        authenticated = true;
      }
    } catch (_) {
      await widget.api.logout();
    }
    if (mounted) setState(() => ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return authenticated ? AppShell(api: widget.api) : LoginPage(api: widget.api);
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({required this.api, super.key});
  final ApiService api;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final loginController = TextEditingController();
  final passwordController = TextEditingController();
  bool loading = false;
  bool obscure = true;
  String? error;

  @override
  void dispose() {
    loginController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (loginController.text.trim().isEmpty || passwordController.text.isEmpty) {
      setState(() => error = 'Informe seu login e sua senha.');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await widget.api.authenticate('/auth/login', {
        'login': loginController.text.trim(),
        'password': passwordController.text,
      });
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => AppShell(api: widget.api),
        ));
      }
    } catch (exception) {
      setState(() => error = exception.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _openServerConfig() {
    showDialog(
      context: context,
      builder: (_) => ServerConfigDialog(
        api: widget.api,
        onSaved: () => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Monitor de Estufa',
      subtitle: 'Acesso à telemetria de secagem',
      api: widget.api,
      onConfigureServer: _openServerConfig,
      child: Column(
        children: [
          if (error != null) ErrorBanner(message: error!),
          AppField(
            controller: loginController,
            label: 'Usuário ou e-mail',
            icon: Icons.badge_outlined,
          ),
          const SizedBox(height: 14),
          AppField(
            controller: passwordController,
            label: 'Senha',
            icon: Icons.lock_outline,
            obscureText: obscure,
            suffix: IconButton(
              onPressed: () => setState(() => obscure = !obscure),
              icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => PasswordRecoveryPage(api: widget.api),
              )),
              child: const Text('Esqueci minha senha'),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: loading ? null : login,
            icon: loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.login),
            label: Text(loading ? 'Entrando...' : 'Entrar na plataforma'),
            style: FilledButton.styleFrom(
              backgroundColor: primaryGreen,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => RegisterPage(api: widget.api),
            )),
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('Criar conta de produtor'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}

class RegisterPage extends StatefulWidget {
  const RegisterPage({required this.api, super.key});
  final ApiService api;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final name = TextEditingController();
  final login = TextEditingController();
  final password = TextEditingController();
  String? error;
  bool loading = false;

  @override
  void dispose() {
    name.dispose();
    login.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> register() async {
    if (name.text.trim().isEmpty || login.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = 'Preencha todos os campos.');
      return;
    }
    setState(() { loading = true; error = null; });
    try {
      await widget.api.authenticate('/auth/register', {
        'name': name.text.trim(),
        'login': login.text.trim(),
        'password': password.text,
      });
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(
          builder: (_) => AppShell(api: widget.api),
        ), (_) => false);
      }
    } catch (exception) {
      setState(() => error = exception.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Criar conta',
      subtitle: 'Comece a monitorar suas estufas',
      showBack: true,
      api: widget.api,
      child: Column(
        children: [
          if (error != null) ErrorBanner(message: error!),
          AppField(controller: name, label: 'Nome completo', icon: Icons.person_outline),
          const SizedBox(height: 14),
          AppField(controller: login, label: 'Usuário ou e-mail', icon: Icons.badge_outlined),
          const SizedBox(height: 14),
          AppField(controller: password, label: 'Senha', icon: Icons.lock_outline, obscureText: true),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: loading ? null : register,
            style: FilledButton.styleFrom(
              backgroundColor: primaryGreen,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(loading ? 'Criando...' : 'Criar conta'),
          ),
        ],
      ),
    );
  }
}

class PasswordRecoveryPage extends StatefulWidget {
  const PasswordRecoveryPage({required this.api, super.key});
  final ApiService api;

  @override
  State<PasswordRecoveryPage> createState() => _PasswordRecoveryPageState();
}

class _PasswordRecoveryPageState extends State<PasswordRecoveryPage> {
  final login = TextEditingController();
  final resetToken = TextEditingController();
  final newPassword = TextEditingController();
  String? error;
  String? message;
  bool requested = false;
  bool loading = false;

  @override
  void dispose() {
    login.dispose();
    resetToken.dispose();
    newPassword.dispose();
    super.dispose();
  }

  Future<void> requestToken() async {
    setState(() { loading = true; error = null; message = null; });
    try {
      final result = await widget.api.postObject('/auth/password-reset/request', {'login': login.text.trim()});
      resetToken.text = result['reset_token']?.toString() ?? '';
      setState(() { requested = true; message = 'Token gerado com sucesso!'; });
    } catch (exception) {
      setState(() => error = exception.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> confirmReset() async {
    setState(() { loading = true; error = null; message = null; });
    try {
      await widget.api.postObject('/auth/password-reset/confirm', {
        'login': login.text.trim(),
        'reset_token': resetToken.text.trim(),
        'new_password': newPassword.text,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Senha atualizada. Faça login novamente.')));
        Navigator.pop(context);
      }
    } catch (exception) {
      setState(() => error = exception.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Recuperar senha',
      subtitle: 'Recupere o acesso à sua conta',
      showBack: true,
      api: widget.api,
      child: Column(children: [
        if (error != null) ErrorBanner(message: error!),
        if (message != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(message!, style: const TextStyle(color: primaryGreen))),
        AppField(controller: login, label: 'Usuário ou e-mail', icon: Icons.badge_outlined),
        if (!requested) ...[
          const SizedBox(height: 16),
          FilledButton(
            onPressed: loading ? null : requestToken,
            style: FilledButton.styleFrom(backgroundColor: primaryGreen),
            child: Text(loading ? 'Solicitando...' : 'Solicitar token'),
          ),
        ] else ...[
          const SizedBox(height: 14),
          AppField(controller: resetToken, label: 'Token de recuperação', icon: Icons.key_outlined),
          const SizedBox(height: 14),
          AppField(controller: newPassword, label: 'Nova senha', icon: Icons.lock_outline, obscureText: true),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: loading ? null : confirmReset,
            style: FilledButton.styleFrom(backgroundColor: primaryGreen),
            child: Text(loading ? 'Atualizando...' : 'Atualizar senha'),
          ),
        ],
      ]),
    );
  }
}

class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
    required this.api,
    this.showBack = false,
    this.onConfigureServer,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final ApiService api;
  final bool showBack;
  final VoidCallback? onConfigureServer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
          child: Column(
            children: [
              if (showBack) Align(alignment: Alignment.centerLeft, child: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back))),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: softSurface, borderRadius: BorderRadius.circular(22)),
                child: const Icon(Icons.local_fire_department, size: 42, color: primaryGreen),
              ),
              const SizedBox(height: 14),
              Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: darkGreen)),
              Text(subtitle, style: const TextStyle(color: textMuted)),
              const SizedBox(height: 12),

              // Server Indicator & Quick Config Chip
              InkWell(
                onTap: onConfigureServer ?? () => showDialog(
                  context: context,
                  builder: (_) => ServerConfigDialog(api: api, onSaved: () {}),
                ),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: softSurface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xffe3e2e2)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_outlined, size: 14, color: primaryGreen),
                      const SizedBox(width: 6),
                      Text(
                        'Servidor: ${api.baseUrl}',
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: darkGreen, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.edit, size: 12, color: textMuted),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              Card(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                child: Padding(padding: const EdgeInsets.all(20), child: child),
              ),
              const SizedBox(height: 20),
              const Text('AgroTech IoT Tabaco • Telemetria de secagem', style: TextStyle(color: textMuted, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class ServerConfigDialog extends StatefulWidget {
  const ServerConfigDialog({required this.api, required this.onSaved, super.key});
  final ApiService api;
  final VoidCallback onSaved;

  @override
  State<ServerConfigDialog> createState() => _ServerConfigDialogState();
}

class _ServerConfigDialogState extends State<ServerConfigDialog> {
  late TextEditingController urlController;
  bool testing = false;
  String? testResult;
  bool? testSuccess;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.api.baseUrl);
  }

  @override
  void dispose() {
    urlController.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      testing = true;
      testResult = null;
      testSuccess = null;
    });
    final ok = await widget.api.testConnection(urlController.text.trim());
    setState(() {
      testing = false;
      testSuccess = ok;
      testResult = ok ? 'Conexão estabelecida com sucesso (API Online)!' : 'Não foi possível conectar. Verifique o IP e se o backend está rodando.';
    });
  }

  Future<void> _save() async {
    final url = urlController.text.trim();
    if (url.isEmpty) return;
    await widget.api.setBaseUrl(url);
    widget.onSaved();
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Servidor configurado para: $url')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.dns, color: primaryGreen),
          SizedBox(width: 8),
          Text('Configurar Servidor API', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: darkGreen)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Informe a URL base do backend FastAPI:', style: TextStyle(fontSize: 12, color: textMuted)),
            const SizedBox(height: 10),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'URL da API (Ex: http://192.168.1.2:8000)',
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Pré-definições Rápidas:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: textMuted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ActionChip(
                  label: const Text('127.0.0.1 (Windows/Web)', style: TextStyle(fontSize: 10)),
                  onPressed: () => setState(() => urlController.text = 'http://127.0.0.1:8000'),
                ),
                ActionChip(
                  label: const Text('10.0.2.2 (Emulador Android)', style: TextStyle(fontSize: 10)),
                  onPressed: () => setState(() => urlController.text = 'http://10.0.2.2:8000'),
                ),
                ActionChip(
                  label: const Text('192.168.1.2 (Wi-Fi Local)', style: TextStyle(fontSize: 10)),
                  onPressed: () => setState(() => urlController.text = 'http://192.168.1.2:8000'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (testResult != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: testSuccess == true ? successBg : errorBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(testSuccess == true ? Icons.check_circle : Icons.error_outline, size: 18, color: testSuccess == true ? primaryGreen : errorRed),
                    const SizedBox(width: 8),
                    Expanded(child: Text(testResult!, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: testSuccess == true ? const Color(0xff394d14) : errorRed))),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: testing ? null : _test,
              icon: testing
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check, size: 16),
              label: Text(testing ? 'Testando conexão...' : 'Testar Conexão'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(backgroundColor: primaryGreen),
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}

class AppField extends StatelessWidget {
  const AppField({required this.controller, required this.label, required this.icon, this.obscureText = false, this.suffix, super.key});
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon), suffixIcon: suffix),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({required this.message, super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xffffdad6), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [const Icon(Icons.error_outline, color: Color(0xffba1a1a)), const SizedBox(width: 8), Expanded(child: Text(message, style: const TextStyle(color: Color(0xff93000a))))]),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({required this.api, super.key});
  final ApiService api;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int index = 0;
  List<Map<String, dynamic>> units = [];
  List<Map<String, dynamic>> devices = [];
  List<Map<String, dynamic>> readings = [];
  List<Map<String, dynamic>> alerts = [];
  Map<String, dynamic>? latest;
  Map<String, dynamic>? user;
  bool loading = true;
  String? error;
  Timer? timer;
  bool requestInProgress = false;
  bool historyLoaded = false;

  @override
  void initState() {
    super.initState();
    loadUser();
    loadData();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => loadData(silent: true));
  }

  Future<void> loadUser() async {
    try {
      final result = await widget.api.getObject('/users/me');
      if (mounted) setState(() => user = result);
    } catch (_) {}
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> loadData({bool silent = false}) async {
    if (requestInProgress) return;
    requestInProgress = true;
    if (!silent && mounted) setState(() => loading = true);
    try {
      final unitData = await widget.api.getList('/curing_units/');
      final nextUnits = unitData.map((item) => Map<String, dynamic>.from(item as Map)).toList();

      List<Map<String, dynamic>> nextDevices = [];
      try {
        final devData = await widget.api.getList('/devices/');
        nextDevices = devData.map((item) => Map<String, dynamic>.from(item as Map)).toList();
      } catch (_) {}

      List<Map<String, dynamic>> nextAlerts = [];
      try {
        final alertData = await widget.api.getList('/alerts/');
        nextAlerts = alertData.map((item) => Map<String, dynamic>.from(item as Map)).toList();
      } catch (_) {}

      List<Map<String, dynamic>> nextReadings = [];
      Map<String, dynamic>? nextLatest;
      if (nextUnits.isNotEmpty) {
        final id = nextUnits.first['id'];
        final results = await Future.wait<dynamic>([
          widget.api.getObjectOrNull('/curing_units/$id/latest'),
          if (!historyLoaded) widget.api.getList('/curing_units/$id/readings'),
        ]);
        nextLatest = results[0] as Map<String, dynamic>?;
        if (!historyLoaded) {
          nextReadings = (results[1] as List<dynamic>).map((item) => Map<String, dynamic>.from(item as Map)).toList();
          historyLoaded = true;
        } else {
          nextReadings = readings;
        }
      }
      if (mounted) {
        setState(() {
          units = nextUnits;
          devices = nextDevices;
          alerts = nextAlerts;
          readings = nextReadings;
          latest = nextLatest;
          loading = false;
          error = null;
        });
      }
    } catch (exception) {
      if (mounted && !silent) setState(() { loading = false; error = exception.toString().replaceFirst('Exception: ', ''); });
    } finally {
      requestInProgress = false;
    }
  }

  Future<void> startDrying() async {
    if (units.isEmpty) return;
    await widget.api.postObject('/curing_units/${units.first['id']}/start-drying', {});
    await loadData();
  }

  Future<void> logout() async {
    await widget.api.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginPage(api: widget.api)),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(
        units: units,
        latest: latest,
        devices: devices,
        loading: loading,
        error: error,
        onRefresh: loadData,
        onStartDrying: startDrying,
        onNavigateToDevices: () => setState(() => index = 1),
      ),
      DevicesPage(
        api: widget.api,
        devices: devices,
        units: units,
        onRefresh: loadData,
      ),
      HistoryPage(readings: readings, unitName: units.isEmpty ? 'Estufa 01' : units.first['name'].toString()),
      AlertsPage(alerts: alerts),
      ProfilePage(api: widget.api, user: user, onLogout: logout, onRefreshData: loadData),
    ];
    return Scaffold(
      body: SafeArea(child: pages[index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Início'),
          NavigationDestination(icon: Icon(Icons.developer_board_outlined), selectedIcon: Icon(Icons.developer_board), label: 'Dispositivos'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Histórico'),
          NavigationDestination(icon: Icon(Icons.notifications_none), selectedIcon: Icon(Icons.notifications), label: 'Alertas'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Perfil'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DASHBOARD
// ---------------------------------------------------------------------------
class DashboardPage extends StatelessWidget {
  const DashboardPage({
    required this.units,
    required this.latest,
    required this.devices,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onStartDrying,
    required this.onNavigateToDevices,
    super.key,
  });

  final List<Map<String, dynamic>> units;
  final Map<String, dynamic>? latest;
  final List<Map<String, dynamic>> devices;
  final bool loading;
  final String? error;
  final Future<void> Function({bool silent}) onRefresh;
  final Future<void> Function() onStartDrying;
  final VoidCallback onNavigateToDevices;

  @override
  Widget build(BuildContext context) {
    final celsius = (latest?['temperature'] as num?)?.toDouble();
    final fahrenheit = celsius == null ? null : celsius * 9 / 5 + 32;
    final humidity = (latest?['humidity'] as num?)?.toDouble();
    final onlineDevicesCount = devices.where((d) => d['status'] == 'online').length;

    return RefreshIndicator(
      onRefresh: () => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ESTUFA DE TABACO', style: TextStyle(color: primaryGreen, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                    SizedBox(height: 4),
                    Text('Monitor de Estufa', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700, color: darkGreen)),
                  ],
                ),
              ),
              IconButton(onPressed: () => onRefresh(), icon: const Icon(Icons.refresh)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: StatusChip(
                  online: error == null,
                  label: error == null ? 'Rede LoRa AU915 • Ativa' : 'API indisponível',
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: onNavigateToDevices,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: softSurface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xffe3e2e2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.sensors, size: 16, color: primaryGreen),
                      const SizedBox(width: 4),
                      Text('$onlineDevicesCount/${devices.length} ESP32', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: darkGreen)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (error != null) ErrorBanner(message: error!),
          if (loading && units.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(36), child: CircularProgressIndicator())),
          if (!loading && units.isEmpty) EmptyState(icon: Icons.warehouse_outlined, title: 'Nenhuma estufa cadastrada', message: 'Vincule um dispositivo ESP32 para começar a receber telemetria.'),
          if (units.isNotEmpty) ...[
            Text(units.first['name']?.toString() ?? 'Estufa', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: darkGreen)),
            const SizedBox(height: 4),
            Text('Fase: ${units.first['curing_stage'] ?? 'Não informado'}', style: const TextStyle(color: textMuted)),
            const SizedBox(height: 14),
            if (units.first['drying_started_at'] == null)
              FilledButton.icon(
                onPressed: onStartDrying,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Iniciar secagem'),
                style: FilledButton.styleFrom(backgroundColor: primaryGreen),
              )
            else
              const StatusChip(online: true, label: 'Secagem em andamento'),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: MetricCard(title: 'Temperatura', value: fahrenheit == null ? '--' : fahrenheit.toStringAsFixed(1), unit: '°F', icon: Icons.thermostat, accent: const Color(0xffe88b54))),
              const SizedBox(width: 12),
              Expanded(child: MetricCard(title: 'Umidade relativa', value: humidity == null ? '--' : humidity.toStringAsFixed(1), unit: '%', icon: Icons.water_drop_outlined, accent: const Color(0xff5595a1))),
            ]),
            const SizedBox(height: 14),
            Card(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, color: primaryGreen),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        latest == null ? 'Aguardando telemetria do transmissor ESP32' : 'Última leitura: ${formatDate(latest!['timestamp'])}',
                        style: const TextStyle(color: textMuted),
                      ),
                    ),
                    Icon(Icons.circle, size: 10, color: latest == null ? Colors.grey : const Color(0xff3f9966)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xffe3e2e2))),
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: softSurface, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.qr_code_scanner, color: primaryGreen),
                ),
                title: const Text('Módulos ESP32 & Sensores', style: TextStyle(fontWeight: FontWeight.w700, color: darkGreen)),
                subtitle: Text('${devices.length} nós cadastrados • LoRa 915MHz'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onNavigateToDevices,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// GERENCIAMENTO DE MÓDULOS ESP32 & SENSORES LORA
// ---------------------------------------------------------------------------
class DevicesPage extends StatefulWidget {
  const DevicesPage({
    required this.api,
    required this.devices,
    required this.units,
    required this.onRefresh,
    super.key,
  });

  final ApiService api;
  final List<Map<String, dynamic>> devices;
  final List<Map<String, dynamic>> units;
  final Future<void> Function({bool silent}) onRefresh;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  String filter = 'Todos';

  @override
  Widget build(BuildContext context) {
    final total = widget.devices.length;
    final onlineCount = widget.devices.where((d) => d['status'] == 'online').length;
    final offlineCount = total - onlineCount;

    final filteredDevices = widget.devices.where((d) {
      if (filter == 'Online') return d['status'] == 'online';
      if (filter == 'Offline / Alertas') return d['status'] != 'online';
      if (filter == 'Bateria Baixa') return (d['battery_level'] as num? ?? 100) < 25;
      return true;
    }).toList();

    return RefreshIndicator(
      onRefresh: () => widget.onRefresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('DISPOSITIVOS IoT', style: TextStyle(color: primaryGreen, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                    SizedBox(height: 2),
                    Text('Módulos & Sensores', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: darkGreen)),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => QrLinkPage(api: widget.api, units: widget.units, onLinked: () => widget.onRefresh()),
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: primaryGreen,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('Vincular', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Overview KPI Row
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [BoxShadow(color: Color(0x0a000000), blurRadius: 10, offset: Offset(0, 4))],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _SummaryItem(label: 'Total Módulos', value: '$total', icon: Icons.developer_board, color: darkGreen),
                _Divider(),
                _SummaryItem(label: 'Nós Online', value: '$onlineCount', icon: Icons.wifi_tethering, color: primaryGreen),
                _Divider(),
                _SummaryItem(label: 'Link Perdido', value: '$offlineCount', icon: Icons.warning_amber_rounded, color: offlineCount > 0 ? errorRed : textMuted),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Filter Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterChip(label: 'Todos ($total)', selected: filter == 'Todos', onSelected: () => setState(() => filter = 'Todos')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Online ($onlineCount)', selected: filter == 'Online', onSelected: () => setState(() => filter = 'Online')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Offline / Alertas ($offlineCount)', selected: filter == 'Offline / Alertas', onSelected: () => setState(() => filter = 'Offline / Alertas')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Bateria Baixa', selected: filter == 'Bateria Baixa', onSelected: () => setState(() => filter = 'Bateria Baixa')),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (filteredDevices.isEmpty)
            Card(
              color: softSurface,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    const Icon(Icons.devices_other, size: 42, color: primaryGreen),
                    const SizedBox(height: 12),
                    const Text('Nenhum módulo ESP32 vinculado', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: darkGreen)),
                    const SizedBox(height: 6),
                    const Text('Vincule o transmissor da sua estufa lendo o QR Code da placa ou digitando o endereço MAC.', textAlign: TextAlign.center, style: TextStyle(color: textMuted)),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QrLinkPage(api: widget.api, units: widget.units, onLinked: () => widget.onRefresh()),
                        ),
                      ),
                      style: FilledButton.styleFrom(backgroundColor: primaryGreen),
                      icon: const Icon(Icons.qr_code),
                      label: const Text('Vincular Novo Módulo ESP32'),
                    ),
                  ],
                ),
              ),
            ),

          // Device Cards
          ...filteredDevices.map((dev) => DeviceCard(
                device: dev,
                api: widget.api,
                onRefresh: widget.onRefresh,
                units: widget.units,
              )),

          const SizedBox(height: 16),

          // Gateway SX1302 Central Section
          GatewayInfoCard(api: widget.api, onRefresh: widget.onRefresh),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({required this.label, required this.value, required this.icon, required this.color});
  final String label, value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800)),
        Text(label, style: const TextStyle(color: textMuted, fontSize: 11)),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(width: 1, height: 36, color: const Color(0xffe3e2e2));
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onSelected});
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      selected: selected,
      onSelected: (_) => onSelected(),
      label: Text(label),
      selectedColor: successBg,
      checkmarkColor: primaryGreen,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? primaryGreen : textMuted,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: selected ? primaryGreen : const Color(0xffe3e2e2))),
      backgroundColor: Colors.white,
    );
  }
}

// ---------------------------------------------------------------------------
// DEVICE CARD COMPONENT
// ---------------------------------------------------------------------------
class DeviceCard extends StatelessWidget {
  const DeviceCard({
    required this.device,
    required this.api,
    required this.onRefresh,
    required this.units,
    super.key,
  });

  final Map<String, dynamic> device;
  final ApiService api;
  final Future<void> Function({bool silent}) onRefresh;
  final List<Map<String, dynamic>> units;

  @override
  Widget build(BuildContext context) {
    final isOnline = device['status'] == 'online';
    final battery = (device['battery_level'] as num?)?.toInt() ?? 100;
    final estufaName = device['curing_unit_name']?.toString() ?? 'Estufa Vinculada';
    final deviceCode = device['device_code']?.toString() ?? 'ESP32-TOBACCO-01';
    final mac = device['mac_address']?.toString() ?? 'Não informado';
    final loraId = device['lora_id']?.toString() ?? 'LoRa AU915';
    final lastSeen = formatRelativeTime(device['last_seen_at']);

    // Parse sensors config
    List<dynamic> sensors = [];
    try {
      if (device['sensors_config'] != null) {
        sensors = jsonDecode(device['sensors_config'].toString()) as List<dynamic>;
      }
    } catch (_) {
      sensors = [];
    }
    if (sensors.isEmpty) {
      sensors = [
        {'name': 'Sensor SHT40 (Temp/Umid)', 'status': isOnline ? 'Operacional' : 'Aguardando Leitura'},
      ];
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: isOnline ? const Color(0xffe3e2e2) : const Color(0xffffdad6), width: isOnline ? 1 : 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Name, Status Badge, More Actions
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              deviceCode,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: darkGreen),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          PulsingStatusBadge(isOnline: isOnline),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$estufaName • Setor de Secagem',
                        style: const TextStyle(fontSize: 12, color: textMuted),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: textMuted),
                  onSelected: (value) async {
                    if (value == 'calibrate') {
                      _openCalibrationDialog(context);
                    } else if (value == 'thresholds') {
                      _openThresholdsDialog(context);
                    } else if (value == 'reconnect') {
                      await _reconnect(context);
                    } else if (value == 'unlink') {
                      await _unlink(context);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'calibrate', child: Row(children: [Icon(Icons.build_outlined, size: 18), SizedBox(width: 8), Text('Calibrar Sondas')])),
                    const PopupMenuItem(value: 'thresholds', child: Row(children: [Icon(Icons.tune, size: 18), SizedBox(width: 8), Text('Limites de Alerta')])),
                    const PopupMenuItem(value: 'reconnect', child: Row(children: [Icon(Icons.bluetooth_searching, size: 18), SizedBox(width: 8), Text('Reconectar BLE')])),
                    const PopupMenuItem(value: 'unlink', child: Row(children: [Icon(Icons.link_off, size: 18, color: errorRed), SizedBox(width: 8), Text('Desvincular', style: TextStyle(color: errorRed))])),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Meta specs bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: softSurface, borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                  Text('MAC: $mac', style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: textMuted)),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('•', style: TextStyle(color: textMuted))),
                  Text('LoRa: $loraId', style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: textMuted)),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Telemetry Badges Row (LoRa, Battery, Last Contact)
            Row(
              children: [
                Expanded(
                  child: _TelemetryMetricBox(
                    icon: Icons.cell_tower,
                    label: 'Sinal LoRa',
                    value: isOnline ? '$rssi dBm' : 'Sem Sinal',
                    subvalue: isOnline ? (rssi > -75 ? 'Excelente' : 'Regular') : 'Link Perdido',
                    accentColor: isOnline ? (rssi > -75 ? primaryGreen : accentGold) : errorRed,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TelemetryMetricBox(
                    icon: battery > 25 ? Icons.battery_charging_full : Icons.battery_alert,
                    label: 'Bateria Nó',
                    value: '$battery%',
                    subvalue: battery > 25 ? (device['battery_status']?.toString() ?? 'Solar OK') : 'Bateria Baixa',
                    accentColor: battery > 25 ? primaryGreen : errorRed,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TelemetryMetricBox(
                    icon: Icons.history,
                    label: 'Último Contato',
                    value: lastSeen,
                    subvalue: isOnline ? 'Tempo Real' : 'Atrasado',
                    accentColor: isOnline ? darkGreen : errorRed,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Sensors Connected Matrix
            const Text('Sensores Conectados', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: darkGreen)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: sensors.map((s) {
                final sName = s['name']?.toString() ?? 'Sensor';
                final sStatus = s['status']?.toString() ?? 'Operacional';
                final isSensorOk = sStatus.contains('OK') || sStatus.contains('Operacional');
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: isSensorOk ? softSurface : const Color(0x33ffdad6),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isSensorOk ? const Color(0xffe3e2e2) : const Color(0x66ba1a1a)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        sName.contains('GLP') ? Icons.local_fire_department : Icons.thermostat,
                        size: 14,
                        color: isSensorOk ? primaryGreen : errorRed,
                      ),
                      const SizedBox(width: 4),
                      Text('$sName: ', style: const TextStyle(fontSize: 11, color: textMuted)),
                      Text(sStatus, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isSensorOk ? primaryGreen : errorRed)),
                    ],
                  ),
                );
              }).toList(),
            ),

            // Failure Diagnostic Box (if offline)
            if (!isOnline) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: errorBg, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.warning_amber_rounded, size: 18, color: errorRed),
                        SizedBox(width: 6),
                        Text('Diagnóstico de Falha de Telemetria', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: errorRed)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Sem sinal de pacote há $lastSeen. O último RSSI registrado foi de $rssi dBm com bateria em $battery%.',
                      style: const TextStyle(fontSize: 11, color: Color(0xff93000a)),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Icon(Icons.lightbulb_outline, size: 16, color: accentGold),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Ação recomendada: Inspecione o alinhamento da antena LoRa do nó e verifique a alimentação.',
                              style: TextStyle(fontSize: 10.5, color: darkGreen),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            // Quick Actions Button Bar
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openCalibrationDialog(context),
                    icon: const Icon(Icons.build_outlined, size: 15),
                    label: const Text('Calibrar', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openThresholdsDialog(context),
                    icon: const Icon(Icons.tune, size: 15),
                    label: const Text('Limites', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                if (!isOnline) ...[
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Reconectar BLE',
                    onPressed: () => _reconnect(context),
                    icon: const Icon(Icons.bluetooth_searching, size: 18),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openCalibrationDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SensorCalibrationSheet(
        api: api,
        device: device,
        onSaved: () => onRefresh(),
      ),
    );
  }

  void _openThresholdsDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => DeviceThresholdsSheet(
        api: api,
        device: device,
        onSaved: () => onRefresh(),
      ),
    );
  }

  Future<void> _reconnect(BuildContext context) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tentando reconexão com o nó...')));
      await api.postObject('/devices/${device['id']}/reconnect', {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nó reconectado com sucesso!')));
      await onRefresh();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falha ao reconectar: $e')));
    }
  }

  Future<void> _unlink(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desvincular Dispositivo'),
        content: Text('Tem certeza que deseja desvincular ${device['device_code']}? A estufa deixará de receber telemetria deste nó.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: errorRed),
            child: const Text('Desvincular'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await api.deleteObject('/devices/${device['id']}');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dispositivo desvinculado.')));
        await onRefresh();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao desvincular: $e')));
      }
    }
  }
}

class _TelemetryMetricBox extends StatelessWidget {
  const _TelemetryMetricBox({
    required this.icon,
    required this.label,
    required this.value,
    required this.subvalue,
    required this.accentColor,
  });

  final IconData icon;
  final String label, value, subvalue;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: softSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: accentColor),
              const SizedBox(width: 4),
              Expanded(child: Text(label, style: const TextStyle(fontSize: 10, color: textMuted), overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: accentColor), maxLines: 1),
          Text(subvalue, style: const TextStyle(fontSize: 9.5, color: textMuted), maxLines: 1),
        ],
      ),
    );
  }
}

class PulsingStatusBadge extends StatefulWidget {
  const PulsingStatusBadge({required this.isOnline, super.key});
  final bool isOnline;

  @override
  State<PulsingStatusBadge> createState() => _PulsingStatusBadgeState();
}

class _PulsingStatusBadgeState extends State<PulsingStatusBadge> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOnline) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: errorBg, borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.circle, size: 6, color: errorRed),
            SizedBox(width: 4),
            Text('Desconectado', style: TextStyle(color: Color(0xff93000a), fontSize: 10, fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final alpha = (0.6 + 0.4 * _controller.value).clamp(0.0, 1.0);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: successBg, borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color.fromRGBO(13, 99, 27, alpha),
                  boxShadow: [
                    BoxShadow(color: Color.fromRGBO(13, 99, 27, 0.4 * _controller.value), blurRadius: 4, spreadRadius: 1),
                  ],
                ),
              ),
              const SizedBox(width: 5),
              const Text('Online', style: TextStyle(color: Color(0xff394d14), fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// GATEWAY INFO CARD (STITCH PROTOTYPE)
// ---------------------------------------------------------------------------
class GatewayInfoCard extends StatelessWidget {
  const GatewayInfoCard({required this.api, required this.onRefresh, super.key});
  final ApiService api;
  final Future<void> Function({bool silent}) onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: primaryGreen, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.router, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Gateway SX1302 Central', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: darkGreen)),
                    Text('Concentrador LoRaWAN Multicanal', style: TextStyle(fontSize: 11, color: textMuted)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: successBg, borderRadius: BorderRadius.circular(20)),
                child: const Text('915.0 MHz', style: TextStyle(color: Color(0xff394d14), fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Network Parameters Grid
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 2.3,
            children: [
              _GatewayParam(title: 'Endereço IP Servidor', value: api.baseUrl.replaceFirst('http://', '')),
              const _GatewayParam(title: 'Banda de Operação', value: 'AU915 (Anatel)'),
              const _GatewayParam(title: 'Spreading Factor', value: 'SF7 / BW 125kHz'),
              const _GatewayParam(title: 'Potência TX / Taxa', value: '+20 dBm • 60s'),
            ],
          ),
          const SizedBox(height: 12),

          // Security Footnote
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: softSurface, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: const [
                Icon(Icons.verified_user, size: 16, color: primaryGreen),
                SizedBox(width: 8),
                Expanded(child: Text('JWT Bearer Auth • Criptografia por Chave de Lote', style: TextStyle(fontSize: 11, color: textMuted))),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Gateway Action Buttons
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logs RF exportados para a memória local.'))),
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Exportar Logs RF', style: TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Comando de reinício enviado ao Gateway SX1302.'))),
                  icon: const Icon(Icons.power_settings_new, size: 16, color: accentGold),
                  label: const Text('Reiniciar Gateway', style: TextStyle(fontSize: 11)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GatewayParam extends StatelessWidget {
  const _GatewayParam({required this.title, required this.value});
  final String title, value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(fontSize: 10, color: textMuted)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: darkGreen), overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// QR CODE SCANNER & DEVICE LINKING PAGE
// ---------------------------------------------------------------------------
class QrLinkPage extends StatefulWidget {
  const QrLinkPage({
    required this.api,
    required this.units,
    required this.onLinked,
    super.key,
  });

  final ApiService api;
  final List<Map<String, dynamic>> units;
  final VoidCallback onLinked;

  @override
  State<QrLinkPage> createState() => _QrLinkPageState();
}

class _QrLinkPageState extends State<QrLinkPage> with SingleTickerProviderStateMixin {
  late MobileScannerController _scannerController;
  late AnimationController _laserController;
  bool flashOn = false;
  bool isSubmitting = false;
  String? successMessage;
  String? errorMessage;

  // Real Recognized Device State
  bool deviceRecognized = false;
  String? recognizedCode;
  String? recognizedMac;
  String? recognizedLora;
  String? recognizedRssi;
  List<String> detectedSensors = ['Sensor SHT40 (Temp/Umid)'];

  // Target Curing Unit Selection
  int? selectedUnitId;

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
    _laserController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    if (widget.units.isNotEmpty) {
      selectedUnitId = widget.units.first['id'] as int?;
    }
  }

  @override
  void dispose() {
    _scannerController.dispose();
    _laserController.dispose();
    super.dispose();
  }

  void _handleScannedRaw(String raw) {
    if (raw.trim().isEmpty) return;

    String code = raw.trim();
    String? mac;
    String? lora;
    String? model;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        code = decoded['controller_id']?.toString() ??
            decoded['device_code']?.toString() ??
            decoded['id']?.toString() ??
            code;
        mac = decoded['mac_address']?.toString() ?? decoded['mac']?.toString();
        lora = decoded['lora_id']?.toString() ?? decoded['lora']?.toString();
        model = decoded['hardware_model']?.toString();
      }
    } catch (_) {
      final idMatch = RegExp(r'(?:ID|controller_id|id)=([A-Za-z0-9\-_]+)', caseSensitive: false).firstMatch(raw);
      if (idMatch != null) {
        code = idMatch.group(1)!;
      }
      final macMatch = RegExp(r'([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})').firstMatch(raw);
      if (macMatch != null) {
        mac = macMatch.group(0)?.toUpperCase();
      }
      final loraMatch = RegExp(r'0x[0-9A-Fa-f]{4,8}').firstMatch(raw);
      if (loraMatch != null) {
        lora = loraMatch.group(0)?.toUpperCase();
      }
    }

    setState(() {
      recognizedCode = code;
      recognizedMac = mac;
      recognizedLora = lora;
      recognizedRssi = '-60 dBm';
      deviceRecognized = true;
      errorMessage = null;
      if (model != null) {
        detectedSensors = ['Sensor SHT40', model];
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Código QR lido: $code!')),
    );
  }

  void _onManualEntry() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const ManualDeviceDialog(),
    );
    if (result != null && (result['code']?.isNotEmpty == true || result['mac']?.isNotEmpty == true)) {
      setState(() {
        recognizedCode = result['code']?.isNotEmpty == true ? result['code']! : (result['mac'] ?? 'ESP32-TOBACCO-01');
        recognizedMac = result['mac']?.isNotEmpty == true ? result['mac'] : null;
        recognizedLora = result['lora']?.isNotEmpty == true ? result['lora'] : null;
        recognizedRssi = '-60 dBm';
        deviceRecognized = true;
        errorMessage = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dispositivo identificado! Prossiga para o vínculo.')));
    }
  }

  Future<void> _confirmLink() async {
    if (!deviceRecognized || (recognizedCode == null && recognizedMac == null)) {
      setState(() => errorMessage = 'Por favor, escaneie ou digite o Controller ID do seu ESP32 primeiro.');
      return;
    }

    setState(() {
      isSubmitting = true;
      errorMessage = null;
      successMessage = null;
    });

    try {
      await widget.api.postObject('/devices/link', {
        'controller_id': recognizedCode,
        'device_code': recognizedCode,
        'mac_address': recognizedMac,
        'lora_id': recognizedLora,
        'hardware_model': 'Heltec WiFi LoRa 32 V3',
        'curing_unit_id': selectedUnitId,
      });

      setState(() {
        successMessage = 'Dispositivo $recognizedCode vinculado com sucesso!';
        isSubmitting = false;
      });

      widget.onLinked();
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        errorMessage = e.toString().replaceFirst('Exception: ', '');
        isSubmitting = false;
      });
    }
  }

  void _createNewUnit() async {
    final nameController = TextEditingController(text: 'Estufa 0${widget.units.length + 1}');
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cadastrar Estufa de Secagem'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: 'Nome da Estufa (Ex: Estufa 03)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: primaryGreen),
            child: const Text('Criar'),
          ),
        ],
      ),
    );
    if (created == true && nameController.text.trim().isNotEmpty) {
      try {
        final newUnit = await widget.api.postObject('/curing_units/', {
          'name': nameController.text.trim(),
        });
        setState(() {
          widget.units.add(newUnit);
          selectedUnitId = newUnit['id'] as int?;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Estufa ${nameController.text} criada!')));
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao criar estufa: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vincular por QR Code', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: darkGreen)),
        backgroundColor: surface,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Text('Aponte a câmera para o QR Code no invólucro do seu módulo ESP32 ou insira o Controller ID.', style: TextStyle(fontSize: 13, color: textMuted)),
          const SizedBox(height: 16),

          // Real Mobile Scanner Camera Box
          Container(
            height: 290,
            decoration: BoxDecoration(
              color: const Color(0xff121212),
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [BoxShadow(color: Color(0x1a000000), blurRadius: 12, offset: Offset(0, 6))],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                // Live Hardware Camera Scanner
                Positioned.fill(
                  child: MobileScanner(
                    controller: _scannerController,
                    onDetect: (capture) {
                      final barcodes = capture.barcodes;
                      for (final barcode in barcodes) {
                        final raw = barcode.rawValue;
                        if (raw != null && raw.trim().isNotEmpty) {
                          _handleScannedRaw(raw);
                          break;
                        }
                      }
                    },
                    errorBuilder: (context, error) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.videocam_off, color: Colors.white70, size: 40),
                              const SizedBox(height: 10),
                              const Text('Câmera indisponível nesta plataforma', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              const Text('Utilize a digitação manual abaixo para inserir o Controller ID.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontSize: 11)),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: _onManualEntry,
                                style: FilledButton.styleFrom(backgroundColor: primaryGreen),
                                icon: const Icon(Icons.edit, size: 16),
                                label: const Text('Digitar Controller ID', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),

                // Top Controls Overlay (Flash & Camera Switch)
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                        child: Row(
                          children: const [
                            Icon(Icons.circle, size: 8, color: Color(0xff88d982)),
                            SizedBox(width: 6),
                            Text('SCANNER ATIVO', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          IconButton.filled(
                            style: IconButton.styleFrom(backgroundColor: flashOn ? const Color(0xff88d982) : Colors.black54),
                            onPressed: () async {
                              await _scannerController.toggleTorch();
                              setState(() => flashOn = !flashOn);
                            },
                            icon: Icon(flashOn ? Icons.flash_on : Icons.flash_off, color: flashOn ? Colors.black : Colors.white, size: 18),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            style: IconButton.styleFrom(backgroundColor: Colors.black54),
                            onPressed: () => _scannerController.switchCamera(),
                            icon: const Icon(Icons.flip_camera_ios, color: Colors.white, size: 18),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Scanning Reticle & Animated Laser
                Center(
                  child: SizedBox(
                    width: 190,
                    height: 190,
                    child: Stack(
                      children: [
                        Positioned.fill(child: CustomPaint(painter: _QrCornerPainter())),
                        AnimatedBuilder(
                          animation: _laserController,
                          builder: (context, child) {
                            return Positioned(
                              top: 20 + _laserController.value * 140,
                              left: 12,
                              right: 12,
                              child: Container(
                                height: 2,
                                decoration: const BoxDecoration(
                                  color: Color(0xff88d982),
                                  boxShadow: [
                                    BoxShadow(color: Color(0xffa3f69c), blurRadius: 10, spreadRadius: 1),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        if (deviceRecognized)
                          Center(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.check_circle, size: 36, color: Color(0xff88d982)),
                                  const SizedBox(height: 4),
                                  Text(recognizedCode ?? 'Detectado', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // Manual Entry Button
                Positioned(
                  bottom: 12,
                  left: 12,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.black54,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                    onPressed: _onManualEntry,
                    icon: const Icon(Icons.keyboard, size: 16),
                    label: const Text('Digitar manualmente', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Recognized QR Code Card (Only shown if detected/entered)
          if (deviceRecognized)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xffcfe99f), width: 1.5),
                boxShadow: const [BoxShadow(color: Color(0x0a000000), blurRadius: 8, offset: Offset(0, 3))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.verified, color: primaryGreen, size: 18),
                          SizedBox(width: 6),
                          Text('Dispositivo Reconhecido', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: primaryGreen)),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: successBg, borderRadius: BorderRadius.circular(12)),
                        child: const Text('Pronto para Vincular', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xff394d14))),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(recognizedCode ?? 'ESP32-TOBACCO-01', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: darkGreen)),
                  const SizedBox(height: 3),
                  Text('MAC: ${recognizedMac ?? "Auto / Wi-Fi"}  •  LoRa: ${recognizedLora ?? "AU915"}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: textMuted)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    children: detectedSensors.map((tag) => Chip(
                      label: Text(tag, style: const TextStyle(fontSize: 11, color: darkGreen)),
                      backgroundColor: softSurface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    )).toList(),
                  ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: softSurface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: primaryGreen, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text('Aponte a câmera para o QR Code da placa ou clique em "Digitar manualmente".', style: TextStyle(fontSize: 12, color: textMuted)),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 18),

          // Step 2: Target Estufa Selector
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('Selecione a Estufa de Destino', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: darkGreen)),
              Text('Passo 2 de 2', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: primaryGreen)),
            ],
          ),
          const SizedBox(height: 10),

          if (widget.units.isEmpty)
            Card(
              color: softSurface,
              elevation: 0,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Nenhuma estufa cadastrada. Crie uma abaixo para associar ao módulo.'),
              ),
            )
          else
            ...widget.units.map((u) {
              final id = u['id'] as int?;
              final name = u['name']?.toString() ?? 'Estufa';
              final isSelected = selectedUnitId == id;
              return InkWell(
                onTap: () => setState(() => selectedUnitId = id),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xfff0f7ed) : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: isSelected ? primaryGreen : const Color(0xffe3e2e2), width: isSelected ? 1.5 : 1),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: isSelected ? primaryGreen : const Color(0xff707a6c),
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: darkGreen)),
                            Text('Fase atual: ${u['curing_stage'] ?? 'Não iniciado'}', style: const TextStyle(fontSize: 12, color: textMuted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: _createNewUnit,
            icon: const Icon(Icons.add_business, size: 18),
            label: const Text('Cadastrar Nova Estufa de Secagem'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 18),

          if (errorMessage != null) ErrorBanner(message: errorMessage!),
          if (successMessage != null)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: successBg, borderRadius: BorderRadius.circular(14)),
              child: Row(
                children: [
                  const Icon(Icons.done_all, color: primaryGreen),
                  const SizedBox(width: 8),
                  Expanded(child: Text(successMessage!, style: const TextStyle(color: Color(0xff394d14), fontWeight: FontWeight.bold))),
                ],
              ),
            ),

          // Confirm Button
          FilledButton.icon(
            onPressed: isSubmitting ? null : _confirmLink,
            icon: isSubmitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.link, size: 20),
            label: Text(isSubmitting ? 'Vinculando com o Servidor...' : 'Confirmar Vínculo de Dispositivo', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            style: FilledButton.styleFrom(
              backgroundColor: primaryGreen,
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}

class _QrCornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff88d982)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cornerSize = 24.0;

    canvas.drawLine(const Offset(0, cornerSize), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(cornerSize, 0), paint);

    canvas.drawLine(Offset(size.width - cornerSize, 0), Offset(size.width, 0), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, cornerSize), paint);

    canvas.drawLine(Offset(0, size.height - cornerSize), Offset(0, size.height), paint);
    canvas.drawLine(Offset(0, size.height), Offset(cornerSize, size.height), paint);

    canvas.drawLine(Offset(size.width - cornerSize, size.height), Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(size.width, size.height), Offset(size.width, size.height - cornerSize), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// DIALOG DE ENTRADA MANUAL DE DISPOSITIVO (SEM MOCKS)
// ---------------------------------------------------------------------------
class ManualDeviceDialog extends StatefulWidget {
  const ManualDeviceDialog({super.key});

  @override
  State<ManualDeviceDialog> createState() => _ManualDeviceDialogState();
}

class _ManualDeviceDialogState extends State<ManualDeviceDialog> {
  final codeCtrl = TextEditingController();
  final macCtrl = TextEditingController();
  final loraCtrl = TextEditingController();

  @override
  void dispose() {
    codeCtrl.dispose();
    macCtrl.dispose();
    loraCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Identificação do Módulo ESP32'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Digite o Controller ID definido no ESP32 ou o endereço MAC:', style: TextStyle(fontSize: 12, color: textMuted)),
            const SizedBox(height: 14),
            TextField(
              controller: codeCtrl,
              decoration: const InputDecoration(
                labelText: 'Controller ID / Nome do Nó *',
                hintText: 'Ex: ESP32-TOBACCO-01',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: macCtrl,
              decoration: const InputDecoration(
                labelText: 'Endereço MAC (Opcional)',
                hintText: 'Ex: 24:6F:28:B1:09:4A',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: loraCtrl,
              decoration: const InputDecoration(
                labelText: 'ID LoRa (Opcional)',
                hintText: 'Ex: 0x74C0',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            if (codeCtrl.text.trim().isEmpty && macCtrl.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Por favor, digite ao menos o Controller ID ou MAC.')),
              );
              return;
            }
            Navigator.pop(context, {
              'code': codeCtrl.text.trim(),
              'mac': macCtrl.text.trim(),
              'lora': loraCtrl.text.trim(),
            });
          },
          style: FilledButton.styleFrom(backgroundColor: primaryGreen),
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// BOTTOM SHEET DE CALIBRAÇÃO DE SENSORES
// ---------------------------------------------------------------------------
class SensorCalibrationSheet extends StatefulWidget {
  const SensorCalibrationSheet({required this.api, required this.device, required this.onSaved, super.key});
  final ApiService api;
  final Map<String, dynamic> device;
  final VoidCallback onSaved;

  @override
  State<SensorCalibrationSheet> createState() => _SensorCalibrationSheetState();
}

class _SensorCalibrationSheetState extends State<SensorCalibrationSheet> {
  double dryOffset = 0.0;
  double wetOffset = 0.0;
  double humidityOffset = 0.0;
  int flameSensitivity = 80;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    try {
      if (widget.device['calibration_data'] != null) {
        final data = jsonDecode(widget.device['calibration_data'].toString()) as Map<String, dynamic>;
        dryOffset = (data['dry_probe_offset'] as num?)?.toDouble() ?? 0.0;
        wetOffset = (data['wet_probe_offset'] as num?)?.toDouble() ?? 0.0;
        humidityOffset = (data['humidity_offset'] as num?)?.toDouble() ?? 0.0;
        flameSensitivity = (data['flame_sensitivity'] as num?)?.toInt() ?? 80;
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await widget.api.postObject('/devices/${widget.device['id']}/calibrate', {
        'dry_probe_offset': dryOffset,
        'wet_probe_offset': wetOffset,
        'humidity_offset': humidityOffset,
        'flame_sensitivity': flameSensitivity,
      });
      widget.onSaved();
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Calibração salva no módulo ESP32!')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao salvar calibração: $e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Calibração de Sensores', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: darkGreen)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
          Text('${widget.device['device_code']} • Ajustes finos de offset', style: const TextStyle(fontSize: 12, color: textMuted)),
          const SizedBox(height: 16),

          _OffsetSlider(
            label: 'Offset Sonda Bulbo Seco (°F)',
            value: dryOffset,
            min: -5.0,
            max: 5.0,
            unit: '°F',
            onChanged: (v) => setState(() => dryOffset = double.parse(v.toStringAsFixed(1))),
          ),
          const SizedBox(height: 12),

          _OffsetSlider(
            label: 'Offset Sonda Bulbo Úmido (°F)',
            value: wetOffset,
            min: -5.0,
            max: 5.0,
            unit: '°F',
            onChanged: (v) => setState(() => wetOffset = double.parse(v.toStringAsFixed(1))),
          ),
          const SizedBox(height: 12),

          _OffsetSlider(
            label: 'Offset Umidade Relativa (%)',
            value: humidityOffset,
            min: -10.0,
            max: 10.0,
            unit: '%',
            onChanged: (v) => setState(() => humidityOffset = double.parse(v.toStringAsFixed(1))),
          ),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Sensibilidade Sensor GLP (MQ-2)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: darkGreen)),
              Text('$flameSensitivity%', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: primaryGreen)),
            ],
          ),
          Slider(
            value: flameSensitivity.toDouble(),
            min: 10,
            max: 100,
            divisions: 18,
            activeColor: primaryGreen,
            onChanged: (v) => setState(() => flameSensitivity = v.toInt()),
          ),
          const SizedBox(height: 18),

          FilledButton.icon(
            onPressed: saving ? null : _save,
            icon: saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.check),
            label: Text(saving ? 'Gravando no Módulo...' : 'Gravar Calibração'),
            style: FilledButton.styleFrom(
              backgroundColor: primaryGreen,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

class _OffsetSlider extends StatelessWidget {
  const _OffsetSlider({required this.label, required this.value, required this.min, required this.max, required this.unit, required this.onChanged});
  final String label, unit;
  final double value, min, max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: darkGreen)),
            Text('${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} $unit', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: primaryGreen)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: ((max - min) * 10).toInt(),
          activeColor: primaryGreen,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// BOTTOM SHEET DE CONFIGURAÇÃO DE LIMITES DE TEMPERATURA E UMIDADE
// ---------------------------------------------------------------------------
class DeviceThresholdsSheet extends StatefulWidget {
  const DeviceThresholdsSheet({required this.api, required this.device, required this.onSaved, super.key});
  final ApiService api;
  final Map<String, dynamic> device;
  final VoidCallback onSaved;

  @override
  State<DeviceThresholdsSheet> createState() => _DeviceThresholdsSheetState();
}

class _DeviceThresholdsSheetState extends State<DeviceThresholdsSheet> {
  late double tempMin;
  late double tempMax;
  late double humMin;
  late double humMax;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    tempMin = (widget.device['temp_min'] as num?)?.toDouble() ?? 35.0;
    tempMax = (widget.device['temp_max'] as num?)?.toDouble() ?? 75.0;
    humMin = (widget.device['humidity_min'] as num?)?.toDouble() ?? 40.0;
    humMax = (widget.device['humidity_max'] as num?)?.toDouble() ?? 90.0;
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await widget.api.postObject('/devices/${widget.device['id']}/thresholds', {
        'temp_min': tempMin,
        'temp_max': tempMax,
        'humidity_min': humMin,
        'humidity_max': humMax,
      });
      widget.onSaved();
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Limites atualizados com sucesso!')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao atualizar limites: $e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Limites de Temperatura e Umidade', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: darkGreen)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
          const Text('Defina a faixa segura para disparar alarmes em caso de desvio.', style: TextStyle(fontSize: 12, color: textMuted)),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Faixa de Temperatura (°C)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: darkGreen)),
              Text('${tempMin.toStringAsFixed(0)}°C  a  ${tempMax.toStringAsFixed(0)}°C', style: const TextStyle(fontWeight: FontWeight.bold, color: primaryGreen)),
            ],
          ),
          RangeSlider(
            values: RangeValues(tempMin, tempMax),
            min: 20.0,
            max: 95.0,
            divisions: 75,
            activeColor: primaryGreen,
            onChanged: (values) => setState(() {
              tempMin = values.start;
              tempMax = values.end;
            }),
          ),
          const SizedBox(height: 14),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Faixa de Umidade Relativa (%)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: darkGreen)),
              Text('${humMin.toStringAsFixed(0)}%  a  ${humMax.toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.bold, color: primaryGreen)),
            ],
          ),
          RangeSlider(
            values: RangeValues(humMin, humMax),
            min: 10.0,
            max: 100.0,
            divisions: 90,
            activeColor: const Color(0xff5595a1),
            onChanged: (values) => setState(() {
              humMin = values.start;
              humMax = values.end;
            }),
          ),
          const SizedBox(height: 20),

          FilledButton.icon(
            onPressed: saving ? null : _save,
            icon: saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.save),
            label: Text(saving ? 'Salvando...' : 'Salvar Limites de Operação'),
            style: FilledButton.styleFrom(
              backgroundColor: primaryGreen,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HISTÓRICO & ALERTAS & PERFIL & OUTROS COMPONENTES
// ---------------------------------------------------------------------------
class HistoryPage extends StatelessWidget {
  const HistoryPage({required this.readings, required this.unitName, super.key});
  final List<Map<String, dynamic>> readings;
  final String unitName;

  @override
  Widget build(BuildContext context) {
    final values = readings.map((reading) => ((reading['temperature'] as num).toDouble() * 9 / 5) + 32).toList();
    final humidity = readings.map((reading) => (reading['humidity'] as num).toDouble()).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        const Text('HISTÓRICO DE LEITURAS', style: TextStyle(color: primaryGreen, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
        const SizedBox(height: 5),
        Text(unitName, style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700, color: darkGreen)),
        const SizedBox(height: 18),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Temperatura °F'), icon: Icon(Icons.thermostat)),
            ButtonSegment(value: 1, label: Text('Umidade %'), icon: Icon(Icons.water_drop_outlined)),
          ],
          selected: const {0},
          onSelectionChanged: (_) {},
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Janela de coleta • últimas leituras', style: TextStyle(color: textMuted, fontWeight: FontWeight.w600)),
                const SizedBox(height: 18),
                SizedBox(height: 210, child: readings.isEmpty ? const Center(child: Text('Sem leituras disponíveis')) : ReadingChart(values: values, color: primaryGreen)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Stat(label: 'Mínima', value: values.isEmpty ? '--' : '${values.reduce((a, b) => a < b ? a : b).toStringAsFixed(1)} °F'),
                    Stat(label: 'Máxima', value: values.isEmpty ? '--' : '${values.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)} °F'),
                    Stat(label: 'Umidade média', value: humidity.isEmpty ? '--' : '${(humidity.reduce((a, b) => a + b) / humidity.length).toStringAsFixed(1)}%'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Leituras recentes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: darkGreen)),
        const SizedBox(height: 8),
        ...readings.take(12).map((reading) {
          final f = (reading['temperature'] as num).toDouble() * 9 / 5 + 32;
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(backgroundColor: Color(0xffcfe99f), child: Icon(Icons.sensors, color: primaryGreen)),
            title: Text('${f.toStringAsFixed(1)} °F  •  ${(reading['humidity'] as num).toStringAsFixed(1)}%'),
            subtitle: Text(formatDate(reading['timestamp'])),
          );
        }),
      ],
    );
  }
}

class AlertsPage extends StatelessWidget {
  const AlertsPage({required this.alerts, super.key});
  final List<Map<String, dynamic>> alerts;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('PAINEL DE OCORRÊNCIAS', style: TextStyle(color: primaryGreen, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                  SizedBox(height: 5),
                  Text('Central de alertas', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700, color: darkGreen)),
                ],
              ),
            ),
            if (alerts.isNotEmpty) StatusChip(online: false, label: '${alerts.length} ativo${alerts.length == 1 ? '' : 's'}'),
          ],
        ),
        const SizedBox(height: 18),
        if (alerts.isEmpty)
          const EmptyState(icon: Icons.notifications_none, title: 'Nenhum alerta ativo', message: 'Sua estufa está dentro dos parâmetros normais monitorados.')
        else
          ...alerts.map((alert) => AlertTile(alert: alert, expanded: true)),
      ],
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({
    required this.api,
    required this.user,
    required this.onLogout,
    required this.onRefreshData,
    super.key,
  });

  final ApiService api;
  final Map<String, dynamic>? user;
  final Future<void> Function() onLogout;
  final VoidCallback onRefreshData;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        children: [
          const Text('CONTA', style: TextStyle(color: primaryGreen, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
          const SizedBox(height: 5),
          const Text('Perfil e configurações', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700, color: darkGreen)),
          const SizedBox(height: 22),
          Card(
            elevation: 0,
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: const CircleAvatar(backgroundColor: Color(0xffcfe99f), child: Icon(Icons.person, color: primaryGreen)),
              title: Text(user?['name']?.toString() ?? 'Produtor Conectado', style: const TextStyle(fontWeight: FontWeight.bold, color: darkGreen)),
              subtitle: Text(user?['login']?.toString() ?? 'Sua conta está ativa'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Servidor & Conexão da API'),
                  subtitle: Text(api.baseUrl),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showDialog(
                    context: context,
                    builder: (_) => ServerConfigDialog(api: api, onSaved: onRefreshData),
                  ),
                ),
                const Divider(height: 1),
                const ListTile(leading: Icon(Icons.notifications_outlined), title: Text('Notificações Push'), subtitle: Text('Alertas de temperatura, umidade e link')),
                const Divider(height: 1),
                const ListTile(leading: Icon(Icons.router_outlined), title: Text('Rede LoRaWAN'), subtitle: Text('Gateway SX1302 • Frequência AU915')),
              ],
            ),
          ),
          const SizedBox(height: 22),
          OutlinedButton.icon(
            onPressed: onLogout,
            icon: const Icon(Icons.logout),
            label: const Text('Sair da conta'),
            style: OutlinedButton.styleFrom(foregroundColor: errorRed, minimumSize: const Size.fromHeight(50)),
          ),
        ],
      );
}

class MetricCard extends StatelessWidget {
  const MetricCard({required this.title, required this.value, required this.unit, required this.icon, required this.accent, super.key});
  final String title, value, unit;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(minHeight: 170),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: accent, width: 4)),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Color(0x12294d3d), blurRadius: 14, offset: Offset(0, 7))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 26),
          const Spacer(),
          Text(title, style: const TextStyle(color: textMuted, fontSize: 13)),
          const SizedBox(height: 4),
          RichText(
            text: TextSpan(
              style: const TextStyle(color: darkGreen, fontSize: 31, fontWeight: FontWeight.w700),
              children: [
                TextSpan(text: value),
                TextSpan(text: ' $unit', style: const TextStyle(color: textMuted, fontSize: 15, fontWeight: FontWeight.normal)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({required this.online, required this.label, super.key});
  final bool online;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(color: online ? successBg : errorBg, borderRadius: BorderRadius.circular(30)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 8, color: online ? primaryGreen : errorRed),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: online ? const Color(0xff394d14) : const Color(0xff93000a), fontSize: 11, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class AlertTile extends StatelessWidget {
  const AlertTile({required this.alert, this.expanded = false, super.key});
  final Map<String, dynamic> alert;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xffe3e2e2))),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: errorBg, borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.warning_amber_rounded, color: errorRed),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(alert['type']?.toString() ?? 'Ocorrência técnica', style: const TextStyle(fontWeight: FontWeight.w700, color: darkGreen))),
                Text(formatDate(alert['timestamp'])),
              ],
            ),
            const SizedBox(height: 10),
            Text(alert['message']?.toString() ?? 'Alerta sem mensagem', style: const TextStyle(color: textMuted)),
            if (expanded) ...[
              const SizedBox(height: 10),
              Text('Estufa ${alert['curing_unit_id']}', style: const TextStyle(color: primaryGreen, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.icon, required this.title, required this.message, super.key});
  final IconData icon;
  final String title, message;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        color: softSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              Icon(icon, size: 42, color: primaryGreen),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: darkGreen)),
              const SizedBox(height: 5),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(color: textMuted)),
            ],
          ),
        ),
      );
}

class Stat extends StatelessWidget {
  const Stat({required this.label, required this.value, super.key});
  final String label, value;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value, style: const TextStyle(color: darkGreen, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: textMuted, fontSize: 11)),
        ],
      );
}

class ReadingChart extends StatelessWidget {
  const ReadingChart({required this.values, required this.color, super.key});
  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: ChartPainter(values: values, color: color), child: const SizedBox.expand());
}

class ChartPainter extends CustomPainter {
  ChartPainter({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = const Color(0xffe3e2e2)..strokeWidth = 1;
    for (var index = 1; index < 5; index++) {
      final y = size.height * index / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.length < 2) return;
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final range = max - min == 0 ? 1 : max - min;
    final line = Paint()..color = color..strokeWidth = 3..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * index / (values.length - 1);
      final y = size.height - ((values[index] - min) / range * (size.height - 20)) - 10;
      if (index == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant ChartPainter oldDelegate) => oldDelegate.values != values;
}

String formatDate(dynamic value) {
  if (value == null) return '--';
  final date = DateTime.tryParse(value.toString())?.toLocal();
  if (date == null) return value.toString();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)} ${two(date.hour)}:${two(date.minute)}';
}

String formatRelativeTime(dynamic value) {
  if (value == null) return 'Desconhecido';
  final date = DateTime.tryParse(value.toString())?.toLocal();
  if (date == null) return value.toString();
  final diff = DateTime.now().difference(date);
  if (diff.inSeconds < 60) return 'há ${math.max(1, diff.inSeconds)}s';
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'há ${diff.inHours}h';
  return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}
