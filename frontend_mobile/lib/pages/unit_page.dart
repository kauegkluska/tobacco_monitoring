import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/buzzer.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';
import '../widgets/line_chart.dart';
import '../widgets/phases.dart';
import '../widgets/unit_forms.dart';
import '../widgets/unit_widgets.dart';

/// Abre a tela da estufa por cima das abas.
Future<void> openUnit(BuildContext context, int unitId) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => UnitPage(unitId: unitId)));
}

class _Period {
  const _Period(this.label, this.hours);

  final String label;
  final int hours;
}

const _periods = [
  _Period('6 h', 6),
  _Period('24 h', 24),
  _Period('7 dias', 24 * 7),
  _Period('30 dias', 24 * 30),
];

enum _MenuAction { rename, duration, stage, delete }

/// Tudo de uma estufa: leituras, alertas, cura, gráfico, saídas e sensor.
class UnitPage extends StatefulWidget {
  const UnitPage({required this.unitId, super.key});

  final int unitId;

  @override
  State<UnitPage> createState() => _UnitPageState();
}

class _UnitPageState extends State<UnitPage> {
  static const _pollInterval = Duration(seconds: 5);
  static const _seriesInterval = Duration(seconds: 60);

  CuringUnit? unit;
  Device? device;
  Reading? latest;
  List<AlertItem> alerts = [];
  Outputs? outputs;
  Series? series;
  DateTime? seriesLoadedAt;
  bool seriesLoading = false;
  _Period period = _periods.first;
  bool temperature = true;
  String? error;
  Timer? timer;

  ApiClient get api => AppScope.of(context).api;
  AppPrefs get prefs => AppScope.of(context).prefs;
  String get _base => '/curing_units/${widget.unitId}';

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
    final api = this.api;
    try {
      final results = await Future.wait([
        api.get(_base),
        api.get('/devices/'),
        api.getOrNull('$_base/latest'),
        api.get('$_base/alerts?active=true'),
        api.get('$_base/outputs?events=5'),
      ]);
      final nextUnit = CuringUnit.fromJson(results[0] as Map<String, dynamic>);
      final devices = (results[1] as List).map((item) => Device.fromJson(item as Map<String, dynamic>));
      if (!mounted) return;
      setState(() {
        unit = nextUnit;
        device = devices.where((item) => item.id == nextUnit.deviceId).firstOrNull;
        latest = results[2] == null ? null : Reading.fromJson(results[2] as Map<String, dynamic>);
        alerts = (results[3] as List).map((item) => AlertItem.fromJson(item as Map<String, dynamic>)).toList();
        outputs = Outputs.fromJson(results[4] as Map<String, dynamic>);
        error = null;
      });
      final loadedAt = seriesLoadedAt;
      if (loadedAt == null || DateTime.now().difference(loadedAt) > _seriesInterval) await _loadSeries();
    } on ApiException catch (exception) {
      if (!mounted) return;
      if (exception.status == 404) {
        Navigator.of(context).maybePop();
        return;
      }
      if (unit == null) {
        setState(() => error = exception.message);
      } else {
        showMessage(context, exception.message, error: true);
      }
    } finally {
      if (mounted) timer = Timer(_pollInterval, _load);
    }
  }

  Future<void> _loadSeries() async {
    setState(() => seriesLoading = true);
    final until = DateTime.now().toUtc();
    final since = until.subtract(Duration(hours: period.hours));
    try {
      final result = await api.get(
        '$_base/series?since=${Uri.encodeQueryComponent(since.toIso8601String())}'
        '&until=${Uri.encodeQueryComponent(until.toIso8601String())}&points=180',
      );
      if (!mounted) return;
      setState(() {
        series = Series.fromJson(result as Map<String, dynamic>);
        seriesLoadedAt = DateTime.now();
      });
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    } finally {
      if (mounted) setState(() => seriesLoading = false);
    }
  }

  Future<void> _reload({bool withSeries = false}) {
    if (withSeries) seriesLoadedAt = null;
    return _load();
  }

  /// Roda uma ação da API, mostra o resultado e recarrega a tela.
  Future<void> _run(Future<void> Function() action, String done, {bool withSeries = false}) async {
    try {
      await action();
      if (!mounted) return;
      showMessage(context, done);
      await _reload(withSeries: withSeries);
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Cura

  Future<void> _startDrying(CuringUnit current) async {
    var newBatch = false;
    if (current.interrupted) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Continuar a secagem?'),
          content: Text(
            'A secagem parou em ${current.stage} com ${f.duration(current.stageHours)} nesta fase'
            '${current.pausedAt == null ? '' : ', ${f.relative(current.pausedAt)}'}.\n\n'
            'Continuar: segue na mesma fase, sem contar o tempo parado.\n'
            'Nova estufada: começa outra carga na Amarelação, do zero.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancelar')),
            OutlinedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Nova estufada')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Continuar')),
          ],
        ),
      );
      if (choice == null) return;
      newBatch = choice;
    }
    await _run(
      () => api.post('$_base/start-drying${newBatch ? '?new_batch=true' : ''}'),
      newBatch ? 'Nova estufada iniciada.' : (current.interrupted ? 'Secagem retomada.' : 'Secagem iniciada.'),
      withSeries: true,
    );
  }

  Future<void> _stopDrying() async {
    final confirmed = await confirmAction(
      context,
      title: 'Parar a secagem?',
      message: 'Com a secagem parada, as leituras não são gravadas e não há alertas.',
      confirmLabel: 'Parar',
      danger: true,
    );
    if (confirmed) await _run(() => api.post('$_base/stop-drying'), 'Secagem parada.');
  }

  Future<void> _advanceStage(PhaseStatus phase) async {
    final finishing = phase.finishes;
    final pending = [for (final check in phase.checks) if (!check.ok) phaseCheckLabel(check, prefs.unit).toLowerCase()];
    final confirmed = await confirmAction(
      context,
      title: finishing ? 'Finalizar a cura?' : 'Avançar para ${phase.nextStage}?',
      message: [
        'Nas folhas: ${phase.visualCheck}',
        if (pending.isNotEmpty) 'Ainda falta: ${pending.join('; ')}.',
        if (finishing) 'A secagem será encerrada.',
      ].join('\n\n'),
      confirmLabel: finishing ? 'Finalizar' : 'Avançar',
    );
    if (!confirmed) return;
    await _run(
      () => api.post('$_base/advance-stage'),
      finishing ? 'Cura finalizada.' : 'Fase: ${phase.nextStage}.',
      withSeries: true,
    );
  }

  Future<void> _changeStage(CuringUnit current) async {
    final stages = curingStages.contains(current.stage) ? curingStages : [current.stage, ...curingStages];
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Corrigir fase'),
        children: [
          for (final item in stages)
            ListTile(
              leading: Icon(item == current.stage ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(item),
              onTap: () => Navigator.pop(dialogContext, item),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == current.stage) return;
    await _run(() => api.patch(_base, {'curing_stage': chosen}), 'Fase: $chosen.', withSeries: true);
  }

  // ---------------------------------------------------------------------------
  // Estufa e sensor

  Future<void> _menu(_MenuAction action, CuringUnit current) async {
    switch (action) {
      case _MenuAction.rename:
        if (await showUnitForm(context, api, unit: current) != null) await _reload();
      case _MenuAction.duration:
        if (await showDurationForm(context, api, current) && mounted) {
          showMessage(context, 'Duração salva.');
          await _reload();
        }
      case _MenuAction.stage:
        await _changeStage(current);
      case _MenuAction.delete:
        await _delete(current);
    }
  }

  Future<void> _delete(CuringUnit current) async {
    final confirmed = await confirmAction(
      context,
      title: 'Excluir ${current.name}?',
      message: 'Só estufas sem leituras gravadas podem ser excluídas.',
      confirmLabel: 'Excluir',
      danger: true,
    );
    if (!confirmed) return;
    try {
      await api.delete(_base);
      if (!mounted) return;
      showMessage(context, 'Estufa excluída.');
      Navigator.of(context).pop();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _linkDevice() async {
    final linked = await showLinkDeviceSheet(context, api, unitId: widget.unitId);
    if (linked == null || !mounted) return;
    showMessage(context, 'Sensor ${linked.code} vinculado.');
    await _reload();
  }

  Future<void> _checkDevice(Device target) async {
    try {
      final result = await api.post('/devices/${target.id}/reconnect') as Map<String, dynamic>;
      if (!mounted) return;
      if (result['status'] == 'online') {
        showMessage(context, 'Sensor online.');
      } else {
        showMessage(context, 'Sensor sem sinal. Confira a energia do sensor e o gateway.', error: true);
      }
      await _reload();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _unlinkDevice(Device target) async {
    final confirmed = await confirmAction(
      context,
      title: 'Desvincular ${target.code}?',
      message: 'O histórico continua salvo. A estufa deixa de receber leituras deste sensor.',
      confirmLabel: 'Desvincular',
      danger: true,
    );
    if (confirmed) await _run(() => api.delete('/devices/${target.id}'), 'Sensor desvinculado.');
  }

  // ---------------------------------------------------------------------------
  // Saídas

  Future<void> _setOutputMode(String output, String mode) async {
    final name = (output == 'temperature' ? outputs?.temperature : outputs?.humidity)?.name ?? 'Saída';
    if (mode == 'on') {
      final confirmed = await confirmAction(
        context,
        title: 'Ligar $name?',
        message: 'Fica ligada até você escolher Automático ou Desligada. O gateway toca o aviso sonoro por 2 s.',
        confirmLabel: 'Ligar',
      );
      if (!confirmed) return;
    }
    try {
      final result = await api.patch('$_base/outputs', {'${output}_mode': mode});
      if (!mounted) return;
      setState(() => outputs = Outputs.fromJson(result as Map<String, dynamic>));
      showMessage(context, switch (mode) {
        'on' => '$name ligada.',
        'off' => '$name desligada.',
        _ => '$name no automático.',
      });
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _editOutput(String output, OutputState state) async {
    final name = TextEditingController(text: state.name);
    var trigger = state.trigger;
    String? sheetError;
    await showFormSheet<void>(
      context,
      title: 'Editar ${state.relayLabel.toLowerCase()}',
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormErrorText(sheetError),
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Ventoinhas, Queimador'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: trigger,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'No automático, liga com'),
              items: [for (final entry in outputTriggers.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
              onChanged: (value) => setSheetState(() => trigger = value ?? trigger),
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: 'Salvar',
              onPressed: () async {
                final newName = name.text.trim();
                if (newName.isEmpty) {
                  setSheetState(() => sheetError = 'Informe o nome.');
                  return;
                }
                try {
                  final result = await api.patch('$_base/outputs', {'${output}_name': newName, '${output}_trigger': trigger});
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (mounted) setState(() => outputs = Outputs.fromJson(result as Map<String, dynamic>));
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

  /// Temperatura alvo da ventoinha, digitada na unidade escolhida e enviada em °C.
  Future<void> _editTarget() async {
    final unitPref = prefs.unit;
    final symbol = f.unitSymbol(unitPref);
    final current = outputs?.targetTemperature;
    final controller = TextEditingController(text: current == null ? '' : f.number(f.tempValue(current, unitPref), 0));
    final phase = unit?.phase;
    String? sheetError;
    await showFormSheet<void>(
      context,
      title: 'Temperatura alvo',
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormErrorText(sheetError),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Alvo',
                suffixText: symbol,
                helperText: phase == null
                    ? 'A ventoinha liga abaixo do alvo e desliga ao atingi-lo.'
                    : 'Faixa da fase: ${f.tempRange(phase.limits.tempMin, phase.limits.tempMax, unitPref)}',
              ),
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: 'Salvar',
              onPressed: () async {
                final typed = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                final celsius = typed == null ? null : f.tempToCelsius(typed, unitPref);
                if (celsius == null || celsius < 20 || celsius > 90) {
                  setSheetState(() => sheetError = 'Informe um valor entre ${f.tempRange(20, 90, unitPref)}.');
                  return;
                }
                try {
                  final result = await api.patch('$_base/outputs', {'target_temperature': double.parse(celsius.toStringAsFixed(2))});
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (!mounted) return;
                  setState(() => outputs = Outputs.fromJson(result as Map<String, dynamic>));
                  showMessage(context, 'Alvo: ${f.temp(celsius, unitPref, digits: 0)}.');
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

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final current = unit;
    return Scaffold(
      appBar: AppBar(
        title: Text(current?.name ?? 'Estufa'),
        actions: [
          if (current != null)
            PopupMenuButton<_MenuAction>(
              tooltip: 'Mais opções',
              onSelected: (action) => _menu(action, current),
              itemBuilder: (_) => const [
                PopupMenuItem(value: _MenuAction.rename, child: Text('Renomear')),
                PopupMenuItem(value: _MenuAction.duration, child: Text('Duração prevista')),
                PopupMenuItem(value: _MenuAction.stage, child: Text('Corrigir fase')),
                PopupMenuItem(value: _MenuAction.delete, child: Text('Excluir estufa')),
              ],
            ),
        ],
      ),
      body: error != null
          ? ErrorView(title: 'Não foi possível carregar a estufa', message: error!, onRetry: _load)
          : current == null
              ? const LoadingView()
              : ListenableBuilder(listenable: prefs, builder: (context, _) => _body(current)),
    );
  }

  Widget _body(CuringUnit current) {
    final limits = current.limitsWith(device);
    final expected = current.phase == null ? null : limits;
    final stale = isStale(latest, current, device);
    final children = <Widget>[
      _summary(current),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: ReadingTile(
                  metric: Metric.temperature,
                  value: latest?.temperature,
                  limits: expected,
                  unit: prefs.unit,
                  stale: stale,
                  target: outputs?.usesTarget == true ? outputs?.targetTemperature : null,
                ),),
              const SizedBox(width: 20),
              Expanded(child: ReadingTile(metric: Metric.humidity, value: latest?.humidity, limits: expected, unit: prefs.unit, stale: stale)),
            ],
          ),
        ),
      ),
      if (device != null && !device!.online)
        StatusBanner(
          kind: StatusKind.offline,
          icon: Icons.cloud_off,
          title: 'Sensor sem sinal ${device!.lastSeen == null ? 'desde o vínculo' : f.relative(device!.lastSeen)}',
          text: 'Confira a energia do sensor e o Wi-Fi do gateway.',
        ),
      for (final alert in alerts)
        AlertCard(
          alert: alert,
          unit: prefs.unit,
          showUnitName: false,
          onAcknowledge: () async {
            if (await acknowledgeAlert(context, api, alert)) await _reload();
          },
          onResolve: () async {
            if (await resolveAlert(context, api, alert)) await _reload();
          },
        ),
      _curingCard(current),
      _chartCard(current, limits),
      _outputsCard(),
      _sensorCard(),
    ];

    return RefreshIndicator(
      onRefresh: () => _reload(withSeries: true),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: children.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, index) => children[index],
          ),
        ),
      ),
    );
  }

  /// Fase e situação numa linha, logo abaixo do nome.
  Widget _summary(CuringUnit current) {
    final status = unitStatus(
      unit: current,
      device: device,
      latest: latest,
      activeAlerts: alerts.length,
      criticalAlerts: alerts.where((alert) => alert.isCritical).length,
    );
    final phase = current.phase;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        StatusBadge(kind: status.kind, label: status.label, icon: status.icon),
        PhaseTag(
          label: phase == null ? current.stage : 'Fase ${phase.number} de ${phase.total} · ${current.stage}',
          color: context.colors.phase(phaseKeyOf(current.stage)),
        ),
        if (latest != null) Text('Leitura ${f.relative(latest!.timestamp)}', style: TextStyle(fontSize: 13, color: context.colors.muted)),
      ],
    );
  }

  Widget _curingCard(CuringUnit current) {
    final phase = current.phase;
    final elapsed = current.cycleHours;
    final total = current.estimatedHours;
    final progress = current.isDrying && elapsed != null && total != null && total > 0 ? (elapsed / total).clamp(0.0, 1.0) : null;
    final c = context.colors;
    // Com a secagem parada no meio da cura, a fase em que parou continua marcada.
    final stageIndex = curingPhases.indexWhere((item) => item.name == current.stage);

    Widget check(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: c.textSecondary))),
          ]),
        );

    return SectionCard(
      title: 'Cura',
      icon: Icons.eco_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PhaseSteps(current: phase?.number ?? (stageIndex < 0 ? null : stageIndex + 1), finished: current.isFinished),
          if (current.interrupted) ...[
            const SizedBox(height: 14),
            Text(
              'Parada em ${current.stage}${current.pausedAt == null ? '' : ' ${f.relative(current.pausedAt)}'}. O tempo parado não conta.',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.textSecondary),
            ),
          ],
          if (current.isDrying || current.interrupted) ...[
            const SizedBox(height: 16),
            DetailGrid(items: [
              DetailItem(
                label: 'Nesta fase',
                value: phase == null
                    ? f.duration(current.stageHours)
                    : '${f.duration(phase.hours)} de ${f.number(phase.minHours, 0)}–${f.number(phase.maxHours, 0)} h',
              ),
              DetailItem(label: 'Secagem total', value: f.duration(elapsed)),
              if (total != null && current.isDrying) DetailItem(label: 'Término previsto', value: f.dateTime(current.estimatedCompletion)),
            ]),
            if (progress != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(value: progress, minHeight: 6, backgroundColor: c.surface3),
              ),
            ],
          ],
          if (phase != null) ...[
            const SizedBox(height: 16),
            Text(
              phase.finishes ? 'Para finalizar' : 'Para avançar para ${phase.nextStage}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (phase.overdue) check(Icons.warning_amber_rounded, c.warn, 'Passou das ${f.number(phase.maxHours, 0)} h previstas para a fase.'),
            for (final item in phase.checks)
              check(item.ok ? Icons.check_circle : Icons.radio_button_unchecked, item.ok ? c.ok : c.muted, phaseCheckLabel(item, prefs.unit)),
            check(Icons.visibility_outlined, c.phase(phase.key), 'Nas folhas: ${phase.visualCheck}'),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (phase != null)
                BusyButton(
                  label: phase.finishes ? 'Finalizar cura' : 'Avançar fase',
                  icon: phase.finishes ? Icons.check_circle : Icons.skip_next,
                  style: phase.ready ? BusyButtonStyle.filled : BusyButtonStyle.outlined,
                  onPressed: () => _advanceStage(phase),
                ),
              if (current.isDrying)
                BusyButton(label: 'Parar secagem', icon: Icons.stop, style: BusyButtonStyle.danger, onPressed: _stopDrying)
              else
                BusyButton(
                  label: current.isFinished ? 'Nova estufada' : 'Iniciar secagem',
                  icon: Icons.play_arrow,
                  onPressed: device == null ? null : () => _startDrying(current),
                ),
            ],
          ),
          if (!current.isDrying && device == null) ...[
            const SizedBox(height: 8),
            Text('Vincule um sensor para iniciar.', style: TextStyle(fontSize: 13, color: c.muted)),
          ],
        ],
      ),
    );
  }

  Widget _chartCard(CuringUnit current, Limits limits) {
    final data = series;
    final unitPref = prefs.unit;
    double convert(double value) => temperature ? f.tempValue(value, unitPref)! : value;
    String format(double value) => temperature ? '${f.number(value)} ${f.unitSymbol(unitPref)}' : '${f.number(value)}%';
    String show(double? value) => value == null ? '--' : format(convert(value));

    final stats = data?.stats;
    final phases = data == null ? const <ChartPhase>[] : chartPhasesOf(data, context.colors, temperature: temperature, unit: unitPref);
    final points = [
      for (final point in data?.points ?? const <SeriesPoint>[])
        ChartPoint(
          point.time,
          convert(temperature ? point.temperature : point.humidity),
          low: convert(temperature ? point.temperatureMin : point.humidityMin),
          high: convert(temperature ? point.temperatureMax : point.humidityMax),
          count: point.count,
        ),
    ];

    Widget stat(String label, double? value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.colors.muted)),
              Text(show(value), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ],
          ),
        );

    return SectionCard(
      title: 'Histórico',
      icon: Icons.show_chart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Temperatura'), icon: Icon(Icons.thermostat)),
              ButtonSegment(value: false, label: Text('Umidade'), icon: Icon(Icons.water_drop_outlined)),
            ],
            selected: {temperature},
            onSelectionChanged: (value) => setState(() => temperature = value.first),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final item in _periods)
                ChoiceChip(
                  label: Text(item.label),
                  selected: item == period,
                  onSelected: (_) {
                    if (item == period) return;
                    setState(() => period = item);
                    _loadSeries();
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(children: [
            stat('Mínima', temperature ? stats?.temperatureMin : stats?.humidityMin),
            stat('Média', temperature ? stats?.temperatureAvg : stats?.humidityAvg),
            stat('Máxima', temperature ? stats?.temperatureMax : stats?.humidityMax),
          ]),
          const SizedBox(height: 12),
          AnimatedOpacity(
            opacity: seriesLoading ? 0.5 : 1,
            duration: const Duration(milliseconds: 200),
            child: data == null
                ? const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()))
                : LineChart(
                    points: points,
                    start: data.since,
                    end: data.until,
                    // Com fases no período, cada uma desenha a própria faixa esperada.
                    limitMin: phases.isNotEmpty ? null : (temperature ? f.tempValue(limits.tempMin, unitPref) : limits.humidityMin),
                    limitMax: phases.isNotEmpty ? null : (temperature ? f.tempValue(limits.tempMax, unitPref) : limits.humidityMax),
                    phases: phases,
                    format: format,
                    detail: (point) => point.count > 1 ? '${format(point.low!)} a ${format(point.high!)}' : '1 leitura',
                    gap: Duration(seconds: (data.bucketSeconds * 3).clamp(300, 1 << 30)),
                    height: 220,
                    semanticLabel: '${temperature ? 'Temperatura' : 'Umidade'} nas últimas ${period.label}',
                    emptyText: current.isDrying ? 'Sem leituras neste período.' : 'Sem leituras. Elas só são gravadas com a secagem ligada.',
                  ),
          ),
          if (phases.length > 1) PhaseLegend(phases: phases),
        ],
      ),
    );
  }

  Widget _outputsCard() {
    final data = outputs;
    if (data == null) return const SizedBox.shrink();
    final last = data.lastBuzzer;
    return SectionCard(
      title: 'Saídas',
      icon: Icons.power_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _OutputRow(
            state: data.humidity,
            confirmedAt: data.confirmedAt,
            target: data.targetTemperature,
            unit: prefs.unit,
            onMode: (mode) => _setOutputMode('humidity', mode),
            onEdit: () => _editOutput('humidity', data.humidity),
            onEditTarget: _editTarget,
          ),
          const Divider(height: 28),
          _OutputRow(
            state: data.temperature,
            confirmedAt: data.confirmedAt,
            target: data.targetTemperature,
            unit: prefs.unit,
            onMode: (mode) => _setOutputMode('temperature', mode),
            onEdit: () => _editOutput('temperature', data.temperature),
            onEditTarget: _editTarget,
          ),
          if (last != null) ...[
            const SizedBox(height: 14),
            Row(children: [
              Icon(Icons.volume_up_outlined, size: 18, color: context.colors.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Último aviso sonoro ${f.relative(last.timestamp)}: ${describeOutputEvent(last, prefs.unit)}',
                  style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
                ),
              ),
            ]),
          ],
          if (data.events.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('Últimas mudanças', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                children: [
                  for (final event in data.events)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(event.turnedOn ? Icons.power : Icons.power_off, color: event.turnedOn ? context.scheme.primary : context.colors.muted),
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

  Widget _sensorCard() {
    final current = device;
    if (current == null) {
      return SectionCard(
        title: 'Sensor',
        icon: Icons.sensors,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Nenhum sensor vinculado.', style: TextStyle(color: context.colors.textSecondary)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(onPressed: _linkDevice, icon: const Icon(Icons.link), label: const Text('Vincular sensor')),
            ),
          ],
        ),
      );
    }
    final signal = current.rssi == null
        ? '--'
        : '${current.signalQuality} (${current.rssi} dBm${current.snr == null ? '' : ' · SNR ${f.number(current.snr)}'})';
    return SectionCard(
      title: 'Sensor',
      icon: Icons.sensors,
      trailing: current.online
          ? const StatusBadge(kind: StatusKind.ok, label: 'Online')
          : const StatusBadge(kind: StatusKind.offline, label: 'Sem sinal', icon: Icons.cloud_off),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailGrid(items: [
            DetailItem(label: 'ID', value: current.code),
            DetailItem(label: 'Último contato', value: f.relative(current.lastSeen)),
            DetailItem(label: 'Sinal LoRa', value: signal),
            DetailItem(label: 'Firmware', value: current.firmwareVersion ?? '--'),
            if (current.battery != null) DetailItem(label: 'Bateria', value: '${current.battery}%${current.batteryLow ? ' (baixa)' : ''}'),
            if (current.macAddress != null) DetailItem(label: 'MAC', value: current.macAddress!),
          ]),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              BusyButton(label: 'Verificar', icon: Icons.refresh, style: BusyButtonStyle.outlined, onPressed: () => _checkDevice(current)),
              TextButton.icon(
                onPressed: () => _unlinkDevice(current),
                style: TextButton.styleFrom(foregroundColor: context.colors.crit),
                icon: const Icon(Icons.link_off),
                label: const Text('Desvincular'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  const _OutputRow({
    required this.state,
    required this.confirmedAt,
    required this.target,
    required this.unit,
    required this.onMode,
    required this.onEdit,
    required this.onEditTarget,
  });

  final OutputState state;
  final DateTime? confirmedAt;

  /// Temperatura alvo em °C; só aparece quando a saída segue o alvo.
  final double? target;
  final TempUnit unit;
  final ValueChanged<String> onMode;
  final VoidCallback onEdit;
  final VoidCallback onEditTarget;

  @override
  Widget build(BuildContext context) {
    final (IconData syncIcon, Color syncColor, String syncText) = switch (state) {
      OutputState(inSync: true) => (Icons.verified, context.colors.ok, 'Confirmado pelo sensor'),
      OutputState(confirmedOn: null) => (Icons.hourglass_empty, context.colors.muted, 'Sensor ainda não informou'),
      OutputState(:final confirmedOn) when confirmedOn == state.on => (
          Icons.history,
          context.colors.muted,
          'Confirmado ${f.relative(confirmedAt)}',
        ),
      _ => (Icons.sync, context.colors.warn, 'Aguardando o sensor aplicar'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(state.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5), overflow: TextOverflow.ellipsis),
                  Text('${state.relayLabel} · ${state.reason}', style: TextStyle(fontSize: 13, color: context.colors.textSecondary)),
                ],
              ),
            ),
            StatusBadge(
              kind: state.on ? StatusKind.info : StatusKind.neutral,
              label: state.on ? 'Ligada' : 'Desligada',
              icon: state.on ? Icons.power : Icons.power_off,
            ),
            IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_outlined), tooltip: 'Editar nome e regra', visualDensity: VisualDensity.compact),
          ],
        ),
        const SizedBox(height: 4),
        Row(children: [
          Icon(syncIcon, size: 15, color: syncColor),
          const SizedBox(width: 6),
          Expanded(child: Text(syncText, style: TextStyle(fontSize: 12.5, color: syncColor))),
        ]),
        if (state.followsTarget) ...[
          const SizedBox(height: 10),
          _TargetRow(target: target, unit: unit, onEdit: onEditTarget),
        ],
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

/// Temperatura alvo da ventoinha: o valor e o botão para mudar, ou o aviso para definir.
class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.target, required this.unit, required this.onEdit});

  final double? target;
  final TempUnit unit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final missing = target == null;
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(color: missing ? c.warnContainer : c.surface2, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.thermostat, size: 20, color: missing ? c.warn : context.scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: missing
                ? Text('Defina a temperatura alvo', style: TextStyle(fontWeight: FontWeight.w600, color: c.onWarnContainer))
                : Text.rich(TextSpan(children: [
                    TextSpan(text: 'Alvo  ', style: TextStyle(color: c.textSecondary)),
                    TextSpan(text: f.temp(target, unit), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  ])),
          ),
          TextButton(onPressed: onEdit, child: Text(missing ? 'Definir' : 'Alterar')),
        ],
      ),
    );
  }
}
