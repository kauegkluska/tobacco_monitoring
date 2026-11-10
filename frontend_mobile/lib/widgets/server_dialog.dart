import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/discovery.dart';
import '../core/theme.dart';
import 'common.dart';

/// Configuração avançada do endereço do monitor; o app já vem com o servidor certo.
/// Devolve o endereço salvo, ou nulo se o usuário cancelar.
Future<String?> showServerDialog(BuildContext context, ApiClient api, {bool searchOnOpen = false}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ServerDialog(api: api, searchOnOpen: searchOnOpen),
  );
}

class _ServerDialog extends StatefulWidget {
  const _ServerDialog({required this.api, required this.searchOnOpen});

  final ApiClient api;
  final bool searchOnOpen;

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final controller = TextEditingController(text: widget.api.baseUrl);
  List<DiscoveredServer>? servers;
  bool searching = false;
  String? error;

  @override
  void initState() {
    super.initState();
    if (widget.searchOnOpen && discoverySupported) WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      searching = true;
      error = null;
    });
    final found = await discoverServers();
    if (!mounted) return;
    setState(() {
      searching = false;
      servers = found;
    });
  }

  Future<void> _save(String url) async {
    final ok = await widget.api.testConnection(url);
    if (!mounted) return;
    if (!ok) {
      setState(() => error = 'Não houve resposta de $url. Confira o endereço.');
      return;
    }
    await widget.api.setBaseUrl(url);
    if (mounted) Navigator.pop(context, widget.api.baseUrl);
  }

  @override
  Widget build(BuildContext context) {
    final found = servers;
    return AlertDialog(
      title: const Text('Endereço do monitor'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormErrorText(error),
          if (discoverySupported) ...[
            Text(
              'Só mude isto se o responsável pelo sistema pedir.',
              style: TextStyle(color: context.colors.textSecondary),
            ),
            const SizedBox(height: 12),
            if (searching)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 12),
                    Expanded(child: Text('Procurando no Wi-Fi… (até 15 s)')),
                  ],
                ),
              )
            else
              OutlinedButton.icon(
                onPressed: _search,
                icon: const Icon(Icons.wifi_find),
                label: Text(found == null ? 'Procurar no Wi-Fi' : 'Procurar de novo'),
              ),
            if (found != null && !searching) ...[
              const SizedBox(height: 8),
              if (found.isEmpty)
                Text(
                  'Nenhum monitor encontrado neste Wi-Fi.',
                  style: TextStyle(fontSize: 13, color: context.colors.warn),
                )
              else
                for (final server in found)
                  Card(
                    margin: const EdgeInsets.only(top: 6),
                    child: ListTile(
                      leading: Icon(Icons.dns, color: context.scheme.primary),
                      title: Text(server.name),
                      subtitle: Text(server.host),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _save(server.baseUrl),
                    ),
                  ),
            ],
            const Divider(height: 28),
            Text('Ou digite o endereço', style: TextStyle(fontWeight: FontWeight.w600, color: context.colors.textSecondary)),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Endereço', hintText: 'http://192.168.0.14:8000'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        BusyButton(label: 'Testar e salvar', onPressed: () => _save(controller.text)),
      ],
    );
  }
}
