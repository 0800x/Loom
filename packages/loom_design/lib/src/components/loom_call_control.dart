import 'package:flutter/material.dart';

import '../loom_theme.dart';
import '../loom_tokens.dart';

/// Keep each control's slot even while its action is unavailable. State labels
/// describe capture; tooltips describe the next explicit user action.
class LoomCallControl extends StatelessWidget {
  const LoomCallControl({
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.destructive = false,
    super.key,
  });
  final String label, tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool active, destructive;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        toggled: destructive ? null : active,
        child: IconButton.filledTonal(
          tooltip: tooltip,
          onPressed: onPressed,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(LoomSizing.minTouch),
            foregroundColor: destructive
                ? Theme.of(context).colorScheme.onError
                : active
                ? context.loom.onPrimary
                : context.loom.textPrimary,
            backgroundColor: destructive
                ? Theme.of(context).colorScheme.error
                : active
                ? context.loom.primary
                : context.loom.surfaceMuted,
          ),
          icon: Icon(icon),
        ),
      ),
      const SizedBox(height: LoomSpacing.xxs),
      Text(
        label,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    ],
  );
}
