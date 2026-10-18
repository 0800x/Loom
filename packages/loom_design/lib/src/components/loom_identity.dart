import 'package:flutter/material.dart';

import '../loom_theme.dart';
import '../loom_tokens.dart';

class LoomAvatar extends StatelessWidget {
  const LoomAvatar({
    required this.label,
    this.size = LoomSizing.avatar,
    this.presence = false,
    this.presenceLabel,
    this.image,
    super.key,
  });
  final String label;
  final double size;
  final bool presence;
  final String? presenceLabel;
  final ImageProvider<Object>? image;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final initials = label.trim().isEmpty
        ? '?'
        : label
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((e) => e.characters.first.toUpperCase())
            .join();
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CircleAvatar(
              backgroundColor: p.primary.withAlphaFraction(0.13),
              foregroundImage: image,
              child: Text(
                initials,
                style: TextStyle(color: p.primary, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (presence)
            PositionedDirectional(
              end: -1,
              bottom: -1,
              child: LoomPresenceIndicator(
                size: size * .24,
                semanticLabel: presenceLabel,
              ),
            ),
        ],
      ),
    );
  }
}

class LoomPresenceIndicator extends StatelessWidget {
  const LoomPresenceIndicator({
    this.size = LoomSpacing.sm,
    this.semanticLabel,
    super.key,
  });
  final double size;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Semantics(
      label: semanticLabel,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: p.connectivity,
          border: Border.all(color: p.surface, width: LoomBorders.selectedRail),
        ),
      ),
    );
  }
}
