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
import '../widgets/line_chart.dart';
import '../widgets/phases.dart';
import 'unit_page.dart';

/// Abre as últimas secagens de uma estufa por cima da tela dela.
Future<void> openUnitCycles(BuildContext context, CuringUnit unit) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(title: Text('Secagens · ${unit.name}')),
      body: CyclesPage(unitId: unit.id),
    ),
  ));
}

Future<void> openCycle(BuildContext context, int cycleId) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => CycleDetailPage(cycleId: cycleId)));
}

typedef CycleStatus = ({StatusKind kind, String label, IconData icon});

CycleStatus cycleStatus(CuringCycle cycle) {
  if (cycle.isFinished) return (kind: StatusKind.ok, label: 'Concluída', icon: Icons.check_circle);
  if (!cycle.inProgress) return (kind: StatusKind.warn, label: 'Interrompida', icon: Icons.cancel_outlined);
  if (cycle.isDrying) return (kind: StatusKind.info, label: 'Em andamento', icon: Icons.local_fire_department_outlined);
  return (kind: StatusKind.offline, label: 'Parada', icon: Icons.pause_circle_outline);
}

/// "12/09/2026 08:00 até 18/09/2026 14:00"
String cyclePeriod(CuringCycle cycle) {
  final end = cycle.endedAt == null ? (cycle.isDrying ? 'agora' : 'parada') : f.fullDate(cycle.endedAt);
  return '${f.fullDate(cycle.startedAt)} até $end';
}

/// Últimas secagens (estufadas), da mais nova para a mais antiga. Com [unitId], só as daquela estufa.
class CyclesPage extends StatefulWidget {
  const CyclesPage({this.unitId, super.key});

  final int? unitId;

  @override
  State<CyclesPage> createState() => _CyclesPageState();
}

class _CyclesPageState extends State<CyclesPage> {
  static const _pollInterval = Duration(seconds: 30);

  List<CuringCycle>? cycles;
  int? unitFilter;
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
    try {
      final unit = widget.unitId;
      final result = await api.get('/curing-cycles/?limit=100${unit == null ? '' : '&curing_unit_id=$unit'}') as List;
      if (!mounted) return;
      setState(() {
        cycles = result.map((item) => CuringCycle.fromJson(item as Map<String, dynamic>)).toList();
        error = null;
      });
    } on ApiException catch (exception) {
      if (mounted && cycles == null) setState(() => error = exception.message);
    } finally {
      if (mounted) timer = Timer(_pollInterval, _load);
    }
  }

  Future<void> _open(CuringCycle cycle) async {
    timer?.cancel();
    await openCycle(context, cycle.id);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorView(title: 'Não foi possível carregar as secagens', message: error!, onRetry: _load);
    final all = cycles;
    if (all == null) return const LoadingView();

    final units = <int, String>{for (final cycle in all) cycle.unitId: cycle.unitName};
    final list = all.where((cycle) => unitFilter == null || cycle.unitId == unitFilter).toList();

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (widget.unitId == null && units.length > 1) ...[
              DropdownButtonFormField<int?>(
                initialValue: unitFilter,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Estufa', isDense: true),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Todas')),
                  for (final entry in units.entries) DropdownMenuItem<int?>(value: entry.key, child: Text(entry.value, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (value) => setState(() => unitFilter = value),
              ),
              const SizedBox(height: 14),
            ],
            if (list.isEmpty)
              const SectionCard(
                child: EmptyState(
                  icon: Icons.history,
                  title: 'Nenhuma secagem',
                  message: 'Cada estufada aparece aqui ao iniciar a secagem e fica guardada depois de finalizada.',
                ),
              )
            else
              LayoutBuilder(builder: (context, constraints) {
                final columns = constraints.maxWidth >= 720 ? 2 : 1;
                final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final cycle in list)
                      SizedBox(
                        width: width,
                        child: _CycleCard(cycle: cycle, unit: prefs.unit, showUnitName: widget.unitId == null, onTap: () => _open(cycle)),
                      ),
                  ],
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _CycleCard extends StatelessWidget {
  const _CycleCard({required this.cycle, required this.unit, required this.showUnitName, required this.onTap});

  final CuringCycle cycle;
  final TempUnit unit;
  final bool showUnitName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = cycleStatus(cycle);
    final stats = cycle.stats;
    final c = context.colors;
    final footer = [
      switch (stats.count) { 0 => 'Sem leituras', 1 => '1 leitura', final count => '${f.integer(count)} leituras' },
      if (cycle.alerts > 0) f.plural(cycle.alerts, 'alerta'),
    ].join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      showUnitName ? cycle.unitName : 'Estufada de ${f.dayMonth(cycle.startedAt)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                  StatusBadge(kind: status.kind, label: status.label, icon: status.icon),
                  Icon(Icons.chevron_right, color: c.muted),
                ],
              ),
              const SizedBox(height: 4),
              Text(cyclePeriod(cycle), style: TextStyle(fontSize: 13.5, color: c.textSecondary)),
              const SizedBox(height: 14),
              PhaseSteps(current: cycle.isFinished ? null : cycle.stageNumber, finished: cycle.isFinished),
              const SizedBox(height: 14),
              DetailGrid(items: [
                DetailItem(label: 'Secagem', value: f.duration(cycle.dryingHours)),
                DetailItem(
                  label: 'Temperatura',
                  value: stats.count == 0 ? '--' : 'média ${f.temp(stats.temperatureAvg, unit, digits: 0)}, máx. ${f.temp(stats.temperatureMax, unit, digits: 0)}',
                ),
              ]),
              const SizedBox(height: 12),
              Text(
                footer,
                style: TextStyle(
                  fontSize: 12.5,
                  color: cycle.criticalAlerts > 0 ? c.crit : c.muted,
                  fontWeight: cycle.criticalAlerts > 0 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uma secagem: período, fases, resumo das leituras, gráfico do período e alertas.
class CycleDetailPage extends StatefulWidget {
  const CycleDetailPage({required this.cycleId, super.key});

  final int cycleId;

  @override
  State<CycleDetailPage> createState() => _CycleDetailPageState();
}

class _CycleDetailPageState extends State<CycleDetailPage> {
  CuringCycle? cycle;
  Series? series;
  bool temperature = true;
  String? error;

  ApiClient get api => AppScope.of(context).api;
  AppPrefs get prefs => AppScope.of(context).prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final next = CuringCycle.fromJson(await api.get('/curing-cycles/${widget.cycleId}') as Map<String, dynamic>);
      final since = next.startedAt.toUtc();
      final until = (next.endedAt ?? DateTime.now()).toUtc();
      final result = await api.get(
        '/curing_units/${next.unitId}/series?since=${Uri.encodeQueryComponent(since.toIso8601String())}'
        '&until=${Uri.encodeQueryComponent(until.toIso8601String())}&points=180',
      );
      if (!mounted) return;
      setState(() {
        cycle = next;
        series = Series.fromJson(result as Map<String, dynamic>);
        error = null;
      });
    } on ApiException catch (exception) {
      if (!mounted) return;
      if (cycle == null) {
        setState(() => error = exception.message);
      } else {
        showMessage(context, exception.message, error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = cycle;
    return Scaffold(
      appBar: AppBar(title: Text(current == null ? 'Secagem' : 'Secagem · ${current.unitName}')),
      body: error != null
          ? ErrorView(title: 'Não foi possível carregar a secagem', message: error!, onRetry: _load)
          : current == null
              ? const LoadingView()
              : ListenableBuilder(listenable: prefs, builder: (context, _) => _body(current)),
    );
  }

  Widget _body(CuringCycle current) {
    final unitPref = prefs.unit;
    final status = cycleStatus(current);
    final stats = current.stats;
    final c = context.colors;
    final children = <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          StatusBadge(kind: status.kind, label: status.label, icon: status.icon),
          if (current.finalStage != null)
            PhaseTag(
              label: current.inProgress ? 'Fase atual · ${current.finalStage}' : 'Última fase · ${current.finalStage}',
              color: c.phase(phaseKeyOf(current.finalStage!)),
            ),
        ],
      ),
      SectionCard(
        title: 'Resumo',
        icon: Icons.eco_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PhaseSteps(current: current.isFinished ? null : current.stageNumber, finished: current.isFinished),
            const SizedBox(height: 16),
            DetailGrid(items: [
              DetailItem(label: 'Início', value: f.fullDate(current.startedAt)),
              DetailItem(label: 'Fim', value: current.endedAt == null ? status.label : f.fullDate(current.endedAt)),
              DetailItem(label: 'Secagem (sem o tempo parado)', value: f.duration(current.dryingHours)),
              DetailItem(label: 'Leituras', value: f.integer(stats.count)),
              DetailItem(
                label: 'Alertas',
                value: current.alerts == 0
                    ? 'Nenhum'
                    : '${current.alerts}${current.criticalAlerts > 0 ? ' (${current.criticalAlerts} críticos ou piores)' : ''}',
              ),
            ]),
            if (current.phases.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Tempo em cada fase', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final phase in current.phases)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    PhaseSwatch(color: c.phase(phase.key)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(phase.stage)),
                    Text(f.duration(phase.hours), style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => openUnit(context, current.unitId),
                icon: const Icon(Icons.warehouse_outlined),
                label: const Text('Abrir estufa'),
              ),
            ),
          ],
        ),
      ),
      SectionCard(
        title: 'Temperatura e umidade',
        icon: Icons.show_chart,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DetailGrid(items: [
              DetailItem(label: 'Temperatura mín. / méd. / máx.', value: _range(stats.temperatureMin, stats.temperatureAvg, stats.temperatureMax, (v) => f.temp(v, unitPref, digits: 0))),
              DetailItem(label: 'Umidade mín. / méd. / máx.', value: _range(stats.humidityMin, stats.humidityAvg, stats.humidityMax, (v) => f.humidity(v, digits: 0))),
            ]),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Temperatura'), icon: Icon(Icons.thermostat)),
                ButtonSegment(value: false, label: Text('Umidade'), icon: Icon(Icons.water_drop_outlined)),
              ],
              selected: {temperature},
              onSelectionChanged: (value) => setState(() => temperature = value.first),
            ),
            const SizedBox(height: 12),
            _chart(),
          ],
        ),
      ),
      if (current.alertItems.isNotEmpty) ...[
        Text('Alertas desta secagem', style: context.text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        for (final alert in current.alertItems)
          AlertCard(
            alert: alert,
            unit: unitPref,
            showUnitName: false,
            onAcknowledge: () async {
              if (await acknowledgeAlert(context, api, alert)) await _load();
            },
            onResolve: () async {
              if (await resolveAlert(context, api, alert)) await _load();
            },
          ),
      ],
    ];

    return RefreshIndicator(
      onRefresh: _load,
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

  static String _range(double? min, double? avg, double? max, String Function(double value) format) {
    if (min == null || avg == null || max == null) return '--';
    return '${format(min)} / ${format(avg)} / ${format(max)}';
  }

  Widget _chart() {
    final data = series;
    if (data == null) return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
    final unitPref = prefs.unit;
    double convert(double value) => temperature ? f.tempValue(value, unitPref)! : value;
    String format(double value) => temperature ? '${f.number(value)} ${f.unitSymbol(unitPref)}' : '${f.number(value)}%';
    final phases = chartPhasesOf(data, context.colors, temperature: temperature, unit: unitPref);
    final points = [
      for (final point in data.points)
        ChartPoint(
          point.time,
          convert(temperature ? point.temperature : point.humidity),
          low: convert(temperature ? point.temperatureMin : point.humidityMin),
          high: convert(temperature ? point.temperatureMax : point.humidityMax),
          count: point.count,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LineChart(
          points: points,
          start: data.since,
          end: data.until,
          phases: phases,
          format: format,
          detail: (point) => point.count > 1 ? '${format(point.low!)} a ${format(point.high!)}' : '1 leitura',
          gap: Duration(seconds: (data.bucketSeconds * 3).clamp(300, 1 << 30)),
          height: 220,
          semanticLabel: '${temperature ? 'Temperatura' : 'Umidade'} durante a secagem',
          emptyText: 'Sem leituras nesta secagem.',
        ),
        if (phases.length > 1) PhaseLegend(phases: phases),
      ],
    );
  }
}
