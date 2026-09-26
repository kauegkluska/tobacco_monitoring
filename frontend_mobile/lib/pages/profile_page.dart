import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/background.dart';
import '../core/discovery.dart';
import '../core/buzzer.dart';
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/server_dialog.dart';
import 'shell.dart';

/// Perfil: conta, senha, preferências de exibição, servidor e ajuda rápida.
class ProfilePage extends StatefulWidget {
  const ProfilePage({required this.actions, super.key});

  final ShellActions actions;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> with WidgetsBindingObserver {
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
    if (problem != null) {
      showMessage(context, problem, error: true);
    } else {
      showMessage(context, enable ? 'Pronto: os avisos chegam mesmo com o app fechado.' : 'Avisos com o app fechado desligados.');
    }
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
      showMessage(context, 'Nome atualizado.');
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
      showMessage(context, 'Não houve resposta de ${_server.text}.', error: true);
      return;
    }
    await api.setBaseUrl(_server.text);
    if (!mounted) return;
    showMessage(context, 'Servidor salvo. Entre novamente.');
    await widget.actions.logout();
  }

  Widget _backgroundCard() {
    if (!BackgroundMonitor.supported) {
      return SectionCard(
        title: 'Notificações com o app fechado',
        icon: Icons.notifications_active_outlined,
        child: Text(
          'Disponível no app Android instalado (APK). No navegador, os avisos aparecem enquanto a página estiver aberta.',
          style: TextStyle(color: context.colors.textSecondary),
        ),
      );
    }
    final status = background;
    final enabled = prefs.backgroundAlerts && (status?.running ?? false);
    return SectionCard(
      title: 'Notificações com o app fechado',
      icon: Icons.notifications_active_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: backgroundBusy ? null : _toggleBackground,
            title: const Text('Avisar mesmo com o app fechado', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text(
              'O celular consulta o servidor a cada 15 s e notifica quando o gateway toca o aviso sonoro ou um alerta abre. '
              'Enquanto estiver ativo, o Android mostra o aviso fixo "Estufa monitorada".',
            ),
          ),
          if (status != null) ...[
            _PermissionRow(
              ok: status.permissionGranted,
              title: status.permissionGranted ? 'Notificações permitidas' : 'Notificações bloqueadas',
              text: status.permissionGranted
                  ? 'O app pode mostrar avisos na barra de notificações.'
                  : 'Sem esta permissão nenhum aviso aparece com o app fechado.',
              action: status.permissionGranted
                  ? null
                  : const TextButton(onPressed: BackgroundMonitor.openNotificationSettings, child: Text('Abrir configurações')),
            ),
            _PermissionRow(
              ok: status.batteryUnrestricted,
              title: status.batteryUnrestricted ? 'Bateria sem restrição' : 'Economia de bateria ativa',
              text: status.batteryUnrestricted
                  ? 'O Android não vai pausar o monitoramento.'
                  : 'O Android pode pausar o monitoramento. Escolha "Sem restrições" para este app.',
              action: status.batteryUnrestricted
                  ? null
                  : const TextButton(onPressed: BackgroundMonitor.openBatterySettings, child: Text('Ajustar bateria')),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'O celular precisa alcançar o servidor (mesma rede Wi-Fi do computador, ou o servidor publicado na internet).',
            style: TextStyle(fontSize: 12.5, color: context.colors.muted),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorView(title: 'Não foi possível carregar o perfil', message: error!, onRetry: _load);
    final profile = user;
    if (profile == null) return const LoadingView();

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          PageHeader(eyebrow: 'Perfil', title: profile.name, subtitle: 'Login: ${profile.login}'),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Exibição',
            icon: Icons.palette_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Unidade de temperatura', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SegmentedButton<TempUnit>(
                  segments: const [
                    ButtonSegment(value: TempUnit.fahrenheit, label: Text('Fahrenheit (°F)')),
                    ButtonSegment(value: TempUnit.celsius, label: Text('Celsius (°C)')),
                  ],
                  selected: {prefs.unit},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) => prefs.setUnit(value.first),
                ),
                const SizedBox(height: 6),
                Text('O sensor mede em Celsius; a conversão é feita só na tela.', style: TextStyle(fontSize: 12.5, color: context.colors.muted)),
                const SizedBox(height: 16),
                const Text('Tema', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
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
          const SizedBox(height: 14),
          SectionCard(
            title: 'Aviso sonoro',
            icon: Icons.campaign_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: prefs.phoneBuzzer,
                  onChanged: prefs.setPhoneBuzzer,
                  title: const Text('Tocar também no celular', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Quando o gateway tocar o aviso (uma saída ligou), o celular bipa e vibra. Funciona com o app aberto.'),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(onPressed: _buzzer.play, icon: const Icon(Icons.volume_up), label: const Text('Testar som')),
                ),
                const SizedBox(height: 6),
                Text(
                  'Os modos das saídas ficam no Início, em "Saídas e aviso sonoro".',
                  style: TextStyle(fontSize: 12.5, color: context.colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _backgroundCard(),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Sua conta',
            icon: Icons.person_outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nome')),
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: BusyButton(label: 'Salvar nome', onPressed: _saveName)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Senha',
            icon: Icons.lock_outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(controller: _current, obscureText: true, decoration: const InputDecoration(labelText: 'Senha atual')),
                const SizedBox(height: 12),
                TextField(controller: _next, obscureText: true, decoration: const InputDecoration(labelText: 'Nova senha', helperText: 'Pelo menos 6 caracteres.')),
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: BusyButton(label: 'Trocar senha', onPressed: _changePassword)),
              ],
            ),
          ),
          const SizedBox(height: 14),
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
                  decoration: const InputDecoration(
                    labelText: 'Endereço da API',
                    helperText: 'IP do computador que roda o backend, por exemplo http://192.168.1.2:8000.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
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
          const SizedBox(height: 14),
          const _HelpCard(),
          const SizedBox(height: 18),
          BusyButton(label: 'Sair da conta', icon: Icons.logout, style: BusyButtonStyle.danger, onPressed: widget.actions.logout),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.ok, required this.title, required this.text, this.action});

  final bool ok;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline, size: 20, color: ok ? context.colors.ok : context.colors.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(text, style: TextStyle(fontSize: 13, color: context.colors.textSecondary)),
                if (action != null) Align(alignment: Alignment.centerLeft, child: action!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard();

  @override
  Widget build(BuildContext context) {
    const flow = [
      (Icons.thermostat, '1. Sender', 'Na estufa, lê temperatura e umidade (SHT40) e transmite por rádio LoRa.'),
      (Icons.sensors, '2. Receiver', 'O gateway recebe o rádio, envia as leituras ao servidor pelo Wi-Fi e recebe de volta o comando das saídas.'),
      (Icons.space_dashboard_outlined, '3. App', 'O servidor grava o histórico, confere os limites e mostra tudo aqui.'),
    ];
    const statuses = [
      ('Sensor online', 'O sender enviou uma leitura nos últimos 90 segundos.'),
      ('Sensor offline', 'Nenhuma leitura recente. Verifique energia, antena LoRa e o Wi-Fi do gateway.'),
      ('Secagem parada', 'O sensor pode estar enviando, mas as leituras não são gravadas nem geram alertas.'),
      ('Alerta crítico', 'Temperatura acima do máximo definido. Exige atenção imediata.'),
      ('Alerta de atenção', 'Temperatura abaixo do mínimo ou umidade fora da faixa.'),
      ('Saída no automático', 'Liga quando o valor sai da faixa segura e desliga quando volta com folga. Com a secagem parada, fica desligada.'),
      ('Aviso sonoro', 'O gateway bipa por 2 segundos sempre que uma saída liga.'),
    ];
    return SectionCard(
      title: 'Como funciona',
      icon: Icons.help_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (icon, title, text) in flow)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: context.colors.surface2, borderRadius: BorderRadius.circular(12)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: context.scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(text, style: TextStyle(color: context.colors.textSecondary, fontSize: 13.5)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          for (final (term, description) in statuses)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(term, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(description, style: TextStyle(color: context.colors.textSecondary, fontSize: 13.5)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
