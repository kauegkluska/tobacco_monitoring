import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/unit_forms.dart';

/// Sensor da estufa: só importa quando há algum problema, por isso fica fora da tela principal.
class EquipmentPage extends StatefulWidget {
  const EquipmentPage({required this.unitId, super.key});

  final int unitId;

  @override
  State<EquipmentPage> createState() => _EquipmentPageState();
}

class _EquipmentPageState extends State<EquipmentPage> {
  Device? device;
  bool loaded = false;
  String? error;

  ApiClient get api => AppScope.of(context).api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final results = await api.get('/devices/') as List;
      final devices = results.map((item) => Device.fromJson(item as Map<String, dynamic>));
      if (!mounted) return;
      setState(() {
        device = devices.where((item) => item.unitId == widget.unitId).firstOrNull;
        loaded = true;
        error = null;
      });
    } on ApiException catch (exception) {
      if (mounted) setState(() => error = exception.message);
    }
  }

  Future<void> _link() async {
    final linked = await showLinkDeviceSheet(context, api, unitId: widget.unitId);
    if (linked == null || !mounted) return;
    showMessage(context, 'Sensor ${linked.code} vinculado.');
    await _load();
  }

  Future<void> _check(Device target) async {
    try {
      final result = await api.post('/devices/${target.id}/reconnect') as Map<String, dynamic>;
      if (!mounted) return;
      if (result['status'] == 'online') {
        showMessage(context, 'A estufa está respondendo.');
      } else {
        showMessage(context, 'Sem resposta. Veja se a caixa da estufa está ligada e se o Wi-Fi de casa funciona.', error: true);
      }
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _unlink(Device target) async {
    final confirmed = await confirmAction(
      context,
      title: 'Desvincular ${target.code}?',
      message: 'O histórico continua salvo. A estufa deixa de receber leituras deste sensor.',
      confirmLabel: 'Desvincular',
      danger: true,
    );
    if (!confirmed) return;
    try {
      await api.delete('/devices/${target.id}');
      if (!mounted) return;
      showMessage(context, 'Sensor desvinculado.');
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Equipamento')),
      body: error != null
          ? ErrorView(title: 'Não foi possível carregar o equipamento', message: error!, onRetry: _load)
          : !loaded
              ? const LoadingView()
              : ListView(padding: listPadding(context, top: 4), children: [_card()]),
    );
  }

  Widget _card() {
    final current = device;
    if (current == null) {
      return SectionCard(
        title: 'Sensor',
        icon: Icons.sensors,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Nenhum sensor nesta estufa.', style: TextStyle(color: context.colors.textSecondary)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(onPressed: _link, icon: const Icon(Icons.link), label: const Text('Vincular sensor')),
            ),
          ],
        ),
      );
    }
    return SectionCard(
      title: 'Sensor',
      icon: Icons.sensors,
      trailing: current.online
          ? const StatusBadge(kind: StatusKind.ok, label: 'Respondendo')
          : const StatusBadge(kind: StatusKind.offline, label: 'Sem notícias', icon: Icons.cloud_off),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailGrid(items: [
            DetailItem(label: 'Último contato', value: f.relative(current.lastSeen)),
            DetailItem(label: 'Sinal', value: current.signalQuality),
            if (current.battery != null) DetailItem(label: 'Bateria', value: '${current.battery}%${current.batteryLow ? ' (baixa)' : ''}'),
          ]),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: const Text('Detalhes técnicos', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              children: [
                DetailGrid(items: [
                  DetailItem(label: 'ID', value: current.code),
                  if (current.rssi != null) DetailItem(label: 'RSSI', value: '${current.rssi} dBm'),
                  if (current.snr != null) DetailItem(label: 'SNR', value: f.number(current.snr)),
                  DetailItem(label: 'Firmware', value: current.firmwareVersion ?? '--'),
                  if (current.macAddress != null) DetailItem(label: 'MAC', value: current.macAddress!),
                ]),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              BusyButton(label: 'Verificar', icon: Icons.refresh, style: BusyButtonStyle.outlined, onPressed: () => _check(current)),
              TextButton.icon(
                onPressed: () => _unlink(current),
                style: TextButton.styleFrom(foregroundColor: context.colors.crit),
                icon: const Icon(Icons.link_off),
                label: const Text('Desvincular'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
