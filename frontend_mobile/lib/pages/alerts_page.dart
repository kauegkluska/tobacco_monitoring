import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import 'shell.dart';

enum _Filter { active, resolved, all }

/// Central de alertas: ativos, resolvidos e todos, com reconhecer e resolver.
class AlertsPage extends StatefulWidget {
  const AlertsPage({required this.actions, super.key});

  final ShellActions actions;

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  static const _pollInterval = Duration(seconds: 15);

  List<AlertItem>? alerts;
  List<CuringUnit> units = [];
  _Filter filter = _Filter.active;
  int? unitFilter;
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
      final results = await Future.wait([api.get('/alerts/?limit=500'), api.get('/curing_units/')]);
      if (!mounted) return;
      final next = (results[0] as List).map((item) => AlertItem.fromJson(item as Map<String, dynamic>)).toList();
      setState(() {
        alerts = next;
        units = (results[1] as List).map((item) => CuringUnit.fromJson(item as Map<String, dynamic>)).toList();
        error = null;
      });
      widget.actions.setAlertCount(next.where((alert) => alert.isActive).length);
    } on ApiException catch (exception) {
      if (mounted && alerts == null) setState(() => error = exception.message);
    } finally {
      if (mounted) timer = Timer(_pollInterval, _load);
    }
  }

  Future<void> _acknowledge(AlertItem alert) async {
    try {
      await api.post('/alerts/${alert.id}/acknowledge');
      if (!mounted) return;
      showMessage(context, 'Alerta reconhecido. Ele continua ativo até o valor normalizar.');
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _resolve(AlertItem alert) async {
    final confirmed = await confirmAction(
      context,
      title: 'Encerrar este alerta?',
      message: 'Use quando o problema já foi tratado. Se o valor continuar fora da faixa, um novo alerta será aberto na próxima leitura.',
      confirmLabel: 'Resolver',
    );
    if (!confirmed) return;
    try {
      await api.post('/alerts/${alert.id}/resolve');
      if (!mounted) return;
      showMessage(context, 'Alerta resolvido.');
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorView(title: 'Não foi possível carregar os alertas', message: error!, onRetry: _load);
    final all = alerts;
    if (all == null) return const LoadingView(message: 'Carregando alertas…');

    final byUnit = unitFilter == null ? all : all.where((alert) => alert.unitId == unitFilter).toList();
    final counts = {
      _Filter.active: byUnit.where((alert) => alert.isActive).length,
      _Filter.resolved: byUnit.where((alert) => !alert.isActive).length,
      _Filter.all: byUnit.length,
    };
    final list = byUnit.where((alert) {
      return switch (filter) {
        _Filter.active => alert.isActive,
        _Filter.resolved => !alert.isActive,
        _Filter.all => true,
      };
    }).toList();
    final empty = switch (filter) {
      _Filter.active => ('Nenhum alerta ativo', 'Todas as estufas estão dentro dos limites. Os alertas aparecem aqui assim que algum valor sair da faixa.'),
      _Filter.resolved => ('Nenhum alerta resolvido', 'Alertas encerrados aparecem aqui, automaticamente ou quando você os resolve.'),
      _Filter.all => ('Nenhum alerta registrado', 'Os alertas são criados quando a temperatura ou a umidade saem da faixa segura.'),
    };

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const PageHeader(
              eyebrow: 'Central de alertas',
              title: 'Ocorrências',
              subtitle: 'Um alerta abre quando um valor sai da faixa segura e fecha sozinho quando ele volta ao normal.',
            ),
            const SizedBox(height: 14),
            SegmentedButton<_Filter>(
              segments: [
                ButtonSegment(value: _Filter.active, label: Text('Ativos (${counts[_Filter.active]})')),
                ButtonSegment(value: _Filter.resolved, label: Text('Resolvidos (${counts[_Filter.resolved]})')),
                ButtonSegment(value: _Filter.all, label: Text('Todos (${counts[_Filter.all]})')),
              ],
              selected: {filter},
              showSelectedIcon: false,
              onSelectionChanged: (value) => setState(() => filter = value.first),
            ),
            if (units.length > 1) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<int?>(
                initialValue: unitFilter,
                decoration: const InputDecoration(labelText: 'Estufa', prefixIcon: Icon(Icons.warehouse_outlined)),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Todas as estufas')),
                  for (final unit in units) DropdownMenuItem<int?>(value: unit.id, child: Text(unit.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (value) => setState(() => unitFilter = value),
              ),
            ],
            const SizedBox(height: 14),
            if (list.isEmpty)
              SectionCard(
                child: EmptyState(
                  icon: filter == _Filter.active ? Icons.check_circle_outline : Icons.notifications_none,
                  title: empty.$1,
                  message: empty.$2,
                ),
              )
            else
              for (final alert in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _AlertCard(
                    alert: alert,
                    unit: prefs.unit,
                    onAcknowledge: () => _acknowledge(alert),
                    onResolve: () => _resolve(alert),
                    onOpenUnit: () {
                      prefs.setUnitId(alert.unitId);
                      widget.actions.goTo(AppTab.history);
                    },
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.unit, required this.onAcknowledge, required this.onResolve, required this.onOpenUnit});

  final AlertItem alert;
  final TempUnit unit;
  final Future<void> Function() onAcknowledge;
  final Future<void> Function() onResolve;
  final VoidCallback onOpenUnit;

  String _describe(double? value) {
    if (value == null) return '--';
    return alert.isTemperature ? f.tempWithOther(value, unit) : f.humidity(value);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (kind, label, icon, accent, iconBackground) = !alert.isActive
        ? (StatusKind.ok, 'Resolvido', Icons.check_circle, c.border, c.okContainer)
        : alert.isCritical
            ? (StatusKind.crit, 'Crítico', Icons.error, c.crit, c.critContainer)
            : (StatusKind.warn, 'Atenção', Icons.warning_amber_rounded, c.warn, c.warnContainer);
    final iconColor = !alert.isActive ? c.ok : (alert.isCritical ? c.crit : c.warn);
    final expected = alert.threshold == null ? '--' : '${alert.isHigh ? 'Até' : 'A partir de'} ${_describe(alert.threshold)}';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 5, color: accent),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(radius: 21, backgroundColor: iconBackground, child: Icon(icon, color: iconColor)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(spacing: 6, runSpacing: 6, children: [
                            StatusBadge(kind: kind, label: label, icon: icon),
                            if (alert.acknowledgedAt != null && alert.isActive)
                              const StatusBadge(kind: StatusKind.neutral, label: 'Reconhecido', icon: Icons.done_all),
                          ]),
                          const SizedBox(height: 6),
                          Text(
                            '${alert.type} · ${alert.unitName ?? 'Estufa ${alert.unitId}'}',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                    Text(f.relative(alert.timestamp), style: TextStyle(fontSize: 12.5, color: c.muted)),
                  ],
                ),
                const SizedBox(height: 10),
                Text(alert.message, style: TextStyle(color: c.textSecondary)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _Compare(icon: Icons.flag_outlined, label: 'Esperado', value: expected)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _Compare(
                          icon: Icons.warning_amber_rounded,
                          label: 'Encontrado',
                          value: _describe(alert.value),
                          color: alert.isActive ? c.crit : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Aberto em ${f.fullDate(alert.timestamp)}${alert.resolvedAt != null ? ' · encerrado em ${f.fullDate(alert.resolvedAt)}' : ''}',
                  style: TextStyle(fontSize: 12.5, color: c.muted),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: alert.isActive
                          ? BusyButton(
                              label: alert.acknowledgedAt != null ? 'Reconhecido' : 'Reconhecer',
                              icon: Icons.done_all,
                              style: BusyButtonStyle.outlined,
                              onPressed: alert.acknowledgedAt != null ? null : onAcknowledge,
                            )
                          : OutlinedButton.icon(onPressed: onOpenUnit, icon: const Icon(Icons.show_chart), label: const Text('Ver histórico')),
                    ),
                    if (alert.isActive) ...[
                      const SizedBox(width: 10),
                      Expanded(child: BusyButton(label: 'Resolver', icon: Icons.check, onPressed: onResolve)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Compare extends StatelessWidget {
  const _Compare({required this.icon, required this.label, required this.value, this.color});

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, size: 15, color: context.colors.muted),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.colors.muted)),
        ]),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}
