import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../loom_accessibility.dart';
import '../loom_glass.dart';
import '../loom_interactions.dart';
import '../loom_theme.dart';
import '../loom_tokens.dart';

class LoomGlassNavigation extends StatelessWidget {
  const LoomGlassNavigation({
    required this.selectedIndex,
    required this.onSelected,
    required this.destinations,
    super.key,
  })  : assert(destinations.length > 0),
        assert(selectedIndex >= 0 && selectedIndex < destinations.length);

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<LoomNavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LoomSpacing.xxs),
      child: LoomGlassSurface(
        strength: LoomGlassStrength.standard,
        liveBackdrop: true,
        radius: LoomRadii.sheet,
        padding: const EdgeInsets.all(LoomSpacing.xxs),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedAlign(
                alignment: AlignmentDirectional(
                  destinations.length < 2
                      ? 0
                      : -1 + 2 * selectedIndex / (destinations.length - 1),
                  0,
                ),
                duration: reduceMotion ? Duration.zero : LoomMotion.component,
                curve: LoomMotion.emphasized,
                child: FractionallySizedBox(
                  widthFactor: 1 / destinations.length,
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            p.primary.withAlphaFraction(.17),
                            p.primary.withAlphaFraction(.055),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(
                          LoomRadii.navigation - 2,
                        ),
                        border: Border.all(
                          color: p.primary.withAlphaFraction(.15),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: List.generate(destinations.length, (index) {
                final item = destinations[index];
                final selected = index == selectedIndex;
                return Expanded(
                  child: Semantics(
                    selected: selected,
                    button: true,
                    label: item.label,
                    excludeSemantics: true,
                    onTap: () {
                      if (!selected) {
                        if (!reduceMotion) {
                          HapticFeedback.selectionClick();
                        }
                        onSelected(index);
                      }
                    },
                    child: LoomPressable(
                      child: InkWell(
                        onTap: () {
                          if (selected) {
                            return;
                          }
                          Feedback.forTap(context);
                          onSelected(index);
                        },
                        borderRadius: BorderRadius.circular(
                          LoomRadii.navigation,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 5,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _AnimatedNavigationIcon(
                                  icon: item.icon,
                                  selectedIcon: item.selectedIcon ?? item.icon,
                                  selected: selected,
                                  reduceMotion: reduceMotion,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        color: selected
                                            ? p.primary
                                            : p.textSecondary,
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedNavigationIcon extends StatelessWidget {
  const _AnimatedNavigationIcon({
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.reduceMotion,
  });

  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: selected ? 1 : 0),
      duration: reduceMotion ? Duration.zero : LoomMotion.component,
      curve: LoomMotion.emphasized,
      builder: (context, progress, _) {
        final baseColor = Color.lerp(
          p.textSecondary,
          p.primary.withAlphaFraction(.72),
          progress,
        );
        return Transform.translate(
          offset: Offset(0, -1.5 * progress),
          child: Transform.scale(
            scale: 1 + (.04 * progress),
            child: SizedBox(
              width: 30,
              height: 24,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(icon, size: LoomIconSize.standard, color: baseColor),
                  ClipPath(
                    clipper: _DiagonalRevealClipper(progress),
                    child: Icon(
                      selectedIcon,
                      size: LoomIconSize.standard,
                      color: p.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DiagonalRevealClipper extends CustomClipper<Path> {
  const _DiagonalRevealClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    if (progress <= 0) {
      return Path();
    }
    if (progress >= 1) {
      return Path()..addRect(Offset.zero & size);
    }

    final baseY = size.height * (1 - progress);
    final tilt = size.width * .18;
    final leftY = (baseY + tilt / 2).clamp(0.0, size.height).toDouble();
    final rightY = (baseY - tilt / 2).clamp(0.0, size.height).toDouble();

    return Path()
      ..moveTo(0, leftY)
      ..lineTo(size.width, rightY)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant _DiagonalRevealClipper oldClipper) =>
      oldClipper.progress != progress;
}

@immutable
class LoomNavigationDestination {
  const LoomNavigationDestination(this.icon, this.label, {this.selectedIcon});

  final IconData icon;
  final String label;
  final IconData? selectedIcon;
}
