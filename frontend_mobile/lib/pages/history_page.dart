import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/line_chart.dart';
import 'shell.dart';

class _Range {
  const _Range(this.label, this.hours);

  final String label;
  final int hours;
}

const _ranges = [
  _Range('1 h', 1),
  _Range('6 h', 6),
  _Range('24 h', 24),
  _Range('7 dias', 24 * 7),
  _Range('30 dias', 24 * 30),
];

/// Histórico: gráfico por período, resumo (mín/média/máx) e registros.
class HistoryPage extends StatefulWidget {
  const HistoryPage({required this.actions, super.key});

  final ShellActions actions;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  static const _pageSize = 20;

  Overview? overview;
  CuringUnit? unit;
  Series? series;
  _Range range = _ranges[2];
  bool temperature = true;
  bool loading = false;
  int visibleRows = _pageSize;
  String? error;

  ApiClient get api => AppScope.of(context).api;
  AppPrefs get prefs => AppScope.of(context).prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final api = this.api;
    final prefs = this.prefs;
    try {
      final data = await loadOverview(api);
      if (!mounted) return;
      setState(() {
        overview = data;
        unit = data.pick(prefs.unitId);
        error = null;
      });
      if (unit != null) await _loadSeries();
    } on ApiException catch (exception) {
      if (mounted) setState(() => error = exception.message);
    }
  }

  Future<void> _loadSeries() async {
    final current = unit;
    if (current == null) return;
    setState(() => loading = true);
    final until = DateTime.now().toUtc();
    final since = until.subtract(Duration(hours: range.hours));
    try {
      final result = await api.get(
        '/curing_units/${current.id}/series?since=${Uri.encodeQueryComponent(since.toIso8601String())}'
        '&until=${Uri.encodeQueryComponent(until.toIso8601String())}&points=180',
      );
      if (!mounted) return;
      setState(() {
        series = Series.fromJson(result as Map<String, dynamic>);
        visibleRows = _pageSize;
      });
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorView(title: 'Não foi possível carregar o histórico', message: error!, onRetry: _init);
    final data = overview;
    if (data == null) return const LoadingView(message: 'Carregando histórico…');
    final current = unit;
    if (current == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            child: EmptyState(
              icon: Icons.warehouse_outlined,
              title: 'Nenhuma estufa cadastrada',
              message: 'Cadastre uma estufa e vincule o sensor para ver o histórico.',
              action: FilledButton.icon(
                onPressed: () => widget.actions.goTo(AppTab.units, intent: const UnitsIntent(createUnit: true)),
                icon: const Icon(Icons.add),
                label: const Text('Cadastrar estufa'),
              ),
            ),
          ),
        ],
      );
    }

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final device = data.deviceFor(current);
        final limits = device?.limits ?? Limits.defaults;
        final unitPref = prefs.unit;
        double convert(double value) => temperature ? f.tempValue(value, unitPref)! : value;
        String format(double value) => temperature ? '${f.number(value)} ${f.unitSymbol(unitPref)}' : '${f.number(value)}%';

        return RefreshIndicator(
          onRefresh: _loadSeries,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              PageHeader(
                eyebrow: 'Histórico',
                title: current.name,
                subtitle: 'Como a temperatura e a umidade variaram ao longo da cura.',
              ),
              const SizedBox(height: 14),
              if (data.units.length > 1) ...[
                DropdownButtonFormField<int>(
                  key: ValueKey('history-unit-${current.id}'),
                  initialValue: current.id,
                  decoration: const InputDecoration(labelText: 'Estufa', prefixIcon: Icon(Icons.warehouse_outlined)),
                  items: [for (final item in data.units) DropdownMenuItem(value: item.id, child: Text(item.name, overflow: TextOverflow.ellipsis))],
                  onChanged: (value) {
                    prefs.setUnitId(value);
                    setState(() => unit = data.pick(value));
                    _loadSeries();
                  },
                ),
                const SizedBox(height: 12),
              ],
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<_Range>(
                  segments: [for (final item in _ranges) ButtonSegment(value: item, label: Text(item.label))],
                  selected: {range},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) {
                    setState(() => range = value.first);
                    _loadSeries();
                  },
                ),
              ),
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Temperatura'), icon: Icon(Icons.thermostat)),
                  ButtonSegment(value: false, label: Text('Umidade'), icon: Icon(Icons.water_drop_outlined)),
                ],
                selected: {temperature},
                onSelectionChanged: (value) => setState(() => temperature = value.first),
              ),
              const SizedBox(height: 14),
              AnimatedOpacity(
                opacity: loading ? 0.5 : 1,
                duration: const Duration(milliseconds: 200),
                child: series == null
                    ? const LoadingView()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _stats(series!, convert, format),
                          const SizedBox(height: 14),
                          _chart(series!, current, limits, unitPref, convert, format),
                          const SizedBox(height: 14),
                          _records(series!, convert, format, unitPref),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stats(Series data, double Function(double) convert, String Function(double) format) {
    final stats = data.stats;
    final min = temperature ? stats.temperatureMin : stats.humidityMin;
    final avg = temperature ? stats.temperatureAvg : stats.humidityAvg;
    final max = temperature ? stats.temperatureMax : stats.humidityMax;
    String show(double? value) => value == null ? '--' : format(convert(value));

    Widget tile(String label, IconData icon, String value, [String? meta]) => Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(icon, size: 16, color: context.colors.textSecondary),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.colors.textSecondary)),
                ]),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                ),
                if (meta != null) Text(meta, style: TextStyle(fontSize: 12, color: context.colors.muted)),
              ],
            ),
          ),
        );

    return GridView.count(
      crossAxisCount: MediaQuery.sizeOf(context).width >= 700 ? 4 : 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.75,
      children: [
        tile('Mínima', Icons.arrow_downward, show(min)),
        tile('Média', Icons.bar_chart, show(avg)),
        tile('Máxima', Icons.arrow_upward, show(max)),
        tile('Leituras', Icons.sensors, f.integer(stats.count), stats.lastAt == null ? 'Nenhuma no período' : 'Última ${f.relative(stats.lastAt)}'),
      ],
    );
  }

  Widget _chart(Series data, CuringUnit current, Limits limits, TempUnit unitPref, double Function(double) convert, String Function(double) format) {
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
    final bucketNote = data.bucketSeconds > 60 ? 'Cada ponto é a média de ${f.duration(data.bucketSeconds / 3600)} de leituras. ' : '';
    return SectionCard(
      title: '${temperature ? 'Temperatura' : 'Umidade relativa'} · ${range.label}',
      icon: temperature ? Icons.thermostat : Icons.water_drop,
      subtitle: '${bucketNote}Toque ou arraste no gráfico para ver os valores.',
      child: LineChart(
        points: points,
        start: data.since,
        end: data.until,
        limitMin: temperature ? f.tempValue(limits.tempMin, unitPref) : limits.humidityMin,
        limitMax: temperature ? f.tempValue(limits.tempMax, unitPref) : limits.humidityMax,
        format: format,
        detail: (point) => point.count > 1 ? '${format(point.low!)} a ${format(point.high!)} · ${f.plural(point.count, 'leitura')}' : '1 leitura',
        gap: Duration(seconds: (data.bucketSeconds * 3).clamp(300, 1 << 30)),
        height: 260,
        semanticLabel: '${temperature ? 'Temperatura' : 'Umidade'} no período de ${range.label}',
        emptyText: current.isDrying
            ? 'Nenhuma leitura neste período.'
            : 'Nenhuma leitura neste período. As leituras só são gravadas com a secagem em andamento.',
      ),
    );
  }

  Widget _records(Series data, double Function(double) convert, String Function(double) format, TempUnit unitPref) {
    final rows = data.points.reversed.toList();
    final visible = rows.take(visibleRows).toList();
    return SectionCard(
      title: 'Registros do período',
      icon: Icons.schedule,
      trailing: Text(f.plural(rows.length, 'intervalo'), style: TextStyle(color: context.colors.muted, fontSize: 13)),
      child: rows.isEmpty
          ? Text('Sem registros no período selecionado.', style: TextStyle(color: context.colors.textSecondary))
          : Column(
              children: [
                for (final point in visible)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: context.colors.surface2, borderRadius: BorderRadius.circular(10)),
                          child: Icon(Icons.schedule, size: 20, color: context.colors.textSecondary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(f.dateTime(point.time), style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(f.plural(point.count, 'leitura'), style: TextStyle(fontSize: 12, color: context.colors.muted)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(f.temp(point.temperature, unitPref), style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(f.humidity(point.humidity), style: TextStyle(color: context.colors.textSecondary)),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (rows.length > visibleRows)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton(
                      onPressed: () => setState(() => visibleRows += _pageSize * 2),
                      child: Text('Mostrar mais (${rows.length - visibleRows} restantes)'),
                    ),
                  ),
              ],
            ),
    );
  }
}
