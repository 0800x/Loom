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
    final accent = iconColor ?? _settingsIconColor(icon, p.primary);
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
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    size: LoomIconSize.standard,
                    color: Colors.white,
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
                        style: Theme.of(context).textTheme.bodyMedium
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

Color _settingsIconColor(IconData icon, Color fallback) {
  // A restrained warm palette, rather than a single colour for every section.
  if (icon == LoomIcons.logout_rounded) return const Color(0xFFBC4E5C);
  if (icon == LoomIcons.person_outline_rounded ||
      icon == LoomIcons.notifications_none_rounded)
    return const Color(0xFFCE6552);
  if (icon == LoomIcons.lock_outline_rounded ||
      icon == LoomIcons.devices_outlined)
    return const Color(0xFF9D7893);
  if (icon == LoomIcons.storage_outlined || icon == LoomIcons.near_me_outlined)
    return const Color(0xFF668B79);
  if (icon == LoomIcons.folder_outlined || icon == LoomIcons.language_rounded)
    return const Color(0xFFB18A51);
  if (icon == LoomIcons.palette_outlined ||
      icon == LoomIcons.info_outline_rounded)
    return const Color(0xFFAD806B);
  return fallback;
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
