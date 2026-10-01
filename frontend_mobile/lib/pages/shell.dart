import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_scope.dart';
import '../core/buzzer.dart';
import '../core/models.dart';
import '../core/prefs.dart';
import '../widgets/common.dart';
import 'alerts_page.dart';
import 'settings_page.dart';
import 'unit_page.dart';
import 'units_page.dart';

enum AppTab { units, alerts, settings }

/// Ações que as telas podem pedir para a estrutura principal.
class ShellActions {
  const ShellActions({required this.goTo, required this.setAlertCount, required this.logout});

  final void Function(AppTab tab) goTo;
  final void Function(int count) setAlertCount;
  final Future<void> Function() logout;
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = {
  AppTab.units: _Destination('Estufas', Icons.warehouse_outlined, Icons.warehouse),
  AppTab.alerts: _Destination('Alertas', Icons.notifications_outlined, Icons.notifications),
  AppTab.settings: _Destination('Ajustes', Icons.settings_outlined, Icons.settings),
};

class HomeShell extends StatefulWidget {
  const HomeShell({required this.onLogout, super.key});

  final Future<void> Function() onLogout;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _badgeInterval = Duration(seconds: 30);
  static const _buzzerInterval = Duration(seconds: 5);

  AppTab tab = AppTab.units;
  int alertCount = 0;
  Timer? badgeTimer;
  Timer? buzzerTimer;
  int? lastEventId;
  final buzzer = PhoneBuzzer();
  late final ShellActions actions = ShellActions(goTo: _goTo, setAlertCount: _setAlertCount, logout: widget.onLogout);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshBadge();
      _watchBuzzer();
    });
  }

  @override
  void dispose() {
    badgeTimer?.cancel();
    buzzerTimer?.cancel();
    buzzer.dispose();
    super.dispose();
  }

  /// Acompanha os avisos sonoros do gateway (uma saída ligou) e repete o aviso no celular.
  Future<void> _watchBuzzer() async {
    buzzerTimer?.cancel();
    final scope = AppScope.of(context);
    try {
      final after = lastEventId;
      final path = after == null ? '/output-events/?limit=1' : '/output-events/?after_id=$after&limit=20';
      final events = (await scope.api.get(path) as List).map((item) => OutputEvent.fromJson(item as Map<String, dynamic>)).toList();
      if (events.isNotEmpty) lastEventId = events.first.id;
      // Na primeira consulta só marca onde parou: avisos antigos não tocam de novo.
      lastEventId ??= 0;
      final rang = events.where((event) => event.buzzer).toList();
      if (after != null && rang.isNotEmpty && mounted) _announce(rang.first, scope.prefs.phoneBuzzer, scope.prefs.unit, rang.length);
    } catch (_) {
      // O indicador de conexão já mostra a falha.
    } finally {
      if (mounted) buzzerTimer = Timer(_buzzerInterval, _watchBuzzer);
    }
  }

  void _announce(OutputEvent event, bool playSound, TempUnit unit, int count) {
    if (playSound) buzzer.play();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final where = event.unitName == null ? '' : ' em ${event.unitName}';
    final extra = count > 1 ? ' (+${count - 1})' : '';
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Row(
        children: [
          const Icon(Icons.volume_up, color: Color(0xffffb938)),
          const SizedBox(width: 10),
          Expanded(child: Text('Aviso sonoro$where: ${describeOutputEvent(event, unit)}$extra')),
        ],
      ),
      action: SnackBarAction(label: 'Ver', onPressed: () => openUnit(context, event.unitId)),
    ));
  }

  Future<void> _refreshBadge() async {
    badgeTimer?.cancel();
    try {
      final alerts = await AppScope.of(context).api.get('/alerts/?active=true&limit=1000') as List;
      _setAlertCount(alerts.length);
    } catch (_) {
      // O indicador de conexão já mostra a falha.
    } finally {
      if (mounted) badgeTimer = Timer(_badgeInterval, _refreshBadge);
    }
  }

  void _setAlertCount(int count) {
    if (mounted && count != alertCount) setState(() => alertCount = count);
  }

  void _goTo(AppTab next) => setState(() => tab = next);

  Widget _page() {
    final key = ValueKey(tab);
    return switch (tab) {
      AppTab.units => UnitsPage(key: key, actions: actions),
      AppTab.alerts => AlertsPage(key: key, actions: actions),
      AppTab.settings => SettingsPage(key: key, actions: actions),
    };
  }

  Widget _icon(AppTab item, bool selected) {
    final destination = _destinations[item]!;
    final icon = Icon(selected ? destination.selectedIcon : destination.icon);
    if (item != AppTab.alerts || alertCount == 0) return icon;
    return Badge(label: Text(alertCount > 99 ? '99+' : '$alertCount'), child: icon);
  }

  @override
  Widget build(BuildContext context) {
    final api = AppScope.of(context).api;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    const tabs = AppTab.values;

    final appBar = AppBar(
      titleSpacing: 16,
      title: Text(_destinations[tab]!.label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      actions: [
        ValueListenableBuilder<bool>(
          valueListenable: api.online,
          builder: (context, online, _) => online
              ? const SizedBox.shrink()
              : const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: StatusBadge(kind: StatusKind.crit, label: 'Sem conexão', icon: Icons.cloud_off),
                ),
        ),
      ],
    );

    final body = _page();

    if (wide) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: tabs.indexOf(tab),
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (index) => _goTo(tabs[index]),
              destinations: [
                for (final item in tabs)
                  NavigationRailDestination(icon: _icon(item, false), selectedIcon: _icon(item, true), label: Text(_destinations[item]!.label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1100), child: body))),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabs.indexOf(tab),
        onDestinationSelected: (index) => _goTo(tabs[index]),
        destinations: [
          for (final item in tabs)
            NavigationDestination(icon: _icon(item, false), selectedIcon: _icon(item, true), label: _destinations[item]!.label),
        ],
      ),
    );
  }
}
