import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

/// Shared building blocks for the profile surfaces (own profile and peer
/// profile) so both screens speak exactly the same flat, Telegram-style
/// visual language: circular tinted quick actions, grouped flat sections and
/// quiet information rows.

/// Circular tinted quick action: icon disc with a caption underneath.
class ProfileQuickAction extends StatelessWidget {
  const ProfileQuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: p.primary.withValues(alpha: .10),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? onTap : null,
              child: SizedBox.square(
                dimension: 52,
                child: Icon(icon, size: 23, color: p.primary),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: p.primary),
          ),
        ],
      ),
    );
  }
}

/// A titled group of flat rows wrapped in a [LoomSettingsGroup] card.
class ProfileSection extends StatelessWidget {
  const ProfileSection({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 6, bottom: 8),
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: context.loom.textSecondary),
          ),
        ),
        LoomSettingsGroup(children: children),
      ],
    ),
  );
}

/// Flat information row: tinted icon slot, muted label on top and the value
/// underneath, optional trailing control and tap behaviour.
class ProfileInfoRow extends StatelessWidget {
  const ProfileInfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.iconColor,
    this.trailing,
    this.onTap,
    this.showDivider = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final accent = iconColor ?? p.textSecondary;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsetsDirectional.only(
          start: 16,
          end: 8,
          top: 9,
          bottom: 9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: 34,
                  child: Icon(icon, size: 19, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: p.textSecondary),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        value,
                        maxLines: 1,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            if (showDivider)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 46),
                child: Divider(height: 1, color: p.border),
              ),
          ],
        ),
      ),
    );
  }
}

/// A label above a long selectable monospace-ish value (fingerprints,
/// identity keys, addresses).
class ProfileIdentityValue extends StatelessWidget {
  const ProfileIdentityValue({
    required this.label,
    required this.value,
    this.showDivider = true,
    super.key,
  });

  final String label;
  final String value;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            value,
            textDirection: TextDirection.ltr,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
