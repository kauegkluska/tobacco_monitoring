import 'package:flutter/material.dart';

import 'alerts_page.dart';
import 'cycles_page.dart';

/// Tudo o que já passou: as secagens e os alertas encerrados.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool cycles = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Secagens')),
              ButtonSegment(value: false, label: Text('Alertas')),
            ],
            selected: {cycles},
            showSelectedIcon: false,
            onSelectionChanged: (value) => setState(() => cycles = value.first),
          ),
        ),
        Expanded(child: cycles ? const CyclesPage() : const AlertsPage()),
      ],
    );
  }
}
