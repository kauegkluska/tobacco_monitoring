import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/line_chart.dart';
import '../widgets/phases.dart';

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

/// Gráfico completo da estufa, aberto a partir do resumo de 24 h.
class UnitChartPage extends StatefulWidget {
  const UnitChartPage({required this.unitId, required this.limits, required this.isDrying, super.key});

  final int unitId;
  final Limits limits;
  final bool isDrying;

  @override
  State<UnitChartPage> createState() => _UnitChartPageState();
}

class _UnitChartPageState extends State<UnitChartPage> {
  Series? series;
  bool loading = false;
  String? error;
  _Period period = _periods[1];
  bool temperature = true;

  ApiClient get api => AppScope.of(context).api;
  AppPrefs get prefs => AppScope.of(context).prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final until = DateTime.now().toUtc();
    final since = until.subtract(Duration(hours: period.hours));
    try {
      final result = await api.get(
        '/curing_units/${widget.unitId}/series?since=${Uri.encodeQueryComponent(since.toIso8601String())}'
        '&until=${Uri.encodeQueryComponent(until.toIso8601String())}&points=180',
      );
      if (!mounted) return;
      setState(() {
        series = Series.fromJson(result as Map<String, dynamic>);
        error = null;
      });
    } on ApiException catch (exception) {
      if (mounted) setState(() => error = exception.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gráfico')),
      body: error != null && series == null
          ? ErrorView(title: 'Não foi possível carregar o gráfico', message: error!, onRetry: _load)
          : ListenableBuilder(listenable: prefs, builder: (context, _) => _body()),
    );
  }

  Widget _body() {
    final data = series;
    final unitPref = prefs.unit;
    final limits = widget.limits;
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
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
                  _load();
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
          opacity: loading ? 0.5 : 1,
          duration: const Duration(milliseconds: 200),
          child: data == null
              ? const SizedBox(height: 260, child: Center(child: CircularProgressIndicator()))
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
                  height: 260,
                  semanticLabel: '${temperature ? 'Temperatura' : 'Umidade'} nas últimas ${period.label}',
                  emptyText: widget.isDrying ? 'Sem leituras neste período.' : 'Sem leituras. Elas só são gravadas com a secagem ligada.',
                ),
        ),
        if (phases.length > 1) PhaseLegend(phases: phases),
      ],
    );
  }
}
