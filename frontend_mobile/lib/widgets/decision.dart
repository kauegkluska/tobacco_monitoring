import 'package:flutter/material.dart';

import '../core/format.dart' as f;
import '../core/models.dart';
import 'common.dart';
import 'unit_widgets.dart';

/// A resposta do app para "preciso ir lá?": a frase do topo e o selo da lista de estufas.
class Decision {
  const Decision({required this.rank, required this.kind, required this.icon, required this.short, required this.title, this.text});

  /// Menor é mais urgente; ordena a lista de estufas.
  final int rank;
  final StatusKind kind;
  final IconData icon;

  /// Selo da lista.
  final String short;

  /// Frase do topo da estufa.
  final String title;
  final String? text;
}

/// Decide a frase da estufa, da situação mais urgente para a mais tranquila.
///
/// A conexão vem primeiro: sem dado novo, "Tudo certo" seria uma promessa falsa.
Decision decide({
  required CuringUnit unit,
  required Device? device,
  required Reading? latest,
  required bool connected,
  int warnings = 0,
  int criticals = 0,
  bool sensorDoubt = false,
  String? message,
}) {
  if (!connected) {
    return const Decision(
      rank: 0,
      kind: StatusKind.offline,
      icon: Icons.cloud_off,
      short: 'Sem conexão',
      title: 'Sem conexão com o monitor',
      text: 'Os números abaixo podem estar velhos. Confira a internet do celular.',
    );
  }
  if (device == null) {
    return const Decision(
      rank: 8,
      kind: StatusKind.neutral,
      icon: Icons.link_off,
      short: 'Sem sensor',
      title: 'Nenhum sensor nesta estufa',
      text: 'Vincule o sensor para começar a acompanhar.',
    );
  }
  if (!unit.isDrying) {
    return unit.isFinished
        ? const Decision(rank: 9, kind: StatusKind.ok, icon: Icons.check_circle, short: 'Finalizada', title: 'Cura finalizada')
        : const Decision(
            rank: 9,
            kind: StatusKind.neutral,
            icon: Icons.pause,
            short: 'Parada',
            title: 'Secagem parada',
            text: 'O app não está acompanhando a estufa nem enviando avisos.',
          );
  }
  if (latest != null && isStale(latest, unit, device) || (latest == null && !device.online)) {
    final since = f.relative(latest?.timestamp ?? device.lastSeen);
    return Decision(
      rank: 1,
      kind: StatusKind.offline,
      icon: Icons.cloud_off,
      short: 'Sem notícias',
      title: 'Sem notícias da estufa ${since == 'nunca' ? 'ainda' : since}',
      text: 'Veja se a caixa da estufa está ligada e se o Wi-Fi de casa funciona.',
    );
  }
  if (criticals > 0) {
    return Decision(rank: 2, kind: StatusKind.crit, icon: Icons.error, short: 'Vá à estufa', title: 'Vá à estufa agora', text: message);
  }
  if (sensorDoubt) {
    return Decision(rank: 3, kind: StatusKind.warn, icon: Icons.help_outline, short: 'Leitura duvidosa', title: 'A leitura pode estar errada', text: message);
  }
  if (warnings > 0) {
    return Decision(rank: 4, kind: StatusKind.warn, icon: Icons.warning_amber_rounded, short: 'Fique de olho', title: 'Fique de olho', text: message);
  }
  if (latest == null) {
    return const Decision(rank: 7, kind: StatusKind.neutral, icon: Icons.schedule, short: 'Aguardando', title: 'Aguardando a primeira leitura');
  }
  final limits = unit.limitsWith(device);
  final outside = rangeState(latest.temperature, limits.tempMin, limits.tempMax) != 'ok' ||
      rangeState(latest.humidity, limits.humidityMin, limits.humidityMax) != 'ok';
  if (outside) {
    return const Decision(
      rank: 5,
      kind: StatusKind.warn,
      icon: Icons.swap_vert,
      short: 'Fora do esperado',
      title: 'Fique de olho',
      text: 'A temperatura ou a umidade saiu do esperado para a fase.',
    );
  }
  final phase = unit.phase;
  if (phase != null && phase.ready) {
    return Decision(
      rank: 6,
      kind: StatusKind.ok,
      icon: Icons.skip_next,
      short: 'Pode avançar',
      title: phase.finishes ? 'Já dá para finalizar a cura' : 'Já dá para passar de fase',
      text: 'Olhe as folhas: ${phase.visualCheck}',
    );
  }
  return const Decision(rank: 7, kind: StatusKind.ok, icon: Icons.check, short: 'Tudo certo', title: 'Tudo certo');
}

/// O alerta que vira a frase do topo: o mais grave, sem contar os informativos.
AlertItem? featuredAlert(List<AlertItem> alerts) {
  int weight(AlertItem alert) => alert.isCritical ? 0 : (alert.isSensor ? 1 : 2);
  final candidates = alerts.where((alert) => !alert.isInfo).toList()..sort((a, b) => weight(a).compareTo(weight(b)));
  return candidates.firstOrNull;
}

/// O que significa cada situação, aberto ao tocar nela.
Future<void> showStatusLegend(BuildContext context) {
  const items = [
    (StatusKind.crit, 'Vá à estufa', Icons.error, 'Risco para a cura. Aja agora.'),
    (StatusKind.warn, 'Fique de olho', Icons.warning_amber_rounded, 'Há um alerta aberto. Acompanhe a estufa.'),
    (StatusKind.warn, 'Leitura duvidosa', Icons.help_outline, 'O sensor pode estar com problema. Confira no termômetro da estufa.'),
    (StatusKind.warn, 'Fora do esperado', Icons.swap_vert, 'Algum valor saiu do esperado, ainda sem alerta.'),
    (StatusKind.offline, 'Sem notícias', Icons.cloud_off, 'A estufa parou de mandar leituras.'),
    (StatusKind.offline, 'Sem conexão', Icons.cloud_off, 'O celular não consegue falar com o monitor.'),
    (StatusKind.ok, 'Pode avançar', Icons.skip_next, 'Tempo e temperatura atingidos. Olhe as folhas.'),
    (StatusKind.ok, 'Tudo certo', Icons.check, 'Dentro do esperado para a fase, com leitura recente.'),
    (StatusKind.ok, 'Finalizada', Icons.check_circle, 'Cura concluída.'),
    (StatusKind.neutral, 'Aguardando', Icons.schedule, 'Secagem ligada, esperando a primeira leitura.'),
    (StatusKind.neutral, 'Parada', Icons.pause, 'Secagem desligada: nada é gravado e não há avisos.'),
    (StatusKind.neutral, 'Sem sensor', Icons.link_off, 'Falta vincular o sensor a esta estufa.'),
  ];
  return showFormSheet<void>(
    context,
    title: 'O que significa cada situação',
    builder: (_) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (kind, label, icon, text) in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 150, child: Align(alignment: Alignment.centerLeft, child: StatusBadge(kind: kind, label: label, icon: icon))),
                const SizedBox(width: 8),
                Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
              ],
            ),
          ),
      ],
    ),
  );
}
