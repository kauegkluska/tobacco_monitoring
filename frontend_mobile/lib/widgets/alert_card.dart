import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import 'common.dart';

/// Reconhecer: o alerta continua ativo até o valor voltar à faixa.
Future<bool> acknowledgeAlert(BuildContext context, ApiClient api, AlertItem alert) async {
  try {
    await api.post('/alerts/${alert.id}/acknowledge');
    if (context.mounted) showMessage(context, 'Alerta reconhecido.');
    return true;
  } on ApiException catch (exception) {
    if (context.mounted) showMessage(context, exception.message, error: true);
    return false;
  }
}

Future<bool> resolveAlert(BuildContext context, ApiClient api, AlertItem alert) async {
  final confirmed = await confirmAction(
    context,
    title: 'Resolver alerta?',
    message: 'Se o valor continuar fora da faixa, um novo alerta abre na próxima leitura.',
    confirmLabel: 'Resolver',
  );
  if (!confirmed || !context.mounted) return false;
  try {
    await api.post('/alerts/${alert.id}/resolve');
    if (context.mounted) showMessage(context, 'Alerta resolvido.');
    return true;
  } on ApiException catch (exception) {
    if (context.mounted) showMessage(context, exception.message, error: true);
    return false;
  }
}

class AlertCard extends StatelessWidget {
  const AlertCard({
    required this.alert,
    required this.unit,
    required this.onAcknowledge,
    required this.onResolve,
    this.onOpenUnit,
    this.showUnitName = true,
    super.key,
  });

  final AlertItem alert;
  final TempUnit unit;
  final Future<void> Function() onAcknowledge;
  final Future<void> Function() onResolve;
  final VoidCallback? onOpenUnit;
  final bool showUnitName;

  String _value(double? value) {
    if (value == null) return '--';
    return alert.isTemperature ? f.temp(value, unit) : f.humidity(value);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (accent, icon) = !alert.isActive
        ? (c.ok, Icons.check_circle)
        : alert.isCritical
            ? (c.crit, Icons.error)
            : (c.warn, Icons.warning_amber_rounded);
    final status = !alert.isActive
        ? 'Resolvido'
        : alert.acknowledgedAt != null
            ? '${alert.severityLabel} · reconhecido'
            : alert.severityLabel;
    final hasValues = alert.value != null && alert.threshold != null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(icon, size: 18, color: accent),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(status, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent)),
                        ),
                        Text(f.relative(alert.timestamp), style: TextStyle(fontSize: 12.5, color: c.muted)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      showUnitName ? '${alert.type} · ${alert.unitName ?? 'Estufa ${alert.unitId}'}' : alert.type,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    if (hasValues) ...[
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(text: _value(alert.value), style: TextStyle(fontWeight: FontWeight.w700, color: alert.isActive ? c.crit : null)),
                          TextSpan(text: '  ·  limite ${_value(alert.threshold)}', style: TextStyle(color: c.textSecondary)),
                        ]),
                      ),
                    ],
                    if (alert.message.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(alert.message, style: TextStyle(fontSize: 13.5, color: c.textSecondary)),
                    ],
                    if (!alert.isActive && alert.resolvedAt != null) ...[
                      const SizedBox(height: 4),
                      Text('Encerrado em ${f.fullDate(alert.resolvedAt)}', style: TextStyle(fontSize: 12.5, color: c.muted)),
                    ],
                    if (alert.isActive || onOpenUnit != null) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (alert.isActive) BusyButton(label: 'Resolver', icon: Icons.check, onPressed: onResolve),
                          if (alert.isActive && alert.acknowledgedAt == null)
                            BusyButton(label: 'Reconhecer', icon: Icons.done_all, style: BusyButtonStyle.outlined, onPressed: onAcknowledge),
                          if (onOpenUnit != null)
                            TextButton.icon(onPressed: onOpenUnit, icon: const Icon(Icons.chevron_right), label: const Text('Abrir estufa')),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
