import 'package:flutter/material.dart';

import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';

/// Leituras mais antigas que isso aparecem apagadas.
const staleAfter = Duration(minutes: 5);

/// Leitura antiga, sem sinal ou gravada fora da secagem atual.
bool isStale(Reading? reading, CuringUnit unit, Device? device) {
  if (reading == null || device == null || !device.online || !unit.isDrying) return true;
  return DateTime.now().difference(reading.timestamp) > staleAfter;
}

/// Condição para avançar de fase, com o alvo de temperatura na unidade escolhida.
String phaseCheckLabel(PhaseCheck check, TempUnit unit) {
  final target = check.target;
  if (check.metric == 'temperature' && target != null) return 'Temperatura em ${f.temp(target, unit, digits: 0)} ou mais';
  return check.label;
}

enum Metric { temperature, humidity }

/// Valor grande de temperatura ou umidade, com a faixa esperada da fase.
///
/// A umidade aparece como bulbo úmido estimado, em graus, como no termômetro molhado da estufa e nos guias de cura;
/// a umidade relativa medida pelo sensor fica na linha de baixo.
class ReadingTile extends StatelessWidget {
  const ReadingTile({
    required this.metric,
    required this.value,
    required this.limits,
    required this.unit,
    this.stale = false,
    this.compact = false,
    this.target,
    this.relativeHumidity,
    super.key,
  });

  final Metric metric;

  /// Em °C: temperatura do ar (bulbo seco) ou bulbo úmido estimado (umidade).
  final double? value;

  /// Umidade relativa (%) da mesma leitura, mostrada abaixo do bulbo úmido.
  final double? relativeHumidity;

  /// Faixa da fase em andamento; nula sem fase (nada a comparar).
  final Limits? limits;
  final TempUnit unit;
  final bool stale;

  /// Versão da lista de estufas: sem régua e com números menores.
  final bool compact;

  /// Temperatura alvo da ventoinha em °C, mostrada abaixo do valor.
  final double? target;

  @override
  Widget build(BuildContext context) {
    final isTemp = metric == Metric.temperature;
    final range = limits;
    // Temperatura: faixa da fase. Umidade: só o teto do bulbo úmido, nas fases que têm o alerta "Umidade alta".
    final min = range == null || !isTemp ? null : range.tempMin;
    final max = range == null ? null : (isTemp ? range.tempMax : range.wetBulbMax);
    final state = max == null ? null : (min == null ? (value != null && value! > max ? 'high' : 'ok') : rangeState(value, min, max));
    double? display(double? v) => f.tempValue(v, unit);
    final symbol = f.unitSymbol(unit);
    final expected = isTemp
        ? (min == null || max == null ? null : f.tempRange(min, max, unit))
        : (max == null ? null : 'até ${f.temp(max, unit, digits: 1)}');
    final outside = state == 'high' || state == 'low';
    final valueColor = stale
        ? context.colors.muted
        : outside
            ? context.colors.crit
            : context.scheme.onSurface;
    final label = isTemp ? 'Temperatura' : 'Umidade';

    final number = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              f.number(display(value)),
              style: TextStyle(
                fontSize: compact ? 30 : 44,
                height: 1.05,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: valueColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        const SizedBox(width: 3),
        Text(symbol, style: TextStyle(fontSize: compact ? 15 : 20, fontWeight: FontWeight.w600, color: context.colors.textSecondary)),
      ],
    );

    return Semantics(
      container: true,
      label: '$label: ${f.number(display(value))} $symbol${isTemp ? '' : ' de bulbo úmido, umidade relativa ${f.humidity(relativeHumidity, digits: 0)}'}.'
          '${expected == null ? '' : ' Esperado: $expected.'}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Icon(isTemp ? Icons.thermostat : Icons.water_drop_outlined, size: 16, color: context.colors.textSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.colors.textSecondary)),
              ),
              if (!compact && outside && !stale)
                Icon(state == 'high' ? Icons.arrow_upward : Icons.arrow_downward, size: 18, color: context.colors.crit),
            ]),
            const SizedBox(height: 4),
            number,
            if (!compact && min != null && max != null) ...[
              const SizedBox(height: 10),
              RangeMeter(value: display(value), min: display(min)!, max: display(max)!, outside: outside && !stale),
              const SizedBox(height: 6),
            ] else
              const SizedBox(height: 2),
            if (!isTemp)
              Text(
                'Bulbo úmido estimado · UR ${f.humidity(relativeHumidity, digits: 0)}',
                style: TextStyle(fontSize: 12.5, color: context.colors.textSecondary),
              ),
            if (target != null)
              Text(
                'Alvo ${f.temp(target, unit)}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: context.scheme.primary),
              ),
            // Fase sem teto do bulbo úmido (Amarelação, Secagem do talo): nada a comparar na umidade.
            if (expected != null || range == null)
              Text(
                expected == null ? 'Sem fase em andamento' : 'Esperado $expected',
                style: TextStyle(fontSize: 12.5, color: outside && !stale ? context.colors.crit : context.colors.muted),
              ),
          ],
        ),
      ),
    );
  }
}

/// Régua com a faixa esperada destacada e um marcador no valor atual.
class RangeMeter extends StatelessWidget {
  const RangeMeter({required this.value, required this.min, required this.max, required this.outside, super.key});

  final double? value;
  final double min;
  final double max;
  final bool outside;

  @override
  Widget build(BuildContext context) {
    final span = max - min;
    final scaleMin = min - span * 0.5;
    final scaleMax = max + span * 0.5;
    double position(double v) => ((v - scaleMin) / (scaleMax - scaleMin)).clamp(0.0, 1.0);

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return SizedBox(
        height: 16,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            Container(height: 8, decoration: BoxDecoration(color: context.colors.surface3, borderRadius: BorderRadius.circular(999))),
            Positioned(
              left: width * position(min),
              width: width * (position(max) - position(min)),
              child: Container(height: 8, decoration: BoxDecoration(color: context.colors.okContainer, borderRadius: BorderRadius.circular(999))),
            ),
            if (value != null)
              Positioned(
                left: (width * position(value!) - 8).clamp(0.0, width - 16),
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: outside ? context.colors.crit : context.colors.ok,
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
