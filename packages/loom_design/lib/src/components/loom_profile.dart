import 'package:flutter/material.dart';

import '../loom_theme.dart';
import '../loom_tokens.dart';
import 'loom_brand.dart';
import 'loom_identity.dart';

class LoomProfileHero extends StatelessWidget {
  const LoomProfileHero({
    required this.name,
    required this.presence,
    this.address,
    this.showPresence = true,
    this.presenceSemanticLabel,
    this.avatar,
    super.key,
  });

  final String name;
  final String presence;
  final String? address;
  final bool showPresence;
  final String? presenceSemanticLabel;
  final Widget? avatar;
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: LoomSizing.profileHeroMin),
      padding: const EdgeInsets.fromLTRB(
        LoomSpacing.ml,
        LoomSpacing.lg,
        LoomSpacing.ml,
        LoomSpacing.md,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(p.primary.withAlphaFraction(.12), p.surface),
            p.surface,
            Color.alphaBlend(p.secondary.withAlphaFraction(.06), p.surface),
          ],
        ),
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [p.primary, p.secondary]),
              boxShadow: [
                BoxShadow(
                  color: p.shadow.withAlphaFraction(.16),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: avatar ??
                LoomAvatar(
                  label: name,
                  size: LoomSizing.profileAvatar,
                  presence: showPresence,
                  presenceLabel: presenceSemanticLabel,
                ),
          ),
          const SizedBox(height: LoomSpacing.sm),
          Text(name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: LoomSpacing.xxs),
          Text(
            presence,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: p.connectivity),
          ),
          if (address != null) ...[
            const SizedBox(height: LoomSpacing.xxs),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                address!,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact use of the canonical Loom logo throughout navigation and chrome.
class LoomRouteMark extends StatelessWidget {
  const LoomRouteMark({super.key, this.size = 38});

  final double size;

  @override
  Widget build(BuildContext context) => LoomBrandMark(size: size, glow: false);
}
