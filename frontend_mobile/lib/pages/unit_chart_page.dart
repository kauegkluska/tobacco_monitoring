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

  /// Nulo: a estufada inteira.
  final int? hours;
}

// O gráfico é da estufada (a carga atual, ou a última), não da estufa.
const _periods = [
  _Period('Estufada toda', null),
  _Period('Últimas 24 h', 24),
  _Period('Últimas 6 h', 6),
];

/// Gráfico completo da estufada, aberto a partir do resumo na tela da estufa.
class UnitChartPage extends StatefulWidget {
  const UnitChartPage({required this.unitId, required this.limits, required this.isDrying, this.batchStartedAt, super.key});

  final int unitId;
  final Limits limits;
  final bool isDrying;

  /// Início da estufada mostrada; nulo se a estufa nunca teve estufada.
  final DateTime? batchStartedAt;

  @override
  State<UnitChartPage> createState() => _UnitChartPageState();
}

class _UnitChartPageState extends State<UnitChartPage> {
  Series? series;
  bool loading = false;
  String? error;
  _Period period = _periods.first;
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
    final hours = period.hours == null ? '' : '&hours=${period.hours}';
    try {
      final result = await api.get('/curing_units/${widget.unitId}/series?batch=true&points=180$hours');
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
      appBar: AppBar(title: const Text('Gráfico da estufada')),
      body: error != null && series == null
          ? ErrorView(title: 'Não foi possível carregar o gráfico', message: error!, onRetry: _load)
          : ListenableBuilder(listenable: prefs, builder: (context, _) => _body()),
    );
  }

  Widget _body() {
    final data = series;
    final unitPref = prefs.unit;
    final limits = widget.limits;
    // Umidade em bulbo úmido estimado: também uma temperatura.
    double convert(double value) => f.tempValue(value, unitPref)!;
    String format(double value) => '${f.number(value)} ${f.unitSymbol(unitPref)}';
    String show(double? value) => value == null ? '--' : format(convert(value));

    final stats = data?.stats;
    final phases = data == null ? const <ChartPhase>[] : chartPhasesOf(data, context.colors, temperature: temperature, unit: unitPref);
    final points = [
      for (final point in data?.points ?? const <SeriesPoint>[])
        if (temperature || !point.wetBulb.isNaN)
        ChartPoint(
          point.time,
          convert(temperature ? point.temperature : point.wetBulb),
          low: convert(temperature ? point.temperatureMin : point.wetBulbMin),
          high: convert(temperature ? point.temperatureMax : point.wetBulbMax),
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
      padding: listPadding(context, top: 4),
      children: [
        if (widget.batchStartedAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '${widget.isDrying ? 'Estufada em andamento' : 'Última estufada'}, iniciada em ${f.dateTime(widget.batchStartedAt)}.',
              style: TextStyle(fontSize: 13.5, color: context.colors.textSecondary),
            ),
          ),
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
          stat('Mínima', temperature ? stats?.temperatureMin : stats?.wetBulbMin),
          stat('Média', temperature ? stats?.temperatureAvg : stats?.wetBulbAvg),
          stat('Máxima', temperature ? stats?.temperatureMax : stats?.wetBulbMax),
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
                  limitMin: phases.isNotEmpty || !temperature ? null : f.tempValue(limits.tempMin, unitPref),
                  limitMax: phases.isNotEmpty ? null : f.tempValue(temperature ? limits.tempMax : limits.wetBulbMax, unitPref),
                  phases: phases,
                  format: format,
                  detail: (point) => point.count > 1 ? '${format(point.low!)} a ${format(point.high!)}' : '1 leitura',
                  gap: Duration(seconds: (data.bucketSeconds * 3).clamp(300, 1 << 30)),
                  height: 260,
                  semanticLabel: '${temperature ? 'Temperatura' : 'Umidade (bulbo úmido estimado)'} da estufada${period.hours == null ? '' : ', últimas ${period.hours} horas'}',
                  emptyText: widget.batchStartedAt == null
                      ? 'Nenhuma estufada ainda. O gráfico começa quando a secagem for iniciada.'
                      : widget.isDrying
                          ? 'Sem leituras neste período da estufada.'
                          : 'Sem leituras nesta estufada. Elas só são gravadas com a secagem ligada.',
                ),
        ),
        if (phases.length > 1) PhaseLegend(phases: phases),
      ],
    );
  }
}
