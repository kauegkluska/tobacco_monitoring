import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/decision.dart';
import '../widgets/phases.dart';
import '../widgets/unit_forms.dart';
import '../widgets/unit_widgets.dart';
import 'shell.dart';
import 'unit_page.dart';

/// Aba Estufa: com uma só, abre direto nela; com várias, lista da mais urgente para a mais tranquila.
class UnitsPage extends StatefulWidget {
  const UnitsPage({required this.actions, super.key});

  final ShellActions actions;

  @override
  State<UnitsPage> createState() => _UnitsPageState();
}

class _UnitsPageState extends State<UnitsPage> {
  static const _pollInterval = Duration(seconds: 5);
  // Com a estufa aberta direto, ela mesma já consulta o servidor.
  static const _singleUnitInterval = Duration(seconds: 30);

  Overview? data;
  String? error;
  Timer? timer;

  ApiClient get api => AppScope.of(context).api;
  AppPrefs get prefs => AppScope.of(context).prefs;

  bool _opensDirectly(Overview overview) =>
      overview.units.length == 1 && overview.devices.every((device) => device.unitId != null);

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
      final overview = data;
      if (mounted) timer = Timer(overview != null && _opensDirectly(overview) ? _singleUnitInterval : _pollInterval, _load);
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

  Decision _decisionOf(CuringUnit unit, Overview overview, bool connected) => decide(
        unit: unit,
        device: overview.deviceFor(unit),
        latest: unit.latest,
        connected: connected,
        warnings: unit.activeAlerts,
        criticals: unit.criticalAlerts,
      );

  @override
  Widget build(BuildContext context) {
    final overview = data;
    if (overview != null && _opensDirectly(overview)) {
      final only = overview.units.single;
      return UnitPage(key: ValueKey(only.id), unitId: only.id, onGone: _load, onCreateUnit: _create);
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Text('Estufas', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      ),
      body: error != null
          ? ErrorView(title: 'Não foi possível carregar as estufas', message: error!, onRetry: _load)
          : overview == null
              ? const LoadingView()
              : AnimatedBuilder(
                  animation: Listenable.merge([prefs, api.online]),
                  builder: (context, _) => _list(overview),
                ),
    );
  }

  Widget _list(Overview overview) {
    final connected = api.online.value;
    final loose = overview.devices.where((device) => device.unitId == null).toList();
    final units = [...overview.units]
      ..sort((a, b) => _decisionOf(a, overview, connected).rank.compareTo(_decisionOf(b, overview, connected).rank));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (!connected) ...[
            const StatusBanner(
              kind: StatusKind.offline,
              icon: Icons.cloud_off,
              title: 'Sem conexão com o monitor',
              text: 'Os números abaixo podem estar velhos. Confira a internet do celular.',
            ),
            const SizedBox(height: 12),
          ],
          if (units.isEmpty)
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
                  for (final unit in units)
                    SizedBox(
                      width: width,
                      child: _UnitCard(
                        unit: unit,
                        device: overview.deviceFor(unit),
                        tempUnit: prefs.unit,
                        decision: _decisionOf(unit, overview, connected),
                        onTap: () => _open(unit.id),
                      ),
                    ),
                ],
              );
            }),
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
                    subtitle: Text(device.online ? 'Respondendo' : 'Último contato ${f.relative(device.lastSeen)}'),
                    trailing: IconButton(tooltip: 'Desvincular', icon: const Icon(Icons.link_off), onPressed: () => _unlink(device)),
                  ),
              ]),
            ),
          ],
          if (units.isNotEmpty) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Nova estufa')),
            ),
          ],
        ],
      ),
    );
  }
}

class _UnitCard extends StatelessWidget {
  const _UnitCard({required this.unit, required this.device, required this.tempUnit, required this.decision, required this.onTap});

  final CuringUnit unit;
  final Device? device;
  final TempUnit tempUnit;
  final Decision decision;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final latest = unit.latest;
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
                  GestureDetector(
                    onTap: () => showStatusLegend(context),
                    child: StatusBadge(kind: decision.kind, label: decision.short, icon: decision.icon),
                  ),
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
                    child: ReadingTile(
                      metric: Metric.humidity,
                      value: latest?.wetBulb,
                      relativeHumidity: latest?.humidity,
                      dryBulb: latest?.temperature,
                      limits: limits,
                      unit: tempUnit,
                      stale: stale,
                      compact: true,
                    ),
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
