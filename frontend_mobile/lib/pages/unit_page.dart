import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';
import '../widgets/decision.dart';
import '../widgets/line_chart.dart';
import '../widgets/phases.dart';
import '../widgets/unit_forms.dart';
import '../widgets/unit_widgets.dart';
import 'equipment_page.dart';
import 'unit_chart_page.dart';
import 'ventilation_page.dart';

/// Abre a tela da estufa por cima das abas.
Future<void> openUnit(BuildContext context, int unitId) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => UnitPage(unitId: unitId)));
}

enum _MenuAction { equipment, duration, stage, rename, stop, newUnit, delete }

/// Acompanhamento da estufa, do mais urgente ao menos usado.
/// Comandos, sensor e gráfico completo ficam em telas próprias.
class UnitPage extends StatefulWidget {
  const UnitPage({required this.unitId, this.onGone, this.onCreateUnit, super.key});

  final int unitId;

  /// Quando a tela é a própria aba (produtor com uma só estufa): avisa que ela foi excluída.
  final VoidCallback? onGone;
  final Future<void> Function()? onCreateUnit;

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

  void _gone() {
    if (widget.onGone != null) {
      widget.onGone!();
    } else {
      Navigator.of(context).maybePop();
    }
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
        _gone();
        return;
      }
      if (unit == null) {
        setState(() => error = exception.message);
      } else if (exception.status != 0) {
        // Sem conexão quem avisa é a frase do topo, sem repetir um aviso a cada consulta.
        showMessage(context, exception.message, error: true);
      }
    } finally {
      if (mounted) timer = Timer(_pollInterval, _load);
    }
  }

  /// Resumo do gráfico: a estufada atual (ou a última) inteira.
  Future<void> _loadSeries() async {
    try {
      final result = await api.get('$_base/series?batch=true&points=60');
      if (!mounted) return;
      setState(() {
        series = Series.fromJson(result as Map<String, dynamic>);
        seriesLoadedAt = DateTime.now();
      });
    } on ApiException {
      // O resumo é secundário: tenta de novo na próxima consulta.
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
      message: 'Se parar, o app deixa de acompanhar a estufa e você não recebe mais avisos.',
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
      title: finishing ? 'Finalizar a cura?' : 'Passar para ${phase.nextStage}?',
      message: [
        'Nas folhas: ${phase.visualCheck}',
        if (pending.isNotEmpty) 'Ainda falta: ${pending.join('; ')}.',
        if (finishing) 'A secagem será encerrada.',
      ].join('\n\n'),
      confirmLabel: finishing ? 'Finalizar' : 'Passar de fase',
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

  Future<void> _menu(_MenuAction action, CuringUnit current) async {
    switch (action) {
      case _MenuAction.equipment:
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EquipmentPage(unitId: widget.unitId)));
        if (mounted) await _reload();
      case _MenuAction.rename:
        if (await showUnitForm(context, api, unit: current) != null) await _reload();
      case _MenuAction.duration:
        if (await showDurationForm(context, api, current) && mounted) {
          showMessage(context, 'Duração salva.');
          await _reload();
        }
      case _MenuAction.stage:
        await _changeStage(current);
      case _MenuAction.stop:
        await _stopDrying();
      case _MenuAction.newUnit:
        await widget.onCreateUnit?.call();
      case _MenuAction.delete:
        await _delete(current);
    }
  }

  PopupMenuItem<_MenuAction> _deleteItem(CuringUnit current) {
    final blocker = current.isDrying
        ? 'Pare a secagem antes.'
        : latest != null
            ? 'Tem leituras salvas: o histórico das estufadas fica guardado.'
            : null;
    if (blocker == null) return const PopupMenuItem(value: _MenuAction.delete, child: Text('Excluir estufa'));
    return PopupMenuItem(
      enabled: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Excluir estufa'),
          const SizedBox(height: 2),
          Text(blocker, style: TextStyle(fontSize: 12.5, color: context.colors.muted)),
        ],
      ),
    );
  }

  Future<void> _delete(CuringUnit current) async {
    final confirmed = await confirmAction(
      context,
      title: 'Excluir ${current.name}?',
      message: 'A estufa sai da sua lista.',
      confirmLabel: 'Excluir',
      danger: true,
    );
    if (!confirmed) return;
    try {
      await api.delete(_base);
      if (!mounted) return;
      showMessage(context, 'Estufa excluída.');
      _gone();
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

  Future<void> _openVentilation(CuringUnit current) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => VentilationPage(unitId: widget.unitId, phase: current.phase)));
    if (mounted) await _reload();
  }

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
              itemBuilder: (_) => [
                const PopupMenuItem(value: _MenuAction.equipment, child: Text('Equipamento')),
                const PopupMenuItem(value: _MenuAction.duration, child: Text('Duração prevista')),
                const PopupMenuItem(value: _MenuAction.stage, child: Text('Corrigir fase')),
                const PopupMenuItem(value: _MenuAction.rename, child: Text('Renomear')),
                if (widget.onCreateUnit != null) const PopupMenuItem(value: _MenuAction.newUnit, child: Text('Nova estufa')),
                if (current.isDrying) const PopupMenuItem(value: _MenuAction.stop, child: Text('Parar secagem')),
                // A API só exclui estufa parada e sem leituras: nos outros casos a opção aparece desativada, com o motivo.
                _deleteItem(current),
              ],
            ),
        ],
      ),
      body: error != null
          ? ErrorView(title: 'Não foi possível carregar a estufa', message: error!, onRetry: _load)
          : current == null
              ? const LoadingView()
              : AnimatedBuilder(
                  animation: Listenable.merge([prefs, api.online]),
                  builder: (context, _) => _body(current),
                ),
    );
  }

  Widget _body(CuringUnit current) {
    final featured = featuredAlert(alerts);
    final decision = decide(
      unit: current,
      device: device,
      latest: latest,
      connected: api.online.value,
      criticals: alerts.where((alert) => alert.isCritical).length,
      warnings: alerts.where((alert) => !alert.isInfo).length,
      sensorDoubt: alerts.any((alert) => alert.isSensor),
      message: featured?.message,
    );
    final showsFeatured = featured != null && decision.text == featured.message;
    final others = alerts.where((alert) => !showsFeatured || alert.id != featured.id).toList();
    final limits = current.limitsWith(device);

    final children = <Widget>[
      DecisionCard(
        kind: decision.kind,
        icon: decision.icon,
        title: decision.title,
        text: decision.text,
        onHelp: () => showStatusLegend(context),
        action: showsFeatured ? _alertActions(featured) : _setupAction(current),
      ),
      for (final alert in others)
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
      _readingsCard(current, limits, alerts.any((alert) => alert.isSensor)),
      if (outputs != null) _ventilationLine(current, outputs!),
      if (current.isDrying || current.interrupted) _phaseCard(current),
      _miniChart(current, limits),
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

  Widget _alertActions(AlertItem alert) => AlertActions(
        alert: alert,
        unit: prefs.unit,
        onAcknowledge: () async {
          if (await acknowledgeAlert(context, api, alert)) await _reload();
        },
        onResolve: () async {
          if (await resolveAlert(context, api, alert)) await _reload();
        },
      );

  /// Próximo passo quando a estufa ainda não está sendo acompanhada.
  Widget? _setupAction(CuringUnit current) {
    if (device == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: BusyButton(label: 'Vincular sensor', icon: Icons.link, onPressed: _linkDevice),
      );
    }
    if (current.isDrying) return null;
    return Align(
      alignment: Alignment.centerLeft,
      child: BusyButton(
        label: current.isFinished ? 'Nova estufada' : 'Iniciar secagem',
        icon: Icons.play_arrow,
        onPressed: () => _startDrying(current),
      ),
    );
  }

  Widget _readingsCard(CuringUnit current, Limits limits, bool doubtful) {
    final expected = current.phase == null ? null : limits;
    final stale = isStale(latest, current, device) || doubtful;
    final caption = latest == null ? null : (doubtful ? 'Leitura duvidosa, ${f.relative(latest!.timestamp)}' : 'Leitura ${f.relative(latest!.timestamp)}');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ReadingTile(
                    metric: Metric.temperature,
                    value: latest?.temperature,
                    limits: expected,
                    unit: prefs.unit,
                    stale: stale,
                    target: outputs?.usesTarget == true ? outputs?.targetTemperature : null,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(child: ReadingTile(metric: Metric.humidity, value: latest?.humidity, limits: expected, unit: prefs.unit, stale: stale)),
              ],
            ),
            if (caption != null) ...[
              const SizedBox(height: 10),
              Text(caption, style: TextStyle(fontSize: 13, color: context.colors.muted)),
            ],
          ],
        ),
      ),
    );
  }

  /// O que o sistema já está fazendo, numa linha; os comandos ficam na tela de Ventilação.
  Widget _ventilationLine(CuringUnit current, Outputs data) {
    String describe(OutputState state) {
      if (current.isDrying && state.followsTarget && state.mode == 'auto' && data.targetTemperature == null) {
        return '${state.name}: falta definir a temperatura alvo';
      }
      final running = state.on ? 'em funcionamento' : 'sem funcionar';
      return '${state.name}: $running${state.mode == 'auto' ? '' : ', acionamento manual'}';
    }

    bool needsAttention(OutputState state) =>
        state.mode != 'auto' || (current.isDrying && state.followsTarget && data.targetTemperature == null);
    final attention = needsAttention(data.humidity) || needsAttention(data.temperature);
    final c = context.colors;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openVentilation(current),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(attention ? Icons.warning_amber_rounded : Icons.air, color: attention ? c.warn : c.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Ventilação', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(describe(data.humidity), style: TextStyle(fontSize: 13.5, color: c.textSecondary)),
                    Text(describe(data.temperature), style: TextStyle(fontSize: 13.5, color: c.textSecondary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phaseCard(CuringUnit current) {
    final phase = current.phase;
    final elapsed = current.cycleHours;
    final total = current.estimatedHours;
    final c = context.colors;
    final stageIndex = curingPhases.indexWhere((item) => item.name == current.stage);

    Widget check(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: c.textSecondary))),
          ]),
        );

    final remainingMin = phase?.remainingMin;
    final remainingMax = phase?.remainingMax;

    return SectionCard(
      title: phase == null ? current.stage : '${phase.name} · fase ${phase.number} de ${phase.total}',
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
          const SizedBox(height: 16),
          DetailGrid(items: [
            DetailItem(
              label: 'Nesta fase',
              value: phase == null
                  ? f.duration(current.stageHours)
                  : '${f.duration(phase.hours)} (o normal é de ${f.number(phase.minHours, 0)} a ${f.number(phase.maxHours, 0)} h)',
            ),
            if (remainingMin != null && remainingMax != null)
              DetailItem(label: 'Falta para acabar', value: 'de ${f.duration(remainingMin)} a ${f.duration(remainingMax)}'),
            DetailItem(label: 'Secagem total', value: f.duration(elapsed)),
            if (total != null && current.isDrying) DetailItem(label: 'Término previsto', value: f.dateTime(current.estimatedCompletion)),
          ]),
          if (phase != null) ...[
            const SizedBox(height: 16),
            Text(
              phase.ready ? 'Já dá para passar de fase' : 'Ainda não é hora de passar de fase',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (phase.overdue) check(Icons.warning_amber_rounded, c.warn, 'Passou do tempo previsto. Olhe as folhas.'),
            for (final item in phase.checks)
              check(item.ok ? Icons.check_circle : Icons.radio_button_unchecked, item.ok ? c.ok : c.muted, phaseCheckLabel(item, prefs.unit)),
            check(Icons.visibility_outlined, c.phase(phase.key), 'Nas folhas: ${phase.visualCheck}'),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: BusyButton(
                label: phase.finishes ? 'Finalizar cura' : 'Passar para ${phase.nextStage}',
                icon: phase.finishes ? Icons.check_circle : Icons.skip_next,
                style: phase.ready ? BusyButtonStyle.filled : BusyButtonStyle.outlined,
                onPressed: () => _advanceStage(phase),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniChart(CuringUnit current, Limits limits) {
    final data = series;
    final unitPref = prefs.unit;
    String format(double value) => '${f.number(value)} ${f.unitSymbol(unitPref)}';
    final points = [
      for (final point in data?.points ?? const <SeriesPoint>[]) ChartPoint(point.time, f.tempValue(point.temperature, unitPref)!),
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => UnitChartPage(unitId: widget.unitId, limits: limits, isDrying: current.isDrying, batchStartedAt: current.cycleStartedAt),
        )),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: Text(
                    current.cycleStartedAt == null ? 'Temperatura da estufada' : 'Temperatura da estufada de ${f.dayMonth(current.cycleStartedAt!)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text('Ver gráfico', style: TextStyle(fontSize: 13, color: context.colors.textSecondary)),
                Icon(Icons.chevron_right, color: context.colors.muted),
              ]),
              const SizedBox(height: 8),
              IgnorePointer(
                child: data == null
                    ? const SizedBox(height: 90)
                    : LineChart(
                        points: points,
                        start: data.since,
                        end: data.until,
                        limitMin: current.phase == null ? null : f.tempValue(limits.tempMin, unitPref),
                        limitMax: current.phase == null ? null : f.tempValue(limits.tempMax, unitPref),
                        format: format,
                        gap: Duration(seconds: (data.bucketSeconds * 3).clamp(300, 1 << 30)),
                        height: 90,
                        semanticLabel: 'Temperatura da estufada',
                        emptyText: current.cycleStartedAt == null
                            ? 'Nenhuma estufada ainda.'
                            : current.isDrying
                                ? 'Sem leituras nesta estufada ainda.'
                                : 'Sem leituras nesta estufada.',
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
