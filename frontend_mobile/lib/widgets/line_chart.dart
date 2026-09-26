import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/format.dart' as f;
import '../core/theme.dart';

class ChartPoint {
  const ChartPoint(this.time, this.value, {this.low, this.high, this.count = 1});

  final DateTime time;
  final double value;
  final double? low;
  final double? high;
  final int count;
}

/// Gráfico de linha de uma série com faixa segura (limites), interrupção onde faltaram
/// leituras e seleção por toque ou arraste horizontal.
class LineChart extends StatefulWidget {
  const LineChart({
    required this.points,
    required this.format,
    required this.start,
    required this.end,
    this.limitMin,
    this.limitMax,
    this.detail,
    this.gap = const Duration(minutes: 10),
    this.height = 240,
    this.semanticLabel = 'Gráfico',
    this.emptyText = 'Sem leituras neste período.',
    super.key,
  });

  /// Valores já na unidade de exibição, em ordem cronológica.
  final List<ChartPoint> points;
  final String Function(double value) format;
  final String? Function(ChartPoint point)? detail;
  final DateTime start;
  final DateTime end;
  final double? limitMin;
  final double? limitMax;
  final Duration gap;
  final double height;
  final String semanticLabel;
  final String emptyText;

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  int? selected;

  @override
  void didUpdateWidget(LineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (selected != null && selected! >= widget.points.length) selected = null;
  }

  void _select(_Geometry geometry, double dx) {
    final index = geometry.nearestIndex(widget.points, dx);
    if (index != selected) setState(() => selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (widget.points.isEmpty) {
      return SizedBox(
        height: widget.height * 0.75,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(widget.emptyText, textAlign: TextAlign.center, style: TextStyle(color: colors.muted)),
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final geometry = _Geometry.compute(
        points: widget.points,
        start: widget.start,
        end: widget.end,
        limitMin: widget.limitMin,
        limitMax: widget.limitMax,
        width: constraints.maxWidth,
        height: widget.height,
      );
      final last = widget.points.last;
      final selectedPoint = selected == null ? null : widget.points[selected!];
      const tooltipWidth = 176.0;

      return Semantics(
        label: '${widget.semanticLabel}. Valor mais recente: ${widget.format(last.value)}.',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _select(geometry, details.localPosition.dx),
          onHorizontalDragStart: (details) => _select(geometry, details.localPosition.dx),
          onHorizontalDragUpdate: (details) => _select(geometry, details.localPosition.dx),
          child: SizedBox(
            height: widget.height,
            width: constraints.maxWidth,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(
                  size: Size(constraints.maxWidth, widget.height),
                  painter: _ChartPainter(
                    geometry: geometry,
                    points: widget.points,
                    selected: selected,
                    gap: widget.gap,
                    format: widget.format,
                    colors: colors,
                    surface: context.scheme.surface,
                    textColor: context.scheme.onSurface,
                    crosshairColor: colors.textSecondary,
                  ),
                ),
                if (selectedPoint != null)
                  Positioned(
                    left: (geometry.x(selectedPoint.time) - tooltipWidth / 2).clamp(0.0, math.max(0.0, constraints.maxWidth - tooltipWidth)),
                    top: 0,
                    width: tooltipWidth,
                    child: IgnorePointer(child: _Tooltip(point: selectedPoint, format: widget.format, detail: widget.detail)),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _Tooltip extends StatelessWidget {
  const _Tooltip({required this.point, required this.format, this.detail});

  final ChartPoint point;
  final String Function(double value) format;
  final String? Function(ChartPoint point)? detail;

  @override
  Widget build(BuildContext context) {
    final extra = detail?.call(point);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      color: context.scheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(width: 14, height: 2, color: context.colors.chartLine),
              const SizedBox(width: 8),
              Text(format(point.value), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ]),
            const SizedBox(height: 2),
            Text(f.fullDate(point.time), style: TextStyle(fontSize: 12, color: context.colors.muted)),
            if (extra != null) Text(extra, style: TextStyle(fontSize: 12, color: context.colors.muted)),
          ],
        ),
      ),
    );
  }
}

const _tickSteps = [
  Duration(minutes: 5),
  Duration(minutes: 10),
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 2),
  Duration(hours: 3),
  Duration(hours: 6),
  Duration(hours: 12),
  Duration(days: 1),
  Duration(days: 2),
  Duration(days: 7),
];

double _niceStep(double range, int targetTicks) {
  final rough = range / math.max(1, targetTicks);
  final power = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
  final fraction = rough / power;
  final nice = fraction <= 1
      ? 1.0
      : fraction <= 2
          ? 2.0
          : fraction <= 2.5
              ? 2.5
              : fraction <= 5
                  ? 5.0
                  : 10.0;
  return nice * power;
}

class _Geometry {
  _Geometry({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.startMs,
    required this.endMs,
    required this.yMin,
    required this.yMax,
    required this.yStep,
    required this.xTicks,
    required this.limitMin,
    required this.limitMax,
  });

  factory _Geometry.compute({
    required List<ChartPoint> points,
    required DateTime start,
    required DateTime end,
    required double? limitMin,
    required double? limitMax,
    required double width,
    required double height,
  }) {
    const left = 38.0;
    const right = 44.0;
    const top = 16.0;
    const bottom = 24.0;
    final startMs = start.millisecondsSinceEpoch.toDouble();
    var endMs = end.millisecondsSinceEpoch.toDouble();
    if (endMs <= startMs) endMs = startMs + 3600000;

    final values = [for (final point in points) point.value, if (limitMin != null) limitMin, if (limitMax != null) limitMax];
    var yMin = values.reduce(math.min);
    var yMax = values.reduce(math.max);
    if (yMax - yMin < 2) {
      yMin -= 1;
      yMax += 1;
    }
    final step = _niceStep(yMax - yMin, height < 200 ? 3 : 4);
    yMin = (yMin / step).floor() * step;
    yMax = (yMax / step).ceil() * step;

    final plotWidth = width - left - right;
    final span = endMs - startMs;
    final maxTicks = math.max(2, plotWidth ~/ 72);
    final tickStep = _tickSteps.firstWhere((candidate) => span / candidate.inMilliseconds <= maxTicks, orElse: () => _tickSteps.last);
    final ticks = <(double, String)>[];
    final offset = start.timeZoneOffset.inMilliseconds;
    final stepMs = tickStep.inMilliseconds;
    var tick = (((startMs + offset) / stepMs).ceil() * stepMs - offset).toDouble();
    final byDay = tickStep >= const Duration(days: 1) || span > const Duration(days: 2).inMilliseconds;
    while (tick <= endMs) {
      final date = DateTime.fromMillisecondsSinceEpoch(tick.round());
      final x = left + (tick - startMs) / span * plotWidth;
      ticks.add((x, byDay ? f.dayMonth(date) : f.time(date)));
      tick += stepMs;
    }

    return _Geometry(
      left: left,
      right: width - right,
      top: top,
      bottom: height - bottom,
      startMs: startMs,
      endMs: endMs,
      yMin: yMin,
      yMax: yMax,
      yStep: step,
      xTicks: ticks,
      limitMin: limitMin,
      limitMax: limitMax,
    );
  }

  final double left;
  final double right;
  final double top;
  final double bottom;
  final double startMs;
  final double endMs;
  final double yMin;
  final double yMax;
  final double yStep;
  final List<(double, String)> xTicks;
  final double? limitMin;
  final double? limitMax;

  double x(DateTime time) => left + (time.millisecondsSinceEpoch - startMs) / (endMs - startMs) * (right - left);
  double y(double value) => top + (1 - (value - yMin) / (yMax - yMin)) * (bottom - top);

  int nearestIndex(List<ChartPoint> points, double dx) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final distance = (x(points[i].time) - dx).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return best;
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.geometry,
    required this.points,
    required this.selected,
    required this.gap,
    required this.format,
    required this.colors,
    required this.surface,
    required this.textColor,
    required this.crosshairColor,
  });

  final _Geometry geometry;
  final List<ChartPoint> points;
  final int? selected;
  final Duration gap;
  final String Function(double value) format;
  final AppColors colors;
  final Color surface;
  final Color textColor;
  final Color crosshairColor;

  void _text(Canvas canvas, String text, Offset position, {Color? color, double size = 11, FontWeight weight = FontWeight.w500, TextAlign align = TextAlign.left, bool halo = false}) {
    final style = TextStyle(color: color ?? colors.muted, fontSize: size, fontWeight: weight, fontFeatures: const [FontFeature.tabularFigures()]);
    final painter = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    final dx = switch (align) {
      TextAlign.right => position.dx - painter.width,
      TextAlign.center => position.dx - painter.width / 2,
      _ => position.dx,
    };
    final offset = Offset(dx, position.dy - painter.height / 2);
    if (halo) {
      final outline = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            fontWeight: weight,
            fontFeatures: const [FontFeature.tabularFigures()],
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4
              ..strokeJoin = StrokeJoin.round
              ..color = surface,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      outline.paint(canvas, offset);
    }
    painter.paint(canvas, offset);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final gridPaint = Paint()
      ..color = colors.chartGrid
      ..strokeWidth = 1;

    // Grade e eixo Y
    final integerStep = g.yStep == g.yStep.roundToDouble();
    for (var value = g.yMin; value <= g.yMax + g.yStep / 2; value += g.yStep) {
      final py = g.y(value);
      canvas.drawLine(Offset(g.left, py), Offset(g.right, py), gridPaint);
      _text(canvas, integerStep ? value.round().toString() : f.number(value), Offset(g.left - 6, py), align: TextAlign.right);
    }

    // Faixa segura
    if (g.limitMin != null || g.limitMax != null) {
      final top = g.limitMax != null ? g.y(g.limitMax!) : g.top;
      final bottom = g.limitMin != null ? g.y(g.limitMin!) : g.bottom;
      canvas.drawRect(Rect.fromLTRB(g.left, top, g.right, bottom), Paint()..color = colors.chartBand);
      final limitPaint = Paint()
        ..color = colors.chartLimit
        ..strokeWidth = 1;
      for (final (label, value) in [('máx', g.limitMax), ('mín', g.limitMin)]) {
        if (value == null) continue;
        final py = g.y(value);
        canvas.drawLine(Offset(g.left, py), Offset(g.right, py), limitPaint);
        final labelY = py - 9 < g.top + 6 ? py + 9 : py - 9;
        _text(canvas, '$label ${format(value)}', Offset(g.left + 6, labelY), weight: FontWeight.w700, halo: true);
      }
    }

    // Eixo X
    for (final (x, label) in g.xTicks) {
      _text(canvas, label, Offset(x, size.height - 9), align: TextAlign.center);
    }

    // Área e linha, interrompidas onde faltaram leituras
    final linePaint = Paint()
      ..color = colors.chartLine
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final areaPaint = Paint()..color = colors.chartArea;
    final dotPaint = Paint()..color = colors.chartLine;
    final ringPaint = Paint()
      ..color = surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    var segment = <ChartPoint>[];
    void flush() {
      if (segment.isEmpty) return;
      if (segment.length == 1) {
        canvas.drawCircle(Offset(g.x(segment.first.time), g.y(segment.first.value)), 3, dotPaint);
      } else {
        final line = Path()..moveTo(g.x(segment.first.time), g.y(segment.first.value));
        for (final point in segment.skip(1)) {
          line.lineTo(g.x(point.time), g.y(point.value));
        }
        final area = Path.from(line)
          ..lineTo(g.x(segment.last.time), g.bottom)
          ..lineTo(g.x(segment.first.time), g.bottom)
          ..close();
        canvas.drawPath(area, areaPaint);
        canvas.drawPath(line, linePaint);
      }
      segment = [];
    }

    for (var i = 0; i < points.length; i++) {
      if (i > 0 && points[i].time.difference(points[i - 1].time) > gap) flush();
      segment.add(points[i]);
    }
    flush();

    // Valor mais recente
    final last = points.last;
    final lastOffset = Offset(g.x(last.time), g.y(last.value));
    canvas.drawCircle(lastOffset, 4, dotPaint);
    canvas.drawCircle(lastOffset, 5, ringPaint);
    final endLabel = format(last.value).replaceAll(RegExp(r'\s?°[CF]$|%$'), '');
    _text(canvas, endLabel, Offset(math.min(lastOffset.dx + 8, size.width - 30), lastOffset.dy), color: textColor, size: 12, weight: FontWeight.w700, halo: true);

    // Seleção
    if (selected != null) {
      final point = points[selected!];
      final px = g.x(point.time);
      canvas.drawLine(Offset(px, g.top), Offset(px, g.bottom), Paint()
        ..color = crosshairColor
        ..strokeWidth = 1);
      final center = Offset(px, g.y(point.value));
      canvas.drawCircle(center, 5, dotPaint);
      canvas.drawCircle(center, 6, ringPaint);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.selected != selected || oldDelegate.geometry.right != geometry.right || oldDelegate.colors != colors;
}
