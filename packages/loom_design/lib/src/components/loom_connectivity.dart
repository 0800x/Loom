import 'package:flutter/material.dart';

import '../loom_icons.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';
import 'loom_component_models.dart';

class LoomConnectivityPill extends StatefulWidget {
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
  State<LoomConnectivityPill> createState() => _LoomConnectivityPillState();
}

class _LoomConnectivityPillState extends State<LoomConnectivityPill> {
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final state = widget.state;
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
        minHeight: widget.onTap == null ? 0.0 : LoomSizing.minTouch,
      ),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: radius,
        child: AnimatedContainer(
          duration: LoomMotion.component,
          curve: LoomMotion.standard,
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
              AnimatedSwitcher(
                duration: LoomMotion.component,
                switchInCurve: LoomMotion.standard,
                switchOutCurve: LoomMotion.exit,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: .6, end: 1).animate(animation),
                    child: child,
                  ),
                ),
                child: Icon(
                  icon,
                  key: ValueKey(icon),
                  size: state == LoomConnectivity.online
                      ? LoomIconSize.statusDot
                      : LoomIconSize.micro,
                  color: color,
                ),
              ),
              const SizedBox(width: LoomSpacing.xxs),
              AnimatedDefaultTextStyle(
                duration: LoomMotion.component,
                style: (Theme.of(context).textTheme.labelSmall ??
                        const TextStyle(fontSize: LoomTypeScale.labelSmall))
                    .copyWith(color: labelColor, fontWeight: FontWeight.w600),
                child: Text(widget.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
