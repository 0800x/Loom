import 'package:flutter/material.dart';

import '../loom_glass.dart';
import '../loom_icons.dart';
import '../loom_interactions.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';

class LoomSettingsGroup extends StatelessWidget {
  const LoomSettingsGroup({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.loom.surface,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(LoomRadii.surface),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class LoomSettingsRow extends StatelessWidget {
  const LoomSettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconColor,
    this.trailing,
    this.showDivider = true,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconColor;
  final Widget? trailing;
  final bool showDivider;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final accent = iconColor ?? _settingsIconColor(icon, p);
    return Semantics(
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.symmetric(
            horizontal: LoomSpacing.md,
            vertical: LoomSpacing.sm,
          ),
          decoration: BoxDecoration(
            border: showDivider
                ? Border(bottom: BorderSide(color: p.border))
                : null,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                Container(
                  width: LoomSizing.settingsIconSlot,
                  height: LoomSizing.settingsIconSlot,
                  decoration: BoxDecoration(
                    color: accent.withAlphaFraction(LoomOpacity.mutedTint),
                    borderRadius: BorderRadius.circular(LoomRadii.compact),
                  ),
                  child: Icon(
                    icon,
                    size: LoomIconSize.standard,
                    color: accent,
                  ),
                ),
                const SizedBox(width: LoomSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: LoomSpacing.xxs),
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: LoomSpacing.xs),
                if (trailing != null)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * .38,
                    ),
                    child: trailing!,
                  )
                else if (onTap != null)
                  LoomDirectionalIcon(
                    LoomIcons.chevron_right_rounded,
                    size: LoomIconSize.standard,
                    color: p.textMuted,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LoomGlassSheet extends StatelessWidget {
  const LoomGlassSheet({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => LoomGlassSurface(
        strength: LoomGlassStrength.standard,
        radius: LoomRadii.sheet,
        padding: const EdgeInsets.all(LoomSpacing.md),
        child: child,
      );
}

Color _settingsIconColor(IconData icon, LoomPalette p) {
  // Sections map to semantic palette roles, so tints follow the active
  // accent and theme instead of a fixed set of swatches.
  if (icon == LoomIcons.logout_rounded) {
    return p.critical;
  }
  if (icon == LoomIcons.lock_outline_rounded ||
      icon == LoomIcons.devices_outlined) {
    return p.connectivity;
  }
  if (icon == LoomIcons.storage_outlined ||
      icon == LoomIcons.near_me_outlined) {
    return p.connectivity;
  }
  if (icon == LoomIcons.folder_outlined || icon == LoomIcons.language_rounded) {
    return p.warning;
  }
  if (icon == LoomIcons.palette_outlined) {
    return p.secondary;
  }
  if (icon == LoomIcons.info_outline_rounded) {
    return p.info;
  }
  // Identity, notifications and anything unlisted keep the primary voice.
  return p.primary;
}

/// A calm opaque surface for settings; navigation retains the glass treatment.
class LoomSettingsCard extends StatelessWidget {
  const LoomSettingsCard({
    required this.child,
    this.padding = const EdgeInsets.all(LoomSpacing.md),
    super.key,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Material(
        color: context.loom.surface,
        borderRadius: BorderRadius.circular(LoomRadii.surface),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      );
}
