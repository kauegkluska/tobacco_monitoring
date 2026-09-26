import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/discovery.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/server_dialog.dart';

enum _AuthMode { login, register, forgot }

/// Entrada: login, cadastro e recuperação de senha.
class LoginPage extends StatefulWidget {
  const LoginPage({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _login = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();

  _AuthMode mode = _AuthMode.login;
  bool busy = false;
  bool codeRequested = false;
  bool showPassword = false;
  String? error;
  String? info;
  bool searchingServer = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoDiscover());
  }

  @override
  void dispose() {
    _name.dispose();
    _login.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  void _switch(_AuthMode next) {
    setState(() {
      mode = next;
      error = null;
      info = null;
      codeRequested = false;
      _password.clear();
      _code.clear();
    });
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final api = AppScope.of(context).api;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      switch (mode) {
        case _AuthMode.login:
          await api.login(_login.text.trim(), _password.text);
          widget.onAuthenticated();
        case _AuthMode.register:
          await api.register(_name.text.trim(), _login.text.trim(), _password.text);
          widget.onAuthenticated();
        case _AuthMode.forgot:
          if (!codeRequested) {
            final result = await api.postPublic('/auth/password-reset/request', {'login': _login.text.trim()}) as Map<String, dynamic>;
            final token = result['reset_token']?.toString();
            setState(() {
              codeRequested = true;
              if (token != null) _code.text = token;
              info = token != null
                  ? 'Código gerado e preenchido abaixo (modo de desenvolvimento). Ele vale por 15 minutos.'
                  : 'Se o login existir, o código foi enviado ao responsável pelo sistema. Ele vale por 15 minutos.';
            });
          } else {
            await api.postPublic('/auth/password-reset/confirm', {
              'login': _login.text.trim(),
              'reset_token': _code.text.trim(),
              'new_password': _password.text,
            });
            if (!mounted) return;
            showMessage(context, 'Senha atualizada. Entre com a nova senha.');
            _switch(_AuthMode.login);
          }
      }
    } on ApiException catch (exception) {
      setState(() => error = exception.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _editServer() async {
    final saved = await showServerDialog(context, AppScope.of(context).api);
    if (saved == null || !mounted) return;
    setState(() {});
    showMessage(context, 'Servidor conectado.');
  }

  /// Na primeira abertura, procura o servidor na rede em vez de pedir o IP.
  Future<void> _autoDiscover() async {
    final api = AppScope.of(context).api;
    if (!discoverySupported || api.hasSavedBaseUrl) return;
    setState(() => searchingServer = true);
    final found = await discoverAndSave(api);
    if (!mounted) return;
    setState(() {
      searchingServer = false;
      if (found != null) info = 'Servidor encontrado na rede: ${Uri.parse(found).authority}.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.of(context).api;
    final titles = {
      _AuthMode.login: 'Entrar na plataforma',
      _AuthMode.register: 'Criar conta de produtor',
      _AuthMode.forgot: 'Recuperar senha',
    };
    final submitLabel = switch (mode) {
      _AuthMode.login => 'Entrar',
      _AuthMode.register => 'Criar conta',
      _AuthMode.forgot => codeRequested ? 'Salvar nova senha' : 'Gerar código',
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 20),
                  child: Form(
                    key: _formKey,
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(color: const Color(0xff2e7d32), borderRadius: BorderRadius.circular(18)),
                              child: const Icon(Icons.eco, color: Colors.white, size: 34),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'MONITOR DE ESTUFA',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: context.scheme.primary, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2),
                          ),
                          const SizedBox(height: 4),
                          Text(titles[mode]!, textAlign: TextAlign.center, style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 22),
                          if (mode != _AuthMode.forgot) ...[
                            SegmentedButton<_AuthMode>(
                              segments: const [
                                ButtonSegment(value: _AuthMode.login, label: Text('Entrar')),
                                ButtonSegment(value: _AuthMode.register, label: Text('Criar conta')),
                              ],
                              selected: {mode},
                              showSelectedIcon: false,
                              onSelectionChanged: (value) => _switch(value.first),
                            ),
                            const SizedBox(height: 20),
                          ],
                          FormErrorText(error),
                          if (info != null)
                            Container(
                              margin: const EdgeInsets.only(bottom: 14),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: context.colors.okContainer, borderRadius: BorderRadius.circular(10)),
                              child: Text(info!, style: TextStyle(color: context.colors.onOkContainer)),
                            ),
                          if (mode == _AuthMode.register) ...[
                            TextFormField(
                              controller: _name,
                              textCapitalization: TextCapitalization.words,
                              autofillHints: const [AutofillHints.name],
                              decoration: const InputDecoration(labelText: 'Seu nome'),
                              validator: (value) => (value ?? '').trim().length < 2 ? 'Informe seu nome.' : null,
                            ),
                            const SizedBox(height: 14),
                          ],
                          TextFormField(
                            controller: _login,
                            autocorrect: false,
                            autofillHints: const [AutofillHints.username],
                            decoration: InputDecoration(
                              labelText: 'Login',
                              helperText: mode == _AuthMode.register ? 'Pelo menos 3 caracteres. Você vai usar para entrar.' : null,
                            ),
                            validator: (value) {
                              final text = (value ?? '').trim();
                              if (text.isEmpty) return 'Informe o login.';
                              if (mode == _AuthMode.register && text.length < 3) return 'Use pelo menos 3 caracteres.';
                              return null;
                            },
                          ),
                          if (mode == _AuthMode.forgot && codeRequested) ...[
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _code,
                              autocorrect: false,
                              decoration: const InputDecoration(labelText: 'Código de redefinição'),
                              validator: (value) => (value ?? '').trim().isEmpty ? 'Informe o código.' : null,
                            ),
                          ],
                          if (mode != _AuthMode.forgot || codeRequested) ...[
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _password,
                              obscureText: !showPassword,
                              autofillHints: [mode == _AuthMode.login ? AutofillHints.password : AutofillHints.newPassword],
                              onFieldSubmitted: (_) => _submit(),
                              decoration: InputDecoration(
                                labelText: mode == _AuthMode.forgot ? 'Nova senha' : 'Senha',
                                helperText: mode == _AuthMode.login ? null : 'Pelo menos 6 caracteres.',
                                suffixIcon: IconButton(
                                  tooltip: showPassword ? 'Ocultar senha' : 'Mostrar senha',
                                  icon: Icon(showPassword ? Icons.visibility_off : Icons.visibility),
                                  onPressed: () => setState(() => showPassword = !showPassword),
                                ),
                              ),
                              validator: (value) {
                                final text = value ?? '';
                                if (text.isEmpty) return 'Informe a senha.';
                                if (mode != _AuthMode.login && text.length < 6) return 'Use pelo menos 6 caracteres.';
                                return null;
                              },
                            ),
                          ],
                          const SizedBox(height: 22),
                          FilledButton(
                            onPressed: busy ? null : _submit,
                            child: busy
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : Text(submitLabel),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => _switch(mode == _AuthMode.forgot ? _AuthMode.login : _AuthMode.forgot),
                            child: Text(mode == _AuthMode.forgot ? 'Voltar para o login' : 'Esqueci minha senha'),
                          ),
                          const Divider(height: 24),
                          Row(
                            children: [
                              Icon(Icons.dns_outlined, size: 18, color: context.colors.muted),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  searchingServer ? 'Procurando o servidor na rede…' : api.baseUrl,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: context.colors.muted, fontSize: 13),
                                ),
                              ),
                              TextButton(onPressed: _editServer, child: const Text('Alterar')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
