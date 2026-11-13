import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/models.dart';
import '../core/prefs.dart';
import '../widgets/alert_card.dart';
import '../widgets/common.dart';
import 'unit_page.dart';

/// Alertas já encerrados. Os ativos ficam no topo da estufa.
class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  static const _pollInterval = Duration(seconds: 30);

  List<AlertItem>? alerts;
  List<CuringUnit> units = [];
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
      final results = await Future.wait([api.get('/alerts/?active=false&limit=500'), api.get('/curing_units/')]);
      if (!mounted) return;
      setState(() {
        alerts = (results[0] as List).map((item) => AlertItem.fromJson(item as Map<String, dynamic>)).toList();
        units = (results[1] as List).map((item) => CuringUnit.fromJson(item as Map<String, dynamic>)).toList();
        error = null;
      });
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
    final list = all.where((alert) => unitFilter == null || alert.unitId == unitFilter).toList();

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: listPadding(context, top: 8),
          children: [
            if (units.length > 1) ...[
              DropdownButtonFormField<int?>(
                initialValue: unitFilter,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Estufa', isDense: true),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Todas')),
                  for (final unit in units) DropdownMenuItem<int?>(value: unit.id, child: Text(unit.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (value) => setState(() => unitFilter = value),
              ),
              const SizedBox(height: 14),
            ],
            if (list.isEmpty)
              const SectionCard(child: EmptyState(icon: Icons.notifications_none, title: 'Nenhum alerta encerrado'))
            else
              for (final alert in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AlertCard(
                    alert: alert,
                    unit: prefs.unit,
                    onAcknowledge: () async {},
                    onResolve: () async {},
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
}
