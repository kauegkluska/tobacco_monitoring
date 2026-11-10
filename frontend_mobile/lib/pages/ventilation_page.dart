import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_scope.dart';
import '../core/buzzer.dart';
import '../core/format.dart' as f;
import '../core/models.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

/// Comando do flap e da ventoinha, separado do acompanhamento do dia a dia.
class VentilationPage extends StatefulWidget {
  const VentilationPage({required this.unitId, this.phase, super.key});

  final int unitId;
  final PhaseStatus? phase;

  @override
  State<VentilationPage> createState() => _VentilationPageState();
}

class _VentilationPageState extends State<VentilationPage> {
  static const _pollInterval = Duration(seconds: 5);

  Outputs? outputs;
  String? error;
  Timer? timer;

  ApiClient get api => AppScope.of(context).api;
  AppPrefs get prefs => AppScope.of(context).prefs;
  String get _base => '/curing_units/${widget.unitId}';

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
      final result = await api.get('$_base/outputs?events=5');
      if (!mounted) return;
      setState(() {
        outputs = Outputs.fromJson(result as Map<String, dynamic>);
        error = null;
      });
    } on ApiException catch (exception) {
      if (mounted && outputs == null) setState(() => error = exception.message);
    } finally {
      if (mounted) timer = Timer(_pollInterval, _load);
    }
  }

  Future<void> _setMode(String output, String mode) async {
    final name = (output == 'temperature' ? outputs?.temperature : outputs?.humidity)?.name ?? 'Saída';
    if (mode != 'auto') {
      final on = mode == 'on';
      final confirmed = await confirmAction(
        context,
        title: on ? 'Ligar $name?' : 'Desligar $name?',
        message: on
            ? 'Fica ligada até você voltar para o Automático. A caixa da estufa apita por 2 s.'
            : 'Fica desligada até você voltar para o Automático, mesmo que a temperatura ou a umidade saia do esperado.',
        confirmLabel: on ? 'Ligar' : 'Desligar',
        danger: !on,
      );
      if (!confirmed) return;
    }
    try {
      final result = await api.patch('$_base/outputs', {'${output}_mode': mode});
      if (!mounted) return;
      setState(() => outputs = Outputs.fromJson(result as Map<String, dynamic>));
      showMessage(context, switch (mode) {
        'on' => '$name ligada.',
        'off' => '$name desligada.',
        _ => '$name no automático.',
      });
    } on ApiException catch (exception) {
      if (mounted) showMessage(context, exception.message, error: true);
    }
  }

  Future<void> _edit(String output, OutputState state) async {
    final name = TextEditingController(text: state.name);
    var trigger = state.trigger;
    String? sheetError;
    await showFormSheet<void>(
      context,
      title: 'Editar ${state.name}',
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormErrorText(sheetError),
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 40,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Flap, Ventoinha'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: trigger,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'No automático, liga com'),
              items: [for (final entry in outputTriggers.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
              onChanged: (value) => setSheetState(() => trigger = value ?? trigger),
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: 'Salvar',
              onPressed: () async {
                final newName = name.text.trim();
                if (newName.isEmpty) {
                  setSheetState(() => sheetError = 'Informe o nome.');
                  return;
                }
                try {
                  final result = await api.patch('$_base/outputs', {'${output}_name': newName, '${output}_trigger': trigger});
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (mounted) setState(() => outputs = Outputs.fromJson(result as Map<String, dynamic>));
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
  }

  /// Temperatura alvo da ventoinha, digitada na unidade escolhida e enviada em °C.
  Future<void> _editTarget() async {
    final unitPref = prefs.unit;
    final symbol = f.unitSymbol(unitPref);
    final current = outputs?.targetTemperature;
    final controller = TextEditingController(text: current == null ? '' : f.number(f.tempValue(current, unitPref), 0));
    final phase = widget.phase;
    String? sheetError;
    await showFormSheet<void>(
      context,
      title: 'Temperatura alvo',
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FormErrorText(sheetError),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Alvo',
                suffixText: symbol,
                helperText: phase == null
                    ? 'A ventoinha liga abaixo do alvo e desliga ao atingi-lo.'
                    : 'Esperado na fase: ${f.tempRange(phase.limits.tempMin, phase.limits.tempMax, unitPref)}',
              ),
            ),
            const SizedBox(height: 20),
            BusyButton(
              label: 'Salvar',
              onPressed: () async {
                final typed = double.tryParse(controller.text.trim().replaceAll(',', '.'));
                final celsius = typed == null ? null : f.tempToCelsius(typed, unitPref);
                if (celsius == null || celsius < 20 || celsius > 90) {
                  setSheetState(() => sheetError = 'Informe um valor entre ${f.tempRange(20, 90, unitPref)}.');
                  return;
                }
                try {
                  final result = await api.patch('$_base/outputs', {'target_temperature': double.parse(celsius.toStringAsFixed(2))});
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (!mounted) return;
                  setState(() => outputs = Outputs.fromJson(result as Map<String, dynamic>));
                  showMessage(context, 'Alvo: ${f.temp(celsius, unitPref, digits: 0)}.');
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
  }

  @override
  Widget build(BuildContext context) {
    final data = outputs;
    return Scaffold(
      appBar: AppBar(title: const Text('Ventilação')),
      body: error != null
          ? ErrorView(title: 'Não foi possível carregar a ventilação', message: error!, onRetry: _load)
          : data == null
              ? const LoadingView()
              : ListenableBuilder(listenable: prefs, builder: (context, _) => _body(data)),
    );
  }

  Widget _body(Outputs data) {
    final last = data.lastBuzzer;
    Widget row(String output, OutputState state) => SectionCard(
          child: _OutputRow(
            state: state,
            confirmedAt: data.confirmedAt,
            target: data.targetTemperature,
            unit: prefs.unit,
            onMode: (mode) => _setMode(output, mode),
            onEdit: () => _edit(output, state),
            onEditTarget: _editTarget,
          ),
        );

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            row('humidity', data.humidity),
            const SizedBox(height: 12),
            row('temperature', data.temperature),
            if (last != null) ...[
              const SizedBox(height: 14),
              Row(children: [
                Icon(Icons.volume_up_outlined, size: 18, color: context.colors.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Último apito ${f.relative(last.timestamp)}: ${describeOutputEvent(last, prefs.unit)}',
                    style: TextStyle(fontSize: 13, color: context.colors.textSecondary),
                  ),
                ),
              ]),
            ],
            if (data.events.isNotEmpty) ...[
              const SizedBox(height: 8),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('Últimas mudanças', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  children: [
                    for (final event in data.events)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(event.turnedOn ? Icons.power : Icons.power_off, color: event.turnedOn ? context.scheme.primary : context.colors.muted),
                        title: Text(describeOutputEvent(event, prefs.unit)),
                        trailing: Text(f.relative(event.timestamp), style: TextStyle(color: context.colors.muted, fontSize: 12.5)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  const _OutputRow({
    required this.state,
    required this.confirmedAt,
    required this.target,
    required this.unit,
    required this.onMode,
    required this.onEdit,
    required this.onEditTarget,
  });

  final OutputState state;
  final DateTime? confirmedAt;

  /// Temperatura alvo em °C; só aparece quando a saída segue o alvo.
  final double? target;
  final TempUnit unit;
  final ValueChanged<String> onMode;
  final VoidCallback onEdit;
  final VoidCallback onEditTarget;

  @override
  Widget build(BuildContext context) {
    final (IconData syncIcon, Color syncColor, String syncText) = switch (state) {
      OutputState(inSync: true) => (Icons.verified, context.colors.ok, 'Confirmado pela estufa'),
      OutputState(confirmedOn: null) => (Icons.hourglass_empty, context.colors.muted, 'Ainda sem confirmação da estufa'),
      OutputState(:final confirmedOn) when confirmedOn == state.on => (
          Icons.history,
          context.colors.muted,
          'Confirmado ${f.relative(confirmedAt)}',
        ),
      _ => (Icons.sync, context.colors.warn, 'Aguardando a estufa aplicar'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(state.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5), overflow: TextOverflow.ellipsis),
                  Text(state.reason, style: TextStyle(fontSize: 13, color: context.colors.textSecondary)),
                ],
              ),
            ),
            StatusBadge(
              kind: state.on ? StatusKind.info : StatusKind.neutral,
              label: state.on ? 'Ligada' : 'Desligada',
              icon: state.on ? Icons.power : Icons.power_off,
            ),
            IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_outlined), tooltip: 'Editar nome e regra', visualDensity: VisualDensity.compact),
          ],
        ),
        const SizedBox(height: 4),
        Row(children: [
          Icon(syncIcon, size: 15, color: syncColor),
          const SizedBox(width: 6),
          Expanded(child: Text(syncText, style: TextStyle(fontSize: 12.5, color: syncColor))),
        ]),
        if (state.followsTarget) ...[
          const SizedBox(height: 10),
          _TargetRow(target: target, unit: unit, onEdit: onEditTarget),
        ],
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'auto', label: Text('Automático')),
            ButtonSegment(value: 'on', label: Text('Ligada')),
            ButtonSegment(value: 'off', label: Text('Desligada')),
          ],
          selected: {state.mode},
          showSelectedIcon: false,
          onSelectionChanged: (value) {
            if (value.first != state.mode) onMode(value.first);
          },
        ),
      ],
    );
  }
}

/// Temperatura alvo da ventoinha: o valor e o botão para mudar, ou o aviso para definir.
class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.target, required this.unit, required this.onEdit});

  final double? target;
  final TempUnit unit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final missing = target == null;
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(color: missing ? c.warnContainer : c.surface2, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(Icons.thermostat, size: 20, color: missing ? c.warn : context.scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: missing
                ? Text('Defina a temperatura alvo', style: TextStyle(fontWeight: FontWeight.w600, color: c.onWarnContainer))
                : Text.rich(TextSpan(children: [
                    TextSpan(text: 'Alvo  ', style: TextStyle(color: c.textSecondary)),
                    TextSpan(text: f.temp(target, unit), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  ])),
          ),
          TextButton(onPressed: onEdit, child: Text(missing ? 'Definir' : 'Alterar')),
        ],
      ),
    );
  }
}
