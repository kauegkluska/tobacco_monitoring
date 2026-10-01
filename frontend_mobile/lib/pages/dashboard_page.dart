import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/buzzer.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/line_chart.dart';
import '../widgets/phases.dart';
import 'shell.dart';

/// Início: situação atual da estufa em linguagem simples.
class DashboardPage extends StatefulWidget {
  const DashboardPage({required this.actions, super.key});

  final ShellActions actions;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const _pollInterval = Duration(seconds: 5);
  static const _seriesInterval = Duration(seconds: 60);
  static const _chartHours = 6;

  Overview? overview;
  CuringUnit? unit;
  Reading? latest;
  List<AlertItem> alerts = [];
  Outputs? outputs;
  Series? series;
  int? seriesUnitId;
  DateTime? seriesLoadedAt;
  String? error;
  Timer? timer;

  ApiClient get api => AppScope.of(context).api;
  AppPrefs get prefs => AppScope.of(context).prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    timer?.cancel();
    // Capturados antes dos awaits: a tela pode sair de cena durante o carregamento.
    final api = this.api;
    final prefs = this.prefs;
    try {
      final nextOverview = await loadOverview(api);
      final nextUnit = nextOverview.pick(prefs.unitId);
      Reading? nextLatest;
      var nextAlerts = <AlertItem>[];
      Outputs? nextOutputs;
      if (nextUnit != null) {
        final needsSeries = seriesUnitId != nextUnit.id ||
            seriesLoadedAt == null ||
            DateTime.now().difference(seriesLoadedAt!) > _seriesInterval;
        final since = DateTime.now().toUtc().subtract(const Duration(hours: _chartHours)).toIso8601String();
        final results = await Future.wait([
          api.getOrNull('/curing_units/${nextUnit.id}/latest'),
          api.get('/curing_units/${nextUnit.id}/alerts?active=true'),
          api.get('/curing_units/${nextUnit.id}/outputs?events=5'),
          if (needsSeries) api.get('/curing_units/${nextUnit.id}/series?since=${Uri.encodeQueryComponent(since)}&points=144'),
        ]);
        nextLatest = results[0] == null ? null : Reading.fromJson(results[0] as Map<String, dynamic>);
        nextAlerts = (results[1] as List).map((item) => AlertItem.fromJson(item as Map<String, dynamic>)).toList();
        nextOutputs = Outputs.fromJson(results[2] as Map<String, dynamic>);
        if (needsSeries) {
          series = Series.fromJson(results[3] as Map<String, dynamic>);
          seriesUnitId = nextUnit.id;
          seriesLoadedAt = DateTime.now();
        }
      }
      if (!mounted) return;
      setState(() {
        overview = nextOverview;
        unit = nextUnit;
        latest = nextLatest;
        alerts = nextAlerts;
        outputs = nextOutputs;
        error = null;
      });
    } on ApiException catch (exception) {
      if (!mounted) return;
      if (overview == null) {
        setState(() => error = exception.message);
      } else {
        showMessage(context, exception.message, error: true);
      }
    } finally {
      if (mounted) timer = Timer(_pollInterval, _load);
    }
  }

  Future<void> _startDrying(CuringUnit target) async {
    try {
      final started = await api.post('/curing_units/${target.id}/start-drying') as Map<String, dynamic>;
      if (!mounted) return;
      showMessage(context, 'Secagem iniciada na fase de ${started['curing_stage']}. As leituras passam a ser gravadas.');
      seriesUnitId = null;
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _advanceStage(CuringUnit target, PhaseStatus phase) async {
    final finishing = phase.finishes;
    final pending = [for (final check in phase.checks) if (!check.ok) check.label.toLowerCase()];
    final confirmed = await confirmAction(
      context,
      title: finishing ? 'Finalizar a cura?' : 'Avançar para ${phase.nextStage}?',
      message: [
        'Confira nas folhas: ${phase.visualCheck}',
        pending.isEmpty ? 'As condições de tempo, temperatura e umidade foram atingidas.' : 'Ainda não atingido: ${pending.join('; ')}.',
        finishing
            ? 'A secagem será encerrada e as leituras deixam de ser gravadas.'
            : 'Os alarmes e as saídas automáticas passam a usar a faixa da nova fase.',
      ].join('\n\n'),
      confirmLabel: finishing ? 'Finalizar cura' : 'Avançar fase',
    );
    if (!confirmed) return;
    try {
      await api.post('/curing_units/${target.id}/advance-stage');
      if (!mounted) return;
      showMessage(context, finishing ? 'Cura finalizada.' : 'Fase alterada para "${phase.nextStage}".');
      seriesUnitId = null;
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _stopDrying(CuringUnit target) async {
    final confirmed = await confirmAction(
      context,
      title: 'Parar a secagem?',
      message: 'Enquanto a secagem estiver parada, as leituras do sensor não são gravadas e nenhum alerta é gerado.',
      confirmLabel: 'Parar secagem',
      danger: true,
    );
    if (!confirmed) return;
    try {
      await api.post('/curing_units/${target.id}/stop-drying');
      if (!mounted) return;
      showMessage(context, 'Secagem parada.');
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _setOutputMode(CuringUnit target, String output, String mode) async {
    final name = (output == 'temperature' ? outputs?.temperature : outputs?.humidity)?.name ?? 'Saída';
    if (mode == 'on') {
      final confirmed = await confirmAction(
        context,
        title: 'Ligar "$name"?',
        message: 'Ela fica ligada até você escolher Automático ou Desligada. '
            'O gateway recebe o comando na próxima leitura e toca o aviso sonoro por 2 segundos.',
        confirmLabel: 'Ligar saída',
      );
      if (!confirmed) return;
    }
    try {
      final result = await api.patch('/curing_units/${target.id}/outputs', {'${output}_mode': mode});
      if (!mounted) return;
      setState(() => outputs = Outputs.fromJson(result as Map<String, dynamic>));
      showMessage(context, switch (mode) {
        'on' => '"$name" ligada. O sender recebe o comando em alguns segundos.',
        'off' => '"$name" desligada.',
        _ => '"$name" no automático.',
      });
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _editOutput(CuringUnit target, String output, OutputState state) async {
    final name = TextEditingController(text: state.name);
    var trigger = state.trigger;
    String? sheetError;
    await showFormSheet<void>(
      context,
      title: 'Editar saída',
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormErrorText(sheetError),
            Text(
              '${state.relayLabel} do sender. O nome aparece no app, no painel e nas notificações.',
              style: TextStyle(color: context.colors.textSecondary),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Ventoinhas, Queimador, Umidificador'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: trigger,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'No automático, liga quando…',
                helperText: 'A faixa segura muda com a fase da cura em andamento.',
                helperMaxLines: 2,
              ),
              items: [
                for (final entry in outputTriggers.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => setSheetState(() => trigger = value ?? trigger),
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: 'Salvar',
              onPressed: () async {
                final newName = name.text.trim();
                if (newName.isEmpty) {
                  setSheetState(() => sheetError = 'Informe um nome para a saída.');
                  return;
                }
                try {
                  final result = await api.patch('/curing_units/${target.id}/outputs', {
                    '${output}_name': newName,
                    '${output}_trigger': trigger,
                  });
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (!mounted) return;
                  setState(() => outputs = Outputs.fromJson(result as Map<String, dynamic>));
                  showMessage(context, 'Saída "$newName" atualizada.');
                } on ApiException catch (exception) {
                  setSheetState(() => sheetError = exception.message);
                }
              },
            ),
          ],
        ),
      ),
    );
    name.dispose();
  }

  Future<void> _changeStage(CuringUnit target, String stage) async {
    try {
      await api.patch('/curing_units/${target.id}', {'curing_stage': stage});
      if (!mounted) return;
      showMessage(context, 'Fase alterada para "$stage".');
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _editDuration(CuringUnit target) async {
    final controller = TextEditingController(text: target.estimatedHours?.round().toString() ?? '');
    String? sheetError;
    await showFormSheet<void>(
      context,
      title: 'Duração prevista da secagem',
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormErrorText(sheetError),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Duração total',
                suffixText: 'horas',
                helperText: 'Uma cura completa costuma levar de 5 a 7 dias (120 a 168 horas).',
              ),
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: 'Salvar',
              onPressed: () async {
                final hours = double.tryParse(controller.text.replaceAll(',', '.'));
                if (hours == null || hours <= 0) {
                  setSheetState(() => sheetError = 'Informe a duração em horas.');
                  return;
                }
                try {
                  await api.patch('/curing_units/${target.id}', {'estimated_duration_hours': hours});
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (mounted) showMessage(context, 'Duração atualizada.');
                  await _load();
                } on ApiException catch (exception) {
                  setSheetState(() => sheetError = exception.message);
                }
              },
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return ErrorView(title: 'Não foi possível carregar o painel', message: error!, onRetry: _load);
    }
    final data = overview;
    if (data == null) return const LoadingView(message: 'Buscando dados da estufa…');

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final current = unit;
        final device = data.deviceFor(current);
        final limits = current?.limitsWith(device) ?? Limits.defaults;
        final children = <Widget>[
          _header(data, current, device),
          if (current == null) _onboarding(data, null, null),
          if (current != null) ...[
            _statusBanner(current, device, limits),
            if ((device == null || !current.isDrying) && latest == null) _onboarding(data, current, device),
            _KpiCard(kind: _KpiKind.temperature, reading: latest, device: device, limits: limits, unit: prefs.unit, byPhase: current.phase != null),
            _KpiCard(kind: _KpiKind.humidity, reading: latest, device: device, limits: limits, unit: prefs.unit, byPhase: current.phase != null),
            _outputsCard(current, device),
            _chartCard(current, limits),
            _dryingCard(current),
            _alertsCard(current),
          ],
        ];

        return RefreshIndicator(
          onRefresh: () {
            seriesUnitId = null;
            return _load();
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: children.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (_, index) => children[index],
          ),
        );
      },
    );
  }

  Widget _header(Overview data, CuringUnit? current, Device? device) {
    final badges = <Widget>[];
    if (current != null) {
      final phase = current.phase;
      badges.add(PhaseTag(
        label: phase == null ? current.stage : 'Fase ${phase.number} de ${phase.total} · ${current.stage}',
        color: context.colors.phase(phaseKeyOf(current.stage)),
      ));
      if (device == null) {
        badges.add(const StatusBadge(kind: StatusKind.neutral, label: 'Sem sensor', icon: Icons.link_off));
      } else if (device.online) {
        badges.add(const StatusBadge(kind: StatusKind.ok, label: 'Sensor online'));
      } else {
        badges.add(const StatusBadge(kind: StatusKind.offline, label: 'Sensor offline', icon: Icons.cloud_off));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeader(eyebrow: 'Visão geral', title: current?.name ?? 'Bem-vindo'),
        if (badges.isNotEmpty) ...[const SizedBox(height: 8), Wrap(spacing: 8, runSpacing: 8, children: badges)],
        if (data.units.length > 1) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: ValueKey('unit-${current?.id}'),
            initialValue: current?.id,
            decoration: const InputDecoration(labelText: 'Estufa', prefixIcon: Icon(Icons.warehouse_outlined)),
            items: [for (final item in data.units) DropdownMenuItem(value: item.id, child: Text(item.name, overflow: TextOverflow.ellipsis))],
            onChanged: (value) {
              prefs.setUnitId(value);
              seriesUnitId = null;
              _load();
            },
          ),
        ],
      ],
    );
  }

  Widget _statusBanner(CuringUnit current, Device? device, Limits limits) {
    if (device == null) {
      return StatusBanner(
        kind: StatusKind.info,
        icon: Icons.info_outline,
        title: 'Esta estufa ainda não tem sensor vinculado',
        text: 'Vincule o dispositivo ESP32 (sender) para começar a receber temperatura e umidade.',
        actions: [
          FilledButton.icon(
            onPressed: () => widget.actions.goTo(AppTab.units, intent: UnitsIntent(linkUnitId: current.id)),
            icon: const Icon(Icons.link),
            label: const Text('Vincular sensor'),
          ),
        ],
      );
    }
    if (!device.online) {
      return StatusBanner(
        kind: StatusKind.offline,
        icon: Icons.cloud_off,
        title: 'Sensor sem sinal ${device.lastSeen == null ? 'desde o cadastro' : f.relative(device.lastSeen)}',
        text: 'Confira se o sender está ligado, se o gateway (receiver) tem Wi-Fi e se o servidor está acessível na rede.',
      );
    }
    if (!current.isDrying) {
      return StatusBanner(
        kind: StatusKind.warn,
        icon: Icons.warning_amber_rounded,
        title: 'Secagem não iniciada: as leituras não estão sendo gravadas',
        text: 'O sensor está enviando dados, mas o histórico e os alertas só funcionam com a secagem em andamento.',
        actions: [BusyButton(label: 'Iniciar secagem', icon: Icons.play_arrow, onPressed: () => _startDrying(current))],
      );
    }
    final critical = alerts.where((alert) => alert.isCritical).toList();
    if (critical.isNotEmpty) {
      return StatusBanner(
        kind: StatusKind.crit,
        icon: Icons.error,
        title: critical.any((alert) => alert.isEmergency)
            ? 'Emergência nesta estufa'
            : '${f.plural(critical.length, 'alerta crítico', 'alertas críticos')} nesta estufa',
        text: critical.first.message,
        actions: [OutlinedButton(onPressed: () => widget.actions.goTo(AppTab.alerts), child: const Text('Ver alertas'))],
      );
    }
    if (alerts.isNotEmpty) {
      return StatusBanner(
        kind: StatusKind.warn,
        icon: Icons.warning_amber_rounded,
        title: f.plural(alerts.length, 'alerta ativo', 'alertas ativos'),
        text: alerts.first.message,
        actions: [OutlinedButton(onPressed: () => widget.actions.goTo(AppTab.alerts), child: const Text('Ver alertas'))],
      );
    }
    final reading = latest;
    final tempOk = rangeState(reading?.temperature, limits.tempMin, limits.tempMax) == 'ok';
    final humidityOk = rangeState(reading?.humidity, limits.humidityMin, limits.humidityMax) == 'ok';
    if (tempOk && humidityOk) {
      return StatusBanner(
        kind: StatusKind.ok,
        icon: Icons.check_circle,
        title: 'Tudo certo',
        text: 'Temperatura e umidade estão dentro da faixa da fase de ${current.stage}.',
      );
    }
    return const StatusBanner(
      kind: StatusKind.info,
      icon: Icons.schedule,
      title: 'Aguardando as próximas leituras',
      text: 'Assim que chegarem, os valores aparecem aqui automaticamente.',
    );
  }

  Widget _onboarding(Overview data, CuringUnit? current, Device? device) {
    final steps = [
      (
        done: data.units.isNotEmpty,
        title: 'Cadastre a estufa',
        text: 'Dê um nome para a estufa que será monitorada.',
        action: FilledButton.icon(
          onPressed: () => widget.actions.goTo(AppTab.units, intent: const UnitsIntent(createUnit: true)),
          icon: const Icon(Icons.add),
          label: const Text('Cadastrar estufa'),
        ) as Widget?,
      ),
      (
        done: device != null,
        title: 'Vincule o sensor ESP32',
        text: 'Leia o QR code do sender ou digite o ID do controlador (ex.: ESP32-TOBACCO-01).',
        action: FilledButton.icon(
          onPressed: () => widget.actions.goTo(AppTab.units, intent: UnitsIntent(linkUnitId: current?.id)),
          icon: const Icon(Icons.link),
          label: const Text('Vincular sensor'),
        ) as Widget?,
      ),
      (
        done: current?.isDrying ?? false,
        title: 'Inicie a secagem',
        text: 'A partir daí as leituras são gravadas e os alertas passam a funcionar.',
        action: current == null ? null : BusyButton(label: 'Iniciar secagem', icon: Icons.play_arrow, onPressed: () => _startDrying(current)) as Widget?,
      ),
    ];
    final currentIndex = steps.indexWhere((step) => !step.done);

    return SectionCard(
      title: 'Primeiros passos',
      icon: Icons.help_outline,
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            Container(
              margin: EdgeInsets.only(top: i == 0 ? 0 : 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: i == currentIndex ? context.scheme.primaryContainer : context.colors.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: steps[i].done ? const Color(0xff2e7d32) : context.scheme.surface,
                    foregroundColor: steps[i].done ? Colors.white : context.scheme.onSurface,
                    child: steps[i].done ? const Icon(Icons.check, size: 18) : Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(steps[i].title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(steps[i].text, style: TextStyle(color: context.colors.textSecondary)),
                        if (i == currentIndex && steps[i].action != null) ...[const SizedBox(height: 10), steps[i].action!],
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _chartCard(CuringUnit current, Limits limits) {
    final unit = prefs.unit;
    final now = DateTime.now();
    final points = [
      for (final point in series?.points ?? const <SeriesPoint>[])
        ChartPoint(point.time, f.tempValue(point.temperature, unit)!, count: point.count),
    ];
    final phases = series == null ? const <ChartPhase>[] : chartPhasesOf(series!, context.colors, temperature: true, unit: unit);
    return SectionCard(
      title: 'Temperatura nas últimas 6 horas',
      icon: Icons.show_chart,
      subtitle: current.phase == null
          ? 'A faixa verde clara é a zona segura. Toque no gráfico para ver os valores.'
          : 'O fundo mostra a fase da cura; a faixa verde clara é a zona segura de cada fase.',
      trailing: TextButton(onPressed: () => widget.actions.goTo(AppTab.history), child: const Text('Histórico')),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LineChart(
            points: points,
            start: now.subtract(const Duration(hours: _chartHours)),
            end: now,
            limitMin: phases.isNotEmpty ? null : f.tempValue(limits.tempMin, unit),
            limitMax: phases.isNotEmpty ? null : f.tempValue(limits.tempMax, unit),
            phases: phases,
            format: (value) => '${f.number(value)} ${f.unitSymbol(unit)}',
            detail: (point) => f.plural(point.count, 'leitura'),
            gap: Duration(seconds: ((series?.bucketSeconds ?? 0) * 3).clamp(300, 1 << 30)),
            height: 220,
            semanticLabel: 'Temperatura nas últimas 6 horas',
            emptyText: 'Nenhuma leitura gravada nas últimas 6 horas.',
          ),
          if (phases.length > 1) PhaseLegend(phases: phases),
        ],
      ),
    );
  }

  Widget _outputsCard(CuringUnit current, Device? device) {
    final data = outputs;
    final last = data?.lastBuzzer;
    final recent = last != null && DateTime.now().difference(last.timestamp) < const Duration(minutes: 2);

    return SectionCard(
      title: 'Saídas e aviso sonoro',
      icon: Icons.campaign_outlined,
      subtitle: 'Relés do sender, como ventoinhas ou queimador. O gateway toca um aviso de 2 segundos sempre que uma saída liga.',
      child: data == null
          ? Text('Carregando…', style: TextStyle(color: context.colors.muted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OutputRow(
                  state: data.humidity,
                  confirmedAt: data.confirmedAt,
                  onMode: (mode) => _setOutputMode(current, 'humidity', mode),
                  onEdit: () => _editOutput(current, 'humidity', data.humidity),
                ),
                const Divider(height: 28),
                _OutputRow(
                  state: data.temperature,
                  confirmedAt: data.confirmedAt,
                  onMode: (mode) => _setOutputMode(current, 'temperature', mode),
                  onEdit: () => _editOutput(current, 'temperature', data.temperature),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: recent ? context.colors.warnContainer : context.colors.surface2,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(last == null ? Icons.volume_off_outlined : Icons.volume_up, color: recent ? context.colors.warn : context.colors.muted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              last == null ? 'Nenhum aviso sonoro até agora' : 'Último aviso sonoro ${f.relative(last.timestamp)}',
                              style: TextStyle(fontWeight: FontWeight.w700, color: recent ? context.colors.onWarnContainer : null),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              last == null
                                  ? 'O aviso toca quando uma saída liga, no automático ou pelo app.'
                                  : '${describeOutputEvent(last, prefs.unit)} · ${f.dateTime(last.timestamp)}',
                              style: TextStyle(fontSize: 13, color: recent ? context.colors.onWarnContainer : context.colors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (device == null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Vincule o sensor desta estufa para que o gateway receba estes comandos.',
                    style: TextStyle(fontSize: 13, color: context.colors.muted),
                  ),
                ],
                if (data.events.isNotEmpty)
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: const Text('Últimas mudanças', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                      children: [
                        for (final event in data.events)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              event.turnedOn ? Icons.power : Icons.power_off,
                              color: event.turnedOn ? context.scheme.primary : context.colors.muted,
                            ),
                            title: Text(describeOutputEvent(event, prefs.unit)),
                            trailing: Text(f.relative(event.timestamp), style: TextStyle(color: context.colors.muted, fontSize: 12.5)),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _dryingCard(CuringUnit current) {
    final elapsed = f.hoursSince(current.dryingStartedAt);
    final total = current.estimatedHours;
    final progress = elapsed != null && total != null && total > 0 ? (elapsed / total).clamp(0.0, 1.0) : null;
    final stages = curingStages.contains(current.stage) ? curingStages : [current.stage, ...curingStages];
    final phase = current.phase;
    final stageHours = f.duration(f.hoursSince(current.stageStartedAt));

    return SectionCard(
      title: 'Secagem',
      icon: Icons.eco,
      trailing: current.isDrying
          ? const StatusBadge(kind: StatusKind.ok, label: 'Em andamento')
          : current.isFinished
              ? const StatusBadge(kind: StatusKind.ok, label: 'Finalizada', icon: Icons.check_circle)
              : const StatusBadge(kind: StatusKind.neutral, label: 'Parada', icon: Icons.stop),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PhaseSteps(current: phase?.number, finished: current.isFinished),
          if (phase != null) ...[
            const SizedBox(height: 14),
            _PhasePanel(phase: phase, unit: prefs.unit),
          ],
          const SizedBox(height: 16),
          DetailGrid(items: [
            DetailItem(label: 'Em secagem há', value: elapsed == null ? 'Parada' : f.duration(elapsed)),
            DetailItem(
              label: 'Nesta fase há',
              value: phase == null ? stageHours : '$stageHours de ${f.number(phase.minHours, 0)} a ${f.number(phase.maxHours, 0)} h',
            ),
            DetailItem(label: 'Duração prevista', value: total == null ? 'Não definida' : f.duration(total)),
            DetailItem(label: 'Término previsto', value: f.dateTime(current.estimatedCompletion)),
          ]),
          if (progress != null) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(value: progress, minHeight: 8, backgroundColor: context.colors.surface3),
            ),
            const SizedBox(height: 6),
            Text('${f.number(progress * 100, 0)}% do tempo previsto', style: TextStyle(fontSize: 13, color: context.colors.muted)),
          ],
          const Divider(height: 28),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (phase != null)
                BusyButton(
                  label: phase.finishes ? 'Finalizar cura' : 'Avançar para ${phase.nextStage}',
                  icon: phase.finishes ? Icons.check_circle : Icons.skip_next,
                  style: phase.ready ? BusyButtonStyle.filled : BusyButtonStyle.outlined,
                  onPressed: () => _advanceStage(current, phase),
                ),
              current.isDrying
                  ? BusyButton(label: 'Parar secagem', icon: Icons.stop, style: BusyButtonStyle.danger, onPressed: () => _stopDrying(current))
                  : BusyButton(
                      label: current.isFinished ? 'Iniciar nova cura' : 'Iniciar secagem',
                      icon: Icons.play_arrow,
                      onPressed: () => _startDrying(current),
                    ),
              OutlinedButton.icon(
                onPressed: () => _editDuration(current),
                icon: const Icon(Icons.schedule),
                label: Text(total == null ? 'Definir duração' : 'Alterar duração'),
              ),
            ],
          ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 4),
              title: const Text('Corrigir a fase manualmente', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
              children: [
                DropdownButtonFormField<String>(
                  key: ValueKey('stage-${current.id}-${current.stage}'),
                  initialValue: current.stage,
                  decoration: const InputDecoration(labelText: 'Fase da cura'),
                  items: [for (final stage in stages) DropdownMenuItem(value: stage, child: Text(stage))],
                  onChanged: (value) {
                    if (value != null && value != current.stage) _changeStage(current, value);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _alertsCard(CuringUnit current) {
    return SectionCard(
      title: 'Alertas ativos',
      icon: Icons.notifications_outlined,
      trailing: TextButton(onPressed: () => widget.actions.goTo(AppTab.alerts), child: const Text('Todos')),
      child: alerts.isEmpty
          ? Text(
              current.isDrying ? 'Nenhum alerta. Os valores estão sendo acompanhados.' : 'Os alertas são avaliados enquanto a secagem está em andamento.',
              style: TextStyle(color: context.colors.textSecondary),
            )
          : Column(
              children: [
                for (final alert in alerts.take(3))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      alert.isCritical ? Icons.error : Icons.warning_amber_rounded,
                      color: alert.isCritical ? context.colors.crit : context.colors.warn,
                    ),
                    title: Text('${alert.type} · ${alert.severityLabel}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${alert.message}\n${f.relative(alert.timestamp)}'),
                    isThreeLine: true,
                  ),
              ],
            ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  const _OutputRow({required this.state, required this.confirmedAt, required this.onMode, required this.onEdit});

  final OutputState state;
  final DateTime? confirmedAt;
  final ValueChanged<String> onMode;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final (IconData syncIcon, Color syncColor, String syncText) = switch (state) {
      OutputState(inSync: true) => (Icons.verified, context.colors.ok, 'Sender confirmou: ${state.on ? 'ligada' : 'desligada'}'),
      OutputState(confirmedOn: null) => (
          Icons.hourglass_empty,
          context.colors.muted,
          'O sender ainda não informou o estado do relé.',
        ),
      OutputState(:final confirmedOn) when confirmedOn == state.on => (
          Icons.history,
          context.colors.muted,
          'Último estado informado pelo sender ${f.relative(confirmedAt)}.',
        ),
      _ => (Icons.sync, context.colors.warn, 'Aguardando o sender aplicar o comando…'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: context.colors.surface2, borderRadius: BorderRadius.circular(10)),
              child: Icon(state.relay == 1 ? Icons.looks_one_outlined : Icons.looks_two_outlined, color: context.scheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(state.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  Text(state.relayLabel, style: TextStyle(fontSize: 12, color: context.colors.muted)),
                ],
              ),
            ),
            StatusBadge(
              kind: state.on ? StatusKind.info : StatusKind.neutral,
              label: state.on ? 'Ligada' : 'Desligada',
              icon: state.on ? Icons.power : Icons.power_off,
            ),
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Editar nome e regra',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(state.reason, style: TextStyle(fontSize: 13, color: context.colors.textSecondary)),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(syncIcon, size: 16, color: syncColor),
            const SizedBox(width: 6),
            Expanded(child: Text(syncText, style: TextStyle(fontSize: 12.5, color: syncColor))),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'auto', label: Text('Automático')),
            ButtonSegment(value: 'on', label: Text('Ligada')),
            ButtonSegment(value: 'off', label: Text('Desligada')),
          ],
          selected: {state.mode},
          showSelectedIcon: false,
          onSelectionChanged: (value) {
            if (value.first != state.mode) onMode(value.first);
          },
        ),
      ],
    );
  }
}

enum _KpiKind { temperature, humidity }

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.kind, required this.reading, required this.device, required this.limits, required this.unit, this.byPhase = false});

  final _KpiKind kind;
  final Reading? reading;
  final Device? device;
  final Limits limits;
  final TempUnit unit;

  /// A faixa é a da fase da cura em andamento.
  final bool byPhase;

  @override
  Widget build(BuildContext context) {
    final isTemp = kind == _KpiKind.temperature;
    final raw = reading == null ? null : (isTemp ? reading!.temperature : reading!.humidity);
    final min = isTemp ? limits.tempMin : limits.humidityMin;
    final max = isTemp ? limits.tempMax : limits.humidityMax;
    final state = rangeState(raw, min, max);
    final stale = reading == null || device?.online != true;

    double? display(double? value) => isTemp ? f.tempValue(value, unit) : value;
    final value = display(raw);
    final displayMin = display(min)!;
    final displayMax = display(max)!;
    final symbol = isTemp ? f.unitSymbol(unit) : '%';

    final badge = switch (state) {
      'high' => const StatusBadge(kind: StatusKind.crit, label: 'Acima do limite', icon: Icons.arrow_upward),
      'low' => const StatusBadge(kind: StatusKind.warn, label: 'Abaixo do limite', icon: Icons.arrow_downward),
      'ok' => const StatusBadge(kind: StatusKind.ok, label: 'Na faixa', icon: Icons.check),
      _ => const StatusBadge(kind: StatusKind.neutral, label: 'Sem leitura', icon: Icons.schedule),
    };
    final valueColor = stale ? context.colors.muted : context.scheme.onSurface;

    return Semantics(
      container: true,
      label: '${isTemp ? 'Temperatura' : 'Umidade relativa'}: ${f.number(value)} $symbol',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: context.colors.surface2, borderRadius: BorderRadius.circular(10)),
                    child: Icon(isTemp ? Icons.thermostat : Icons.water_drop, color: context.scheme.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isTemp ? 'Temperatura' : 'Umidade relativa',
                      style: TextStyle(fontWeight: FontWeight.w600, color: context.colors.textSecondary),
                    ),
                  ),
                  Flexible(child: badge),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                children: [
                  Text(f.number(value), style: TextStyle(fontSize: 48, height: 1, fontWeight: FontWeight.w800, letterSpacing: -1, color: valueColor)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(symbol, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: context.colors.textSecondary)),
                  ),
                  if (isTemp && raw != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(f.temp(raw, f.otherUnit(unit)), style: TextStyle(color: context.colors.muted)),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _RangeMeter(value: value, min: displayMin, max: displayMax, outOfRange: state != null && state != 'ok'),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${byPhase ? 'Faixa da fase' : 'Faixa segura'}: ${f.number(displayMin, 0)} a ${f.number(displayMax, 0)} $symbol',
                      style: TextStyle(fontSize: 12.5, color: context.colors.muted),
                    ),
                  ),
                  Text(
                    reading == null ? 'Sem leituras gravadas' : 'Leitura ${f.relative(reading!.timestamp)}',
                    style: TextStyle(fontSize: 12.5, color: context.colors.muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Régua com a faixa segura destacada e um marcador na posição do valor atual.
class _RangeMeter extends StatelessWidget {
  const _RangeMeter({required this.value, required this.min, required this.max, required this.outOfRange});

  final double? value;
  final double min;
  final double max;
  final bool outOfRange;

  @override
  Widget build(BuildContext context) {
    final span = max - min;
    final scaleMin = min - span * 0.35;
    final scaleMax = max + span * 0.35;
    double position(double v) => ((v - scaleMin) / (scaleMax - scaleMin)).clamp(0.0, 1.0);

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return SizedBox(
        height: 18,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            Container(height: 10, decoration: BoxDecoration(color: context.colors.surface3, borderRadius: BorderRadius.circular(999))),
            Positioned(
              left: width * position(min),
              width: width * (position(max) - position(min)),
              child: Container(height: 10, decoration: BoxDecoration(color: context.scheme.primaryContainer, borderRadius: BorderRadius.circular(999))),
            ),
            if (value != null)
              Positioned(
                left: (width * position(value!) - 9).clamp(0.0, width - 18),
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: outOfRange ? context.colors.crit : const Color(0xff2e7d32),
                    shape: BoxShape.circle,
                    border: Border.all(color: context.scheme.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}

/// Fase em andamento: faixa de referência e o que falta para passar à próxima.
class _PhasePanel extends StatelessWidget {
  const _PhasePanel({required this.phase, required this.unit});

  final PhaseStatus phase;
  final TempUnit unit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = colors.phase(phase.key);
    final limits = phase.limits;

    Widget item(IconData icon, Color iconColor, String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, color: colors.textSecondary))),
          ]),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withValues(alpha: 0.09), context.scheme.surface),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fase ${phase.number}: ${phase.name}', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(
            '${f.temp(limits.tempMin, unit, digits: 0)} a ${f.temp(limits.tempMax, unit, digits: 0)} · '
            'umidade ${f.number(limits.humidityMin, 0)}% a ${f.number(limits.humidityMax, 0)}%',
            style: TextStyle(fontSize: 13.5, color: colors.textSecondary),
          ),
          if (phase.overdue) item(Icons.warning_amber_rounded, colors.warn, 'Passou das ${f.number(phase.maxHours, 0)} h de referência desta fase.'),
          const SizedBox(height: 8),
          Text(
            phase.finishes ? 'Para finalizar a cura:' : 'Para passar para ${phase.nextStage}:',
            style: TextStyle(fontSize: 12.5, color: colors.muted),
          ),
          for (final check in phase.checks) item(check.ok ? Icons.check_circle : Icons.schedule, check.ok ? colors.ok : colors.muted, check.label),
          item(Icons.eco, color, 'Confira nas folhas: ${phase.visualCheck}'),
        ],
      ),
    );
  }
}
