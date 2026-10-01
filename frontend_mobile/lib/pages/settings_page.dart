import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/background.dart';
import '../core/buzzer.dart';
import '../core/discovery.dart';
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/server_dialog.dart';
import 'shell.dart';

/// Ajustes: exibição, avisos, conta, servidor e legenda das situações.
class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.actions, super.key});

  final ShellActions actions;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  UserProfile? user;
  BackgroundStatus? background;
  bool backgroundBusy = false;
  String? error;
  final _name = TextEditingController();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _server = TextEditingController();
  final _buzzer = PhoneBuzzer();

  ApiClient get api => AppScope.of(context).api;
  AppPrefs get prefs => AppScope.of(context).prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadBackground();
    });
  }

  // Ao voltar das configurações do Android, mostra a permissão atualizada.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadBackground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    _current.dispose();
    _next.dispose();
    _server.dispose();
    _buzzer.dispose();
    super.dispose();
  }

  Future<void> _loadBackground() async {
    final status = await BackgroundMonitor.status();
    if (mounted) setState(() => background = status);
  }

  Future<void> _toggleBackground(bool enable) async {
    setState(() => backgroundBusy = true);
    final prefs = this.prefs;
    String? problem;
    if (enable) {
      problem = await BackgroundMonitor.start();
      await prefs.setBackgroundAlerts(problem == null);
    } else {
      await BackgroundMonitor.stop();
      await prefs.setBackgroundAlerts(false);
    }
    await _loadBackground();
    if (!mounted) return;
    setState(() => backgroundBusy = false);
    if (problem != null) showMessage(context, problem, error: true);
  }

  Future<void> _load() async {
    try {
      final result = UserProfile.fromJson(await api.get('/users/me') as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        user = result;
        _name.text = result.name;
        _server.text = api.baseUrl;
        error = null;
      });
    } on ApiException catch (exception) {
      if (mounted) setState(() => error = exception.message);
    }
  }

  Future<void> _saveName() async {
    try {
      final result = UserProfile.fromJson(await api.patch('/users/me', {'name': _name.text.trim()}) as Map<String, dynamic>);
      if (!mounted) return;
      setState(() => user = result);
      showMessage(context, 'Nome salvo.');
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _changePassword() async {
    try {
      await api.post('/users/me/password', {'current_password': _current.text, 'new_password': _next.text});
      _current.clear();
      _next.clear();
      if (mounted) showMessage(context, 'Senha alterada.');
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _searchServer() async {
    final previous = api.baseUrl;
    final saved = await showServerDialog(context, api, searchOnOpen: true);
    if (saved == null || !mounted) return;
    _server.text = saved;
    if (saved == previous) {
      showMessage(context, 'Este já é o servidor em uso.');
      return;
    }
    showMessage(context, 'Servidor salvo. Entre novamente.');
    await widget.actions.logout();
  }

  Future<void> _saveServer() async {
    final ok = await api.testConnection(_server.text);
    if (!mounted) return;
    if (!ok) {
      showMessage(context, 'Sem resposta de ${_server.text}.', error: true);
      return;
    }
    await api.setBaseUrl(_server.text);
    if (!mounted) return;
    showMessage(context, 'Servidor salvo. Entre novamente.');
    await widget.actions.logout();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorView(title: 'Não foi possível carregar os ajustes', message: error!, onRetry: _load);
    final profile = user;
    if (profile == null) return const LoadingView();

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              SectionCard(
                title: 'Exibição',
                icon: Icons.palette_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Label('Temperatura'),
                    SegmentedButton<TempUnit>(
                      segments: const [
                        ButtonSegment(value: TempUnit.fahrenheit, label: Text('°F')),
                        ButtonSegment(value: TempUnit.celsius, label: Text('°C')),
                      ],
                      selected: {prefs.unit},
                      showSelectedIcon: false,
                      onSelectionChanged: (value) => prefs.setUnit(value.first),
                    ),
                    const SizedBox(height: 16),
                    const _Label('Tema'),
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(value: ThemeMode.system, label: Text('Automático')),
                        ButtonSegment(value: ThemeMode.light, label: Text('Claro')),
                        ButtonSegment(value: ThemeMode.dark, label: Text('Escuro')),
                      ],
                      selected: {prefs.themeMode},
                      showSelectedIcon: false,
                      onSelectionChanged: (value) => prefs.setThemeMode(value.first),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _noticesCard(),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Conta',
                icon: Icons.person_outline,
                subtitle: 'Login: ${profile.login}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nome')),
                    const SizedBox(height: 10),
                    Align(alignment: Alignment.centerRight, child: BusyButton(label: 'Salvar nome', style: BusyButtonStyle.outlined, onPressed: _saveName)),
                    const Divider(height: 28),
                    TextField(controller: _current, obscureText: true, decoration: const InputDecoration(labelText: 'Senha atual')),
                    const SizedBox(height: 12),
                    TextField(controller: _next, obscureText: true, decoration: const InputDecoration(labelText: 'Nova senha', helperText: 'Mínimo de 6 caracteres.')),
                    const SizedBox(height: 10),
                    Align(alignment: Alignment.centerRight, child: BusyButton(label: 'Trocar senha', style: BusyButtonStyle.outlined, onPressed: _changePassword)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Servidor',
                icon: Icons.dns_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Endereço da API', hintText: 'http://192.168.1.2:8000'),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (discoverySupported)
                          OutlinedButton.icon(onPressed: _searchServer, icon: const Icon(Icons.wifi_find), label: const Text('Procurar na rede')),
                        BusyButton(label: 'Testar e salvar', onPressed: _saveServer),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const _LegendCard(),
              const SizedBox(height: 18),
              BusyButton(label: 'Sair da conta', icon: Icons.logout, style: BusyButtonStyle.danger, onPressed: widget.actions.logout),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noticesCard() {
    final status = background;
    final enabled = prefs.backgroundAlerts && (status?.running ?? false);
    return SectionCard(
      title: 'Avisos',
      icon: Icons.notifications_active_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: prefs.phoneBuzzer,
            onChanged: prefs.setPhoneBuzzer,
            title: const Text('Tocar no celular', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Bipa e vibra quando uma saída liga.'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: _buzzer.play, icon: const Icon(Icons.volume_up), label: const Text('Testar som')),
          ),
          const Divider(height: 20),
          if (!BackgroundMonitor.supported)
            Text('Avisos com o app fechado: só no app Android.', style: TextStyle(color: context.colors.textSecondary))
          else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: enabled,
              onChanged: backgroundBusy ? null : _toggleBackground,
              title: const Text('Avisar com o app fechado', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Notifica alertas e acionamentos. O Android mostra o aviso fixo "Estufa monitorada".'),
            ),
            if (status != null && !status.permissionGranted)
              const _Fix(text: 'Notificações bloqueadas', action: 'Permitir', onPressed: BackgroundMonitor.openNotificationSettings),
            if (status != null && !status.batteryUnrestricted)
              const _Fix(text: 'Economia de bateria pode pausar os avisos', action: 'Ajustar', onPressed: BackgroundMonitor.openBatterySettings),
          ],
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}

/// Pendência de permissão do Android, com o atalho para resolver.
class _Fix extends StatelessWidget {
  const _Fix({required this.text, required this.action, required this.onPressed});

  final String text;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(Icons.error_outline, size: 18, color: context.colors.warn),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
      TextButton(onPressed: onPressed, child: Text(action)),
    ]);
  }
}

/// O que significa cada situação mostrada nas estufas e nos alertas.
class _LegendCard extends StatelessWidget {
  const _LegendCard();

  @override
  Widget build(BuildContext context) {
    const items = [
      (StatusKind.ok, 'Normal', Icons.check, 'Temperatura e umidade dentro do esperado para a fase.'),
      (StatusKind.warn, 'Fora da faixa', Icons.swap_vert, 'Algum valor saiu do esperado, ainda sem alerta.'),
      (StatusKind.warn, 'Atenção', Icons.warning_amber_rounded, 'Alerta aberto. Acompanhe a estufa.'),
      (StatusKind.crit, 'Crítico', Icons.error, 'Risco para a cura. Aja agora.'),
      (StatusKind.offline, 'Sem sinal', Icons.cloud_off, 'O sensor não envia leituras há mais de 90 s.'),
      (StatusKind.neutral, 'Parada', Icons.pause, 'Secagem desligada: nada é gravado e não há alertas.'),
    ];
    return SectionCard(
      title: 'Legenda',
      icon: Icons.help_outline,
      child: Column(
        children: [
          for (final (kind, label, icon, text) in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 130, child: Align(alignment: Alignment.centerLeft, child: StatusBadge(kind: kind, label: label, icon: icon))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, color: context.colors.textSecondary))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
