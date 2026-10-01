import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';
import 'qr_scanner_page.dart';
import 'shell.dart';

/// Estufas e dispositivos: cadastro, vínculo do sensor ESP32, limites e desvínculo.
class UnitsPage extends StatefulWidget {
  const UnitsPage({required this.actions, this.intent, super.key});

  final ShellActions actions;
  final UnitsIntent? intent;

  @override
  State<UnitsPage> createState() => _UnitsPageState();
}

class _UnitsPageState extends State<UnitsPage> {
  static const _pollInterval = Duration(seconds: 10);

  Overview? data;
  String? error;
  Timer? timer;
  bool intentHandled = false;

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
      if (!intentHandled) {
        intentHandled = true;
        final intent = widget.intent;
        if (intent?.createUnit == true) {
          _createUnit();
        } else if (intent != null) {
          _linkDevice(unitId: intent.linkUnitId);
        }
      }
    } on ApiException catch (exception) {
      if (mounted && data == null) setState(() => error = exception.message);
    } finally {
      if (mounted) timer = Timer(_pollInterval, _load);
    }
  }

  Future<T?> _sheet<T>({required String title, required Widget Function(BuildContext) builder}) {
    return showFormSheet<T>(context, title: title, builder: builder);
  }

  // ---------------------------------------------------------------------------
  // Estufas

  Future<void> _createUnit() => _unitForm(null);

  Future<void> _unitForm(CuringUnit? unit) async {
    final count = data?.units.length ?? 0;
    final name = TextEditingController(text: unit?.name ?? 'Estufa ${(count + 1).toString().padLeft(2, '0')}');
    final hours = TextEditingController(text: unit?.estimatedHours?.round().toString() ?? '');
    var stage = unit?.stage ?? curingStages.first;
    final stages = curingStages.contains(stage) ? curingStages : [stage, ...curingStages];
    String? sheetError;
    CuringUnit? created;

    await _sheet<void>(
      title: unit == null ? 'Nova estufa' : 'Editar ${unit.name}',
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormErrorText(sheetError),
            TextField(controller: name, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Nome da estufa')),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: stage,
              decoration: const InputDecoration(labelText: 'Fase da cura'),
              items: [for (final item in stages) DropdownMenuItem(value: item, child: Text(item))],
              onChanged: (value) => stage = value ?? stage,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: hours,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Duração prevista (opcional)',
                suffixText: 'horas',
                helperText: 'Usada para calcular o término previsto da secagem.',
              ),
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: unit == null ? 'Cadastrar' : 'Salvar',
              onPressed: () async {
                if (name.text.trim().isEmpty) {
                  setSheetState(() => sheetError = 'Informe o nome da estufa.');
                  return;
                }
                final payload = <String, dynamic>{'name': name.text.trim(), 'curing_stage': stage};
                final parsedHours = double.tryParse(hours.text.replaceAll(',', '.'));
                if (parsedHours != null && parsedHours > 0) payload['estimated_duration_hours'] = parsedHours;
                try {
                  if (unit == null) {
                    created = CuringUnit.fromJson(await api.post('/curing_units/', payload) as Map<String, dynamic>);
                    await prefs.setUnitId(created!.id);
                  } else {
                    await api.patch('/curing_units/${unit.id}', payload);
                  }
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                } on ApiException catch (exception) {
                  setSheetState(() => sheetError = exception.message);
                }
              },
            ),
          ],
        ),
      ),
    );
    name.dispose();
    hours.dispose();
    if (!mounted) return;
    if (created != null) {
      showMessage(context, '${created!.name} cadastrada. Agora vincule o sensor.');
      await _load();
      if (mounted) await _linkDevice(unitId: created!.id);
    } else if (unit != null) {
      await _load();
    }
  }

  Future<void> _deleteUnit(CuringUnit unit) async {
    final confirmed = await confirmAction(
      context,
      title: 'Excluir ${unit.name}?',
      message: 'Só é possível excluir estufas sem histórico de leituras. Esta ação não pode ser desfeita.',
      confirmLabel: 'Excluir',
      danger: true,
    );
    if (!confirmed) return;
    try {
      await api.delete('/curing_units/${unit.id}');
      if (!mounted) return;
      showMessage(context, 'Estufa excluída.');
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Dispositivos

  bool get _canScan => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _linkDevice({int? unitId, ScannedDevice? scanned}) async {
    final units = data?.units ?? const <CuringUnit>[];
    final code = TextEditingController(text: scanned?.code ?? '');
    final mac = TextEditingController(text: scanned?.mac ?? '');
    int? selectedUnit = unitId ?? (units.length == 1 ? units.first.id : null);
    String? rawQr = scanned?.raw;
    String? sheetError;
    Device? linked;

    await _sheet<void>(
      title: 'Vincular dispositivo ESP32',
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'O ID do controlador é o CONTROLLER_ID gravado no sender. Ele aparece no display ao ligar e no monitor serial.',
              style: TextStyle(color: sheetContext.colors.textSecondary),
            ),
            const SizedBox(height: 14),
            if (_canScan) ...[
              OutlinedButton.icon(
                onPressed: () async {
                  final result = await Navigator.push<ScannedDevice>(sheetContext, MaterialPageRoute(builder: (_) => const QrScannerPage()));
                  if (result == null) return;
                  setSheetState(() {
                    rawQr = result.raw;
                    if (result.code != null) code.text = result.code!;
                    if (result.mac != null) mac.text = result.mac!;
                    sheetError = result.code == null && result.mac == null ? 'O QR code lido não tem um ID de controlador reconhecido.' : null;
                  });
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Ler QR code do sensor'),
              ),
              const SizedBox(height: 14),
            ],
            FormErrorText(sheetError),
            TextField(
              controller: code,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'ID do controlador', hintText: 'ESP32-TOBACCO-01'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: mac,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Endereço MAC (opcional)', helperText: 'Só é necessário se você não souber o ID.'),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int?>(
              initialValue: selectedUnit,
              decoration: const InputDecoration(labelText: 'Estufa que vai receber as leituras'),
              items: [
                const DropdownMenuItem<int?>(value: null, child: Text('Nenhuma por enquanto')),
                for (final unit in units) DropdownMenuItem<int?>(value: unit.id, child: Text(unit.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (value) => selectedUnit = value,
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: 'Vincular',
              icon: Icons.link,
              onPressed: () async {
                if (code.text.trim().isEmpty && mac.text.trim().isEmpty) {
                  setSheetState(() => sheetError = 'Informe o ID do controlador ou o endereço MAC.');
                  return;
                }
                final payload = <String, dynamic>{
                  'controller_id': code.text.trim().isEmpty ? null : code.text.trim(),
                  'mac_address': mac.text.trim().isEmpty ? null : mac.text.trim(),
                  if (selectedUnit != null) 'curing_unit_id': selectedUnit,
                  if (rawQr != null) 'raw_qr': rawQr,
                };
                try {
                  linked = Device.fromJson(await api.post('/devices/link', payload) as Map<String, dynamic>);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                } on ApiException catch (exception) {
                  setSheetState(() => sheetError = exception.message);
                }
              },
            ),
          ],
        ),
      ),
    );
    code.dispose();
    mac.dispose();
    if (!mounted || linked == null) return;
    showMessage(context, '${linked!.code} vinculado${linked!.unitName != null ? ' à ${linked!.unitName}' : ''}.');
    await _load();
  }

  Future<void> _checkDevice(Device device) async {
    try {
      final result = await api.post('/devices/${device.id}/reconnect') as Map<String, dynamic>;
      if (!mounted) return;
      if (result['status'] == 'online') {
        showMessage(context, '${device.code} está online e enviando leituras.');
      } else {
        showMessage(context, '${device.code} continua sem sinal. Confira a alimentação do sender e o gateway.', error: true);
      }
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _unlinkDevice(Device device) async {
    final confirmed = await confirmAction(
      context,
      title: 'Desvincular ${device.code}?',
      message: 'A estufa e todo o histórico continuam salvos, mas deixam de receber leituras deste sensor. Você pode vinculá-lo de novo depois.',
      confirmLabel: 'Desvincular',
      danger: true,
    );
    if (!confirmed) return;
    try {
      await api.delete('/devices/${device.id}');
      if (!mounted) return;
      showMessage(context, 'Dispositivo desvinculado.');
      await _load();
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorView(title: 'Não foi possível carregar as estufas', message: error!, onRetry: _load);
    final overview = data;
    if (overview == null) return const LoadingView(message: 'Carregando estufas e dispositivos…');

    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const PageHeader(
              eyebrow: 'Cadastro',
              title: 'Estufas e dispositivos',
              subtitle: 'Cada estufa recebe as leituras de um sensor ESP32 (sender). O gateway (receiver) repassa os dados para o servidor.',
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: FilledButton.icon(onPressed: _createUnit, icon: const Icon(Icons.add), label: const Text('Nova estufa'))),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton.icon(onPressed: () => _linkDevice(), icon: const Icon(Icons.link), label: const Text('Vincular'))),
            ]),
            const SizedBox(height: 22),
            Text('Estufas (${overview.units.length})', style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            if (overview.units.isEmpty)
              SectionCard(
                child: EmptyState(
                  icon: Icons.warehouse_outlined,
                  title: 'Nenhuma estufa cadastrada',
                  message: 'Comece cadastrando a estufa que será monitorada.',
                  action: FilledButton.icon(onPressed: _createUnit, icon: const Icon(Icons.add), label: const Text('Nova estufa')),
                ),
              )
            else
              for (final unit in overview.units)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: _unitCard(unit, overview.deviceFor(unit))),
            const SizedBox(height: 10),
            Text('Dispositivos (${overview.devices.length})', style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            if (overview.devices.isEmpty)
              SectionCard(
                child: EmptyState(
                  icon: Icons.sensors,
                  title: 'Nenhum dispositivo vinculado',
                  message: 'Leia o QR code do sender ou digite o ID do controlador (ex.: ESP32-TOBACCO-01).',
                  action: FilledButton.icon(onPressed: () => _linkDevice(), icon: const Icon(Icons.link), label: const Text('Vincular sensor')),
                ),
              )
            else
              for (final device in overview.devices)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: _deviceCard(device)),
          ],
        ),
      ),
    );
  }

  Widget _unitCard(CuringUnit unit, Device? device) {
    final sensorStatus = device == null
        ? '--'
        : device.online
            ? 'Online'
            : device.lastSeen == null
                ? 'Aguardando primeira leitura'
                : 'Offline (${f.relative(device.lastSeen)})';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _EntityHeader(
              icon: Icons.warehouse,
              title: unit.name,
              subtitle: unit.stage,
              badge: unit.isDrying
                  ? const StatusBadge(kind: StatusKind.ok, label: 'Secando')
                  : const StatusBadge(kind: StatusKind.neutral, label: 'Parada', icon: Icons.stop),
            ),
            const SizedBox(height: 14),
            DetailGrid(items: [
              DetailItem(label: 'Sensor', value: device?.code ?? 'Nenhum'),
              DetailItem(label: 'Situação do sensor', value: sensorStatus),
              DetailItem(label: 'Duração prevista', value: unit.estimatedHours == null ? 'Não definida' : f.duration(unit.estimatedHours)),
              DetailItem(label: 'Secagem iniciada', value: f.dateTime(unit.dryingStartedAt)),
            ]),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () {
                    prefs.setUnitId(unit.id);
                    widget.actions.goTo(AppTab.dashboard);
                  },
                  icon: const Icon(Icons.space_dashboard_outlined),
                  label: const Text('Painel'),
                ),
                if (device == null) FilledButton.icon(onPressed: () => _linkDevice(unitId: unit.id), icon: const Icon(Icons.link), label: const Text('Vincular')),
                OutlinedButton.icon(onPressed: () => _unitForm(unit), icon: const Icon(Icons.edit_outlined), label: const Text('Editar')),
                IconButton(
                  tooltip: 'Excluir ${unit.name}',
                  color: context.colors.crit,
                  onPressed: () => _deleteUnit(unit),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(Device device) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _EntityHeader(
              icon: Icons.sensors,
              title: device.code,
              subtitle: device.unitName == null ? 'Sem estufa vinculada' : 'Estufa: ${device.unitName}',
              badge: device.online
                  ? const StatusBadge(kind: StatusKind.ok, label: 'Online')
                  : const StatusBadge(kind: StatusKind.offline, label: 'Offline', icon: Icons.cloud_off),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _Metric(icon: Icons.signal_cellular_alt, label: 'Sinal LoRa', value: device.rssi == null ? '--' : '${device.rssi} dBm', sub: device.signalQuality)),
              const SizedBox(width: 8),
              Expanded(
                child: _Metric(
                  icon: device.batteryLow ? Icons.battery_alert : Icons.battery_std,
                  label: 'Bateria',
                  value: device.battery == null ? '--' : '${device.battery}%',
                  sub: device.battery == null ? 'Não informada' : (device.batteryLow ? 'Baixa' : 'Normal'),
                  alert: device.batteryLow,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _Metric(icon: Icons.schedule, label: 'Contato', value: f.relative(device.lastSeen), sub: device.lastSeen == null ? 'Nunca enviou' : f.time(device.lastSeen))),
            ]),
            const SizedBox(height: 14),
            DetailGrid(items: [
              DetailItem(label: 'Endereço MAC', value: device.macAddress ?? 'Não informado'),
              DetailItem(label: 'Modelo', value: device.hardwareModel ?? '--'),
            ]),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                BusyButton(label: 'Verificar', icon: Icons.refresh, style: BusyButtonStyle.outlined, onPressed: () => _checkDevice(device)),
                IconButton(
                  tooltip: 'Desvincular ${device.code}',
                  color: context.colors.crit,
                  onPressed: () => _unlinkDevice(device),
                  icon: const Icon(Icons.link_off),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EntityHeader extends StatelessWidget {
  const _EntityHeader({required this.icon, required this.title, required this.subtitle, required this.badge});

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget badge;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: context.colors.surface2, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: context.scheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              Text(subtitle, style: TextStyle(fontSize: 13, color: context.colors.muted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        badge,
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value, required this.sub, this.alert = false});

  final IconData icon;
  final String label;
  final String value;
  final String sub;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: context.colors.surface2, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: alert ? context.colors.crit : context.colors.muted),
            const SizedBox(width: 4),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: context.colors.muted))),
          ]),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Text(sub, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: context.colors.muted)),
        ],
      ),
    );
  }
}
