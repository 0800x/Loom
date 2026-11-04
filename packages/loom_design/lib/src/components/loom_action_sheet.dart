import 'package:flutter/material.dart';

import '../loom_icons.dart';
import '../loom_interactions.dart';
import '../loom_surface_motion.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';

Future<T?> showLoomActionSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  Rect? origin,
  required WidgetBuilder builder,
}) => showLoomSurface<T>(
  context: context,
  origin: origin,
  identity: ('action-sheet', title),
  builder: (context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(LoomIcons.close_rounded),
              ),
            ],
          ),
          if (subtitle != null) ...[
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
          ],
          builder(context),
        ],
      ),
    ),
  ),
);

class LoomActionTile extends StatelessWidget {
  const LoomActionTile({
    required this.icon,
    required this.label,
    this.subtitle,
    this.color,
    this.onTap,
    super.key,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final accent = onTap == null ? p.textMuted : color ?? p.primary;
    return LoomPressable(
      enabled: onTap != null,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        child: Material(
          color: p.surfaceMuted.withAlphaFraction(.65),
          borderRadius: BorderRadius.circular(LoomRadii.surface),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(LoomRadii.surface),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: accent.withAlphaFraction(.13),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: accent),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: onTap == null ? p.textMuted : p.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoomActionGrid extends StatelessWidget {
  const LoomActionGrid({required this.children, super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 500 && children.length > 2
          ? 4
          : 2;
      final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (var i = 0; i < children.length; i++)
            SizedBox(
              width: width,
              child: LoomReveal(order: i, child: children[i]),
            ),
        ],
      );
    },
  );
}
