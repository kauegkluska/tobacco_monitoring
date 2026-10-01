import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/models.dart';
import '../core/prefs.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';
import 'shell.dart';
import 'unit_page.dart';

enum _State { active, resolved, all }

/// Alertas de todas as estufas, com filtro por estado, estufa e gravidade.
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
  _State state = _State.active;
  int? unitFilter;
  String? severityFilter;
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

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorView(title: 'Não foi possível carregar os alertas', message: error!, onRetry: _load);
    final all = alerts;
    if (all == null) return const LoadingView();

    final filtered = all
        .where((alert) => unitFilter == null || alert.unitId == unitFilter)
        .where((alert) => severityFilter == null || alert.severity == severityFilter)
        .toList();
    int count(_State value) => filtered.where((alert) => _matches(alert, value)).length;
    final list = filtered.where((alert) => _matches(alert, state)).toList();

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            SegmentedButton<_State>(
              segments: [
                ButtonSegment(value: _State.active, label: Text('Ativos (${count(_State.active)})')),
                ButtonSegment(value: _State.resolved, label: Text('Resolvidos (${count(_State.resolved)})')),
                ButtonSegment(value: _State.all, label: Text('Todos (${count(_State.all)})')),
              ],
              selected: {state},
              showSelectedIcon: false,
              onSelectionChanged: (value) => setState(() => state = value.first),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (units.length > 1) ...[
                  Expanded(
                    child: DropdownButtonFormField<int?>(
                      initialValue: unitFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Estufa', isDense: true),
                      items: [
                        const DropdownMenuItem<int?>(value: null, child: Text('Todas')),
                        for (final unit in units) DropdownMenuItem<int?>(value: unit.id, child: Text(unit.name, overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (value) => setState(() => unitFilter = value),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    initialValue: severityFilter,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Gravidade', isDense: true),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('Todas')),
                      for (final entry in severityLabels.entries.toList().reversed)
                        DropdownMenuItem<String?>(value: entry.key, child: Text(entry.value)),
                    ],
                    onChanged: (value) => setState(() => severityFilter = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (list.isEmpty)
              SectionCard(
                child: EmptyState(
                  icon: state == _State.active ? Icons.check_circle_outline : Icons.notifications_none,
                  title: state == _State.active ? 'Nenhum alerta ativo' : 'Nenhum alerta',
                ),
              )
            else
              for (final alert in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AlertCard(
                    alert: alert,
                    unit: prefs.unit,
                    onAcknowledge: () async {
                      if (await acknowledgeAlert(context, api, alert)) await _load();
                    },
                    onResolve: () async {
                      if (await resolveAlert(context, api, alert)) await _load();
                    },
                    onOpenUnit: () async {
                      await openUnit(context, alert.unitId);
                      if (mounted) await _load();
                    },
                  ),
                ),
          ],
        ),
      ),
    );
  }

  static bool _matches(AlertItem alert, _State state) => switch (state) {
        _State.active => alert.isActive,
        _State.resolved => !alert.isActive,
        _State.all => true,
      };
}
