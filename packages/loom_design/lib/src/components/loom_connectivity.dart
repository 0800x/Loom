import 'package:flutter/material.dart';

import '../loom_icons.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';
import 'loom_component_models.dart';

class LoomConnectivityPill extends StatelessWidget {
  const LoomConnectivityPill({
    required this.state,
    required this.label,
    this.onTap,
    super.key,
  });

  final LoomConnectivity state;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final (icon, color) = switch (state) {
      LoomConnectivity.online => (LoomIcons.circle, p.connectivity),
      LoomConnectivity.local => (LoomIcons.lan_outlined, p.connectivity),
      LoomConnectivity.nearby => (LoomIcons.compare_arrows_rounded, p.info),
      LoomConnectivity.relaying => (LoomIcons.route_outlined, p.info),
      LoomConnectivity.queued => (LoomIcons.schedule_rounded, p.warning),
      LoomConnectivity.syncing => (LoomIcons.sync_rounded, p.info),
      LoomConnectivity.unavailable => (
        LoomIcons.error_outline_rounded,
        p.critical,
      ),
    };
    final labelColor = switch (state) {
      LoomConnectivity.queued => p.warning,
      LoomConnectivity.unavailable => p.critical,
      _ => p.textSecondary,
    };
    final radius = BorderRadius.circular(LoomRadii.pill);
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: onTap == null ? 0.0 : LoomSizing.minTouch,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: LoomSpacing.xs,
            vertical: LoomSpacing.xxs,
          ),
          decoration: BoxDecoration(
            color: color.withAlphaFraction(LoomOpacity.statusSurface),
            borderRadius: radius,
            border: Border.all(
              color: color.withAlphaFraction(LoomOpacity.statusBorder),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: state == LoomConnectivity.online
                    ? LoomIconSize.statusDot
                    : LoomIconSize.micro,
                color: color,
              ),
              const SizedBox(width: LoomSpacing.xxs),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: labelColor, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
