import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/phases.dart';
import '../widgets/unit_forms.dart';
import '../widgets/unit_widgets.dart';
import 'shell.dart';
import 'unit_page.dart';

/// Tela inicial: uma linha por estufa com temperatura, umidade e situação.
class UnitsPage extends StatefulWidget {
  const UnitsPage({required this.actions, super.key});

  final ShellActions actions;

  @override
  State<UnitsPage> createState() => _UnitsPageState();
}

class _UnitsPageState extends State<UnitsPage> {
  static const _pollInterval = Duration(seconds: 5);

  Overview? data;
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
      final next = await loadOverview(api);
      if (!mounted) return;
      setState(() {
        data = next;
        error = null;
      });
      widget.actions.setAlertCount(next.units.fold(0, (sum, unit) => sum + unit.activeAlerts));
    } on ApiException catch (exception) {
      if (mounted && data == null) setState(() => error = exception.message);
    } finally {
      if (mounted) timer = Timer(_pollInterval, _load);
    }
  }

  Future<void> _open(int unitId) async {
    timer?.cancel();
    await openUnit(context, unitId);
    if (mounted) await _load();
  }

  Future<void> _create() async {
    final created = await showUnitForm(context, api, count: data?.units.length ?? 0);
    if (created != null && mounted) await _open(created.id);
  }

  Future<void> _unlink(Device device) async {
    final confirmed = await confirmAction(
      context,
      title: 'Desvincular ${device.code}?',
      message: 'O sensor sai da sua conta. Você pode vinculá-lo de novo depois.',
      confirmLabel: 'Desvincular',
      danger: true,
    );
    if (!confirmed) return;
    try {
      await api.delete('/devices/${device.id}');
      if (!mounted) return;
      showMessage(context, 'Sensor desvinculado.');
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorView(title: 'Não foi possível carregar as estufas', message: error!, onRetry: _load);
    final overview = data;
    if (overview == null) return const LoadingView();
    final loose = overview.devices.where((device) => device.unitId == null).toList();

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            if (overview.units.isEmpty)
              SectionCard(
                child: EmptyState(
                  icon: Icons.warehouse_outlined,
                  title: 'Nenhuma estufa',
                  message: 'Cadastre a estufa e vincule o sensor dela.',
                  action: FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Nova estufa')),
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
                    for (final unit in overview.units)
                      SizedBox(width: width, child: _UnitCard(unit: unit, device: overview.deviceFor(unit), tempUnit: prefs.unit, onTap: () => _open(unit.id))),
                  ],
                );
              }),
            if (overview.units.isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Nova estufa')),
              ),
            ],
            if (loose.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Sensores sem estufa', style: context.text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Card(
                child: Column(children: [
                  for (final device in loose)
                    ListTile(
                      leading: Icon(Icons.sensors, color: device.online ? context.colors.ok : context.colors.muted),
                      title: Text(device.code),
                      subtitle: Text(device.online ? 'Online' : 'Último contato ${f.relative(device.lastSeen)}'),
                      trailing: IconButton(tooltip: 'Desvincular', icon: const Icon(Icons.link_off), onPressed: () => _unlink(device)),
                    ),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UnitCard extends StatelessWidget {
  const _UnitCard({required this.unit, required this.device, required this.tempUnit, required this.onTap});

  final CuringUnit unit;
  final Device? device;
  final TempUnit tempUnit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final latest = unit.latest;
    final status = unitStatus(
      unit: unit,
      device: device,
      latest: latest,
      activeAlerts: unit.activeAlerts,
      criticalAlerts: unit.criticalAlerts,
    );
    final stale = isStale(latest, unit, device);
    final limits = unit.phase == null ? null : unit.limitsWith(device);
    final phase = unit.phase;
    final c = context.colors;
    final footer = [
      latest == null ? 'Sem leituras' : 'Leitura ${f.relative(latest.timestamp)}',
      if (unit.activeAlerts > 0) f.plural(unit.activeAlerts, 'alerta ativo', 'alertas ativos'),
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
                    child: Text(unit.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  StatusBadge(kind: status.kind, label: status.label, icon: status.icon),
                  Icon(Icons.chevron_right, color: c.muted),
                ],
              ),
              const SizedBox(height: 4),
              Row(children: [
                PhaseSwatch(color: c.phase(phaseKeyOf(unit.stage))),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    phase == null ? unit.stage : '${unit.stage} · fase ${phase.number} de ${phase.total}',
                    style: TextStyle(fontSize: 13.5, color: c.textSecondary),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ReadingTile(metric: Metric.temperature, value: latest?.temperature, limits: limits, unit: tempUnit, stale: stale, compact: true),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ReadingTile(metric: Metric.humidity, value: latest?.humidity, limits: limits, unit: tempUnit, stale: stale, compact: true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                footer,
                style: TextStyle(
                  fontSize: 12.5,
                  color: unit.activeAlerts > 0 ? (unit.criticalAlerts > 0 ? c.crit : c.onWarnContainer) : c.muted,
                  fontWeight: unit.activeAlerts > 0 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
