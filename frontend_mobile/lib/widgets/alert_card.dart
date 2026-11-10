import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import 'common.dart';

/// "Estou ciente": o alerta continua aberto até o valor voltar ao normal.
/// Na queda de temperatura é diferente: aceita o novo nível e encerra, por isso pede confirmação.
Future<bool> acknowledgeAlert(BuildContext context, ApiClient api, AlertItem alert) async {
  if (alert.isDrop) {
    final confirmed = await confirmAction(
      context,
      title: 'Você baixou de propósito?',
      message: 'O alerta será encerrado e esta temperatura passa a ser a referência. Se a fornalha estiver apagando, não confirme.',
      confirmLabel: 'Baixei de propósito',
    );
    if (!confirmed || !context.mounted) return false;
  }
  try {
    await api.post('/alerts/${alert.id}/acknowledge');
    if (context.mounted) showMessage(context, 'Anotado.');
    return true;
  } on ApiException catch (exception) {
    if (context.mounted) showMessage(context, exception.message, error: true);
    return false;
  }
}

Future<bool> resolveAlert(BuildContext context, ApiClient api, AlertItem alert) async {
  final confirmed = await confirmAction(
    context,
    title: 'Encerrar este alerta?',
    message: 'Use só se o problema já acabou. Se continuar, um novo alerta abre sozinho.',
    confirmLabel: 'Encerrar',
  );
  if (!confirmed || !context.mounted) return false;
  try {
    await api.post('/alerts/${alert.id}/resolve');
    if (context.mounted) showMessage(context, 'Alerta encerrado.');
    return true;
  } on ApiException catch (exception) {
    if (context.mounted) showMessage(context, exception.message, error: true);
    return false;
  }
}

/// Detalhes técnicos do alerta: valores medidos e a opção de encerrar à mão.
Future<void> showAlertDetails(
  BuildContext context, {
  required AlertItem alert,
  required TempUnit unit,
  Future<void> Function()? onResolve,
}) {
  String value(double? number) {
    if (number == null) return '--';
    return alert.isTemperature ? f.temp(number, unit) : f.humidity(number);
  }

  final limitLabel = alert.isDrop ? 'Alerta abaixo de' : (alert.isHigh ? 'Máximo' : 'Mínimo');
  return showFormSheet<void>(
    context,
    title: alert.type,
    builder: (sheetContext) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(alert.message, style: const TextStyle(fontSize: 15)),
        const SizedBox(height: 14),
        DetailGrid(items: [
          DetailItem(label: 'Quando', value: f.relative(alert.timestamp)),
          if (alert.value != null) DetailItem(label: alert.isWetBulb ? 'Bulbo úmido' : 'Valor', value: value(alert.value)),
          if (alert.threshold != null) DetailItem(label: limitLabel, value: value(alert.threshold)),
          if (alert.resolvedAt != null) DetailItem(label: 'Encerrado', value: f.fullDate(alert.resolvedAt)),
        ]),
        if (alert.isActive && onResolve != null && !alert.isInfo) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                Navigator.pop(sheetContext);
                await onResolve();
              },
              child: const Text('Encerrar alerta'),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Ações de um alerta: um botão principal e o acesso aos detalhes.
class AlertActions extends StatelessWidget {
  const AlertActions({
    required this.alert,
    required this.unit,
    required this.onAcknowledge,
    required this.onResolve,
    this.onOpenUnit,
    super.key,
  });

  final AlertItem alert;
  final TempUnit unit;
  final Future<void> Function() onAcknowledge;
  final Future<void> Function() onResolve;
  final VoidCallback? onOpenUnit;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (alert.isActive && alert.acknowledgedAt == null && !alert.isInfo)
          BusyButton(
            label: alert.isDrop ? 'Baixei de propósito' : 'Estou ciente',
            icon: Icons.check,
            onPressed: onAcknowledge,
          ),
        TextButton(
          onPressed: () => showAlertDetails(context, alert: alert, unit: unit, onResolve: onResolve),
          child: const Text('Ver detalhes'),
        ),
        if (onOpenUnit != null) TextButton(onPressed: onOpenUnit, child: const Text('Abrir estufa')),
      ],
    );
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (accent, icon) = !alert.isActive
        ? (c.muted, Icons.check_circle_outline)
        : alert.isCritical
            ? (c.crit, Icons.error)
            : alert.isInfo
                ? (c.textSecondary, Icons.info_outline)
                : (c.warn, Icons.warning_amber_rounded);
    final status = !alert.isActive
        ? 'Encerrado'
        : alert.acknowledgedAt != null
            ? '${alert.severityLabel} · ciente'
            : alert.severityLabel;

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
                    if (alert.message.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(alert.message, style: TextStyle(fontSize: 14.5, color: c.textSecondary)),
                    ],
                    if (!alert.isInfo || onOpenUnit != null) ...[
                      const SizedBox(height: 8),
                      AlertActions(
                        alert: alert,
                        unit: unit,
                        onAcknowledge: onAcknowledge,
                        onResolve: onResolve,
                        onOpenUnit: onOpenUnit,
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
