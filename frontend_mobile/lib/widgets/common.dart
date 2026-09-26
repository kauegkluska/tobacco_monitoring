import 'package:flutter/material.dart';

import '../core/theme.dart';

enum StatusKind { ok, warn, crit, offline, info, neutral }

class _StatusColors {
  const _StatusColors(this.background, this.foreground, this.icon);

  final Color background;
  final Color foreground;
  final Color icon;
}

_StatusColors _statusColors(BuildContext context, StatusKind kind) {
  final c = context.colors;
  return switch (kind) {
    StatusKind.ok => _StatusColors(c.okContainer, c.onOkContainer, c.ok),
    StatusKind.warn => _StatusColors(c.warnContainer, c.onWarnContainer, c.warn),
    StatusKind.crit => _StatusColors(c.critContainer, c.onCritContainer, c.crit),
    StatusKind.offline => _StatusColors(c.offlineContainer, c.onOfflineContainer, c.offline),
    StatusKind.info => _StatusColors(c.infoContainer, c.onInfoContainer, c.onInfoContainer),
    StatusKind.neutral => _StatusColors(c.surface2, c.textSecondary, c.textSecondary),
  };
}

/// Selo de estado: sempre ícone (ou ponto) + texto, nunca só cor.
class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.kind, required this.label, this.icon, super.key});

  final StatusKind kind;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = _statusColors(context, kind);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: colors.background, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 15, color: colors.foreground)
          else
            Container(width: 8, height: 8, decoration: BoxDecoration(color: colors.icon, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.foreground, fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// Faixa com a situação em linguagem simples e, opcionalmente, ações.
class StatusBanner extends StatelessWidget {
  const StatusBanner({required this.kind, required this.icon, required this.title, this.text, this.actions = const [], super.key});

  final StatusKind kind;
  final IconData icon;
  final String title;
  final String? text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = _statusColors(context, kind);
    return Semantics(
      liveRegion: kind == StatusKind.crit,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: colors.background, borderRadius: BorderRadius.circular(16)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colors.icon, size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: colors.foreground, fontWeight: FontWeight.w700, fontSize: 15.5)),
                  if (text != null) ...[
                    const SizedBox(height: 4),
                    Text(text!, style: TextStyle(color: colors.foreground, fontSize: 14, height: 1.35)),
                  ],
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: actions),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cartão com título, ícone e ação opcional à direita.
class SectionCard extends StatelessWidget {
  const SectionCard({required this.child, this.title, this.icon, this.subtitle, this.trailing, this.padding = const EdgeInsets.all(16), super.key});

  final String? title;
  final IconData? icon;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (icon != null) ...[Icon(icon, color: context.scheme.primary, size: 22), const SizedBox(width: 8)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title!, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!, style: context.text.bodySmall?.copyWith(color: context.colors.muted)),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
              const SizedBox(height: 14),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader({required this.eyebrow, required this.title, this.subtitle, this.trailing, super.key});

  final String eyebrow;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow.toUpperCase(),
                style: TextStyle(color: context.scheme.primary, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.1),
              ),
              const SizedBox(height: 2),
              Text(title, style: context.text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: context.text.bodyMedium?.copyWith(color: context.colors.textSecondary)),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.icon, required this.title, this.message, this.action, super.key});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 8),
      child: Column(
        children: [
          Icon(icon, size: 46, color: context.colors.muted),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, textAlign: TextAlign.center, style: TextStyle(color: context.colors.textSecondary)),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({this.message = 'Carregando…', super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(message, style: TextStyle(color: context.colors.muted)),
          ],
        ),
      ),
    );
  }
}

/// Tela de erro de carregamento com botão para tentar de novo.
class ErrorView extends StatelessWidget {
  const ErrorView({required this.title, required this.message, required this.onRetry, super.key});

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        StatusBanner(
          kind: StatusKind.crit,
          icon: Icons.cloud_off,
          title: title,
          text: message,
          actions: [OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Tentar de novo'))],
        ),
      ],
    );
  }
}

/// Par rótulo/valor pequeno usado em listas de detalhes.
class DetailItem extends StatelessWidget {
  const DetailItem({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.colors.muted)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Grade de [DetailItem] em duas colunas.
class DetailGrid extends StatelessWidget {
  const DetailGrid({required this.items, super.key});

  final List<DetailItem> items;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: items[i]),
            const SizedBox(width: 12),
            Expanded(child: i + 1 < items.length ? items[i + 1] : const SizedBox()),
          ],
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

void showMessage(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Row(
      children: [
        Icon(error ? Icons.error_outline : Icons.check_circle_outline, color: error ? const Color(0xffffb4ab) : const Color(0xff88d982)),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ],
    ),
    duration: Duration(seconds: error ? 6 : 3),
  ));
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: const Color(0xffba1a1a)) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Botão que mostra um indicador enquanto a ação assíncrona roda e evita toque duplo.
class BusyButton extends StatefulWidget {
  const BusyButton({required this.label, required this.onPressed, this.icon, this.style = BusyButtonStyle.filled, super.key});

  final String label;
  final IconData? icon;
  final Future<void> Function()? onPressed;
  final BusyButtonStyle style;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

enum BusyButtonStyle { filled, outlined, danger, tonal }

class _BusyButtonState extends State<BusyButton> {
  bool busy = false;

  Future<void> _run() async {
    setState(() => busy = true);
    try {
      await widget.onPressed!();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed == null || busy ? null : _run;
    final iconWidget = busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : (widget.icon != null ? Icon(widget.icon, size: 20) : null);
    final label = Text(busy ? 'Aguarde…' : widget.label);
    final c = context.colors;
    switch (widget.style) {
      case BusyButtonStyle.outlined:
        return iconWidget == null
            ? OutlinedButton(onPressed: onPressed, child: label)
            : OutlinedButton.icon(onPressed: onPressed, icon: iconWidget, label: label);
      case BusyButtonStyle.danger:
      case BusyButtonStyle.tonal:
        final danger = widget.style == BusyButtonStyle.danger;
        final style = FilledButton.styleFrom(
          backgroundColor: danger ? c.critContainer : context.scheme.primaryContainer,
          foregroundColor: danger ? c.onCritContainer : context.scheme.onPrimaryContainer,
        );
        return iconWidget == null
            ? FilledButton(style: style, onPressed: onPressed, child: label)
            : FilledButton.icon(style: style, onPressed: onPressed, icon: iconWidget, label: label);
      case BusyButtonStyle.filled:
        return iconWidget == null
            ? FilledButton(onPressed: onPressed, child: label)
            : FilledButton.icon(onPressed: onPressed, icon: iconWidget, label: label);
    }
  }
}

/// Abre um formulário em painel deslizante que sobe com o teclado.
Future<T?> showFormSheet<T>(BuildContext context, {required String title, required Widget Function(BuildContext) builder}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            builder(sheetContext),
          ],
        ),
      ),
    ),
  );
}

class FormErrorText extends StatelessWidget {
  const FormErrorText(this.message, {super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: context.colors.critContainer, borderRadius: BorderRadius.circular(10)),
      child: Text(message!, style: TextStyle(color: context.colors.onCritContainer)),
    );
  }
}
