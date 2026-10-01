import 'package:flutter/material.dart';

import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import 'line_chart.dart';

/// Fases do período (resposta de /series) no formato do gráfico, já na unidade de exibição.
List<ChartPhase> chartPhasesOf(Series series, AppColors colors, {required bool temperature, required TempUnit unit}) => [
  for (final phase in series.phases)
    ChartPhase(
      start: phase.start,
      end: phase.end,
      name: phase.stage,
      color: colors.phase(phase.key),
      min: temperature ? f.tempValue(phase.tempMin, unit) : phase.humidityMin,
      max: temperature ? f.tempValue(phase.tempMax, unit) : phase.humidityMax,
    ),
];

class PhaseSwatch extends StatelessWidget {
  const PhaseSwatch({required this.color, this.size = 10, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
  );
}

/// Etiqueta com a cor da fase, ex.: "Fase 2 de 4 · Murchamento".
class PhaseTag extends StatelessWidget {
  const PhaseTag({required this.label, required this.color, super.key});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Color.alphaBlend(color.withValues(alpha: 0.16), context.scheme.surface),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PhaseSwatch(color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// Legenda das fases que aparecem no gráfico.
class PhaseLegend extends StatelessWidget {
  const PhaseLegend({required this.phases, this.describe, super.key});

  final List<ChartPhase> phases;
  final String Function(ChartPhase phase)? describe;

  @override
  Widget build(BuildContext context) {
    if (phases.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          for (final phase in phases)
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: PhaseSwatch(color: phase.color),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: phase.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if (describe != null)
                          TextSpan(
                            text: ' · ${describe!(phase)}',
                            style: TextStyle(color: context.colors.muted),
                          ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// As quatro fases em sequência: concluídas, a atual em destaque e as próximas apagadas.
class PhaseSteps extends StatelessWidget {
  const PhaseSteps({required this.current, required this.finished, super.key});

  /// Número da fase atual (1 a 4), ou null sem secagem.
  final int? current;
  final bool finished;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < curingPhases.length; index++) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(
            child: Builder(
              builder: (context) {
                final number = index + 1;
                final done = finished || (current != null && number < current!);
                final active = current == number;
                final color = colors.phase(curingPhases[index].key);
                return Semantics(
                  label:
                      '${curingPhases[index].name}${active
                          ? ', fase atual'
                          : done
                          ? ', concluída'
                          : ''}',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: active ? 8 : 6,
                        decoration: BoxDecoration(
                          color: done || active ? color : Color.alphaBlend(color.withValues(alpha: 0.28), colors.surface3),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        curingPhases[index].name,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.2,
                          fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                          color: active ? context.scheme.onSurface : (done ? colors.textSecondary : colors.muted),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
