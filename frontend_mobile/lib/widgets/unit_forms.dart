import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../pages/qr_scanner_page.dart';
import 'common.dart';

/// Cadastra ([unit] nulo) ou renomeia uma estufa. Devolve a estufa salva.
Future<CuringUnit?> showUnitForm(BuildContext context, ApiClient api, {CuringUnit? unit, int count = 0}) async {
  final name = TextEditingController(text: unit?.name ?? 'Estufa ${(count + 1).toString().padLeft(2, '0')}');
  String? sheetError;
  CuringUnit? saved;

  await showFormSheet<void>(
    context,
    title: unit == null ? 'Nova estufa' : 'Renomear estufa',
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormErrorText(sheetError),
          TextField(
            controller: name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Nome'),
          ),
          const SizedBox(height: 20),
          BusyButton(
            label: unit == null ? 'Cadastrar' : 'Salvar',
            onPressed: () async {
              if (name.text.trim().isEmpty) {
                setSheetState(() => sheetError = 'Informe o nome.');
                return;
              }
              final payload = {'name': name.text.trim()};
              try {
                final result = unit == null ? await api.post('/curing_units/', payload) : await api.patch('/curing_units/${unit.id}', payload);
                saved = CuringUnit.fromJson(result as Map<String, dynamic>);
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
  return saved;
}

/// Duração total prevista da secagem, usada na previsão de término.
Future<bool> showDurationForm(BuildContext context, ApiClient api, CuringUnit unit) async {
  final controller = TextEditingController(text: unit.estimatedHours?.round().toString() ?? '');
  String? sheetError;
  var saved = false;
  await showFormSheet<void>(
    context,
    title: 'Duração prevista',
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormErrorText(sheetError),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Duração total', suffixText: 'horas', helperText: 'Uma cura leva de 84 a 168 h.'),
          ),
          const SizedBox(height: 20),
          BusyButton(
            label: 'Salvar',
            onPressed: () async {
              final hours = double.tryParse(controller.text.replaceAll(',', '.'));
              if (hours == null || hours <= 0) {
                setSheetState(() => sheetError = 'Informe a duração em horas.');
                return;
              }
              try {
                await api.patch('/curing_units/${unit.id}', {'estimated_duration_hours': hours});
                saved = true;
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
  controller.dispose();
  return saved;
}

bool get _canScan => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// Vincula o sensor (sender) à estufa pelo QR code ou pelo ID digitado.
Future<Device?> showLinkDeviceSheet(BuildContext context, ApiClient api, {required int unitId}) async {
  final code = TextEditingController();
  final mac = TextEditingController();
  String? rawQr;
  String? sheetError;
  Device? linked;

  await showFormSheet<void>(
    context,
    title: 'Vincular sensor',
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_canScan) ...[
            FilledButton.tonalIcon(
              onPressed: () async {
                final result = await Navigator.push<ScannedDevice>(sheetContext, MaterialPageRoute(builder: (_) => const QrScannerPage()));
                if (result == null) return;
                setSheetState(() {
                  rawQr = result.raw;
                  if (result.code != null) code.text = result.code!;
                  if (result.mac != null) mac.text = result.mac!;
                  sheetError = result.code == null && result.mac == null ? 'QR code sem ID de sensor.' : null;
                });
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Ler QR code'),
            ),
            const SizedBox(height: 14),
          ],
          FormErrorText(sheetError),
          TextField(
            controller: code,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'ID do sensor', hintText: 'ESP32-TOBACCO-01'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: mac,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Endereço MAC (opcional)'),
          ),
          const SizedBox(height: 20),
          BusyButton(
            label: 'Vincular',
            icon: Icons.link,
            onPressed: () async {
              if (code.text.trim().isEmpty && mac.text.trim().isEmpty) {
                setSheetState(() => sheetError = 'Informe o ID ou o endereço MAC.');
                return;
              }
              final payload = <String, dynamic>{
                'controller_id': code.text.trim().isEmpty ? null : code.text.trim(),
                'mac_address': mac.text.trim().isEmpty ? null : mac.text.trim(),
                'curing_unit_id': unitId,
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
  return linked;
}
