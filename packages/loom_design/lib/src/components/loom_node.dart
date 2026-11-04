import 'package:flutter/material.dart';

import '../loom_theme.dart';
import '../loom_tokens.dart';

class LoomNodeCard extends StatelessWidget {
  const LoomNodeCard({
    required this.flag,
    required this.name,
    required this.location,
    required this.latency,
    required this.registration,
    required this.federation,
    this.capacity,
    this.onView,
    this.onRegister,
    required this.viewLabel,
    required this.registerLabel,
    super.key,
  });
  final String flag;
  final String name;
  final String location;
  final String latency;
  final String registration;
  final String federation;
  final String? capacity;
  final VoidCallback? onView;
  final VoidCallback? onRegister;
  final String viewLabel;
  final String registerLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LoomSpacing.xxs,
          vertical: LoomSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: LoomSizing.nodeFlag,
              height: LoomSizing.nodeFlag,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.surfaceMuted,
                borderRadius: BorderRadius.circular(LoomRadii.control),
              ),
              child: Text(
                flag,
                style: const TextStyle(fontSize: LoomIconSize.action),
              ),
            ),
            const SizedBox(width: LoomSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        latency,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: p.connectivity),
                      ),
                    ],
                  ),
                  const SizedBox(height: LoomSpacing.xxs),
                  Text(location, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: LoomSpacing.xs),
                  Wrap(
                    spacing: LoomSpacing.xs,
                    runSpacing: LoomSpacing.xxs,
                    children: [
                      _CompactPill(registration, p.connectivity),
                      _CompactPill(federation, p.info),
                      if (capacity != null)
                        _CompactPill(capacity!, p.textSecondary),
                    ],
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  Row(
                    children: [
                      TextButton(onPressed: onView, child: Text(viewLabel)),
                      const SizedBox(width: LoomSpacing.xxs),
                      FilledButton(
                        onPressed: onRegister,
                        child: Text(registerLabel),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactPill extends StatelessWidget {
  const _CompactPill(this.label, this.color);
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: LoomSpacing.xs,
      vertical: LoomSpacing.xxs,
    ),
    decoration: BoxDecoration(
      color: color.withAlphaFraction(LoomOpacity.selectedSubtle),
      borderRadius: BorderRadius.circular(LoomRadii.pill),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    ),
  );
}
