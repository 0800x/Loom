import 'package:flutter/material.dart';

import '../loom_glass.dart';
import '../loom_interactions.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';

class LoomGlassButton extends StatelessWidget {
  const LoomGlassButton({
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    super.key,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final child = LoomPressable(
      enabled: onPressed != null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: LoomSizing.minTouch),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(LoomRadii.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LoomSpacing.md,
              vertical: LoomSpacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: LoomIconSize.standard),
                  const SizedBox(width: LoomSpacing.xs),
                ],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: primary ? p.onPrimary : p.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (primary) {
      return Semantics(
        button: true,
        enabled: onPressed != null,
        child: Opacity(
          opacity: onPressed == null ? .45 : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.primary,
              borderRadius: BorderRadius.circular(LoomRadii.control),
            ),
            child: IconTheme(
              data: IconThemeData(color: p.onPrimary),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: p.onPrimary),
                child: child,
              ),
            ),
          ),
        ),
      );
    }
    return LoomGlassSurface(
      strength: LoomGlassStrength.weak,
      radius: LoomRadii.control,
      blur: false,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        child: Opacity(opacity: onPressed == null ? .45 : 1, child: child),
      ),
    );
  }
}
