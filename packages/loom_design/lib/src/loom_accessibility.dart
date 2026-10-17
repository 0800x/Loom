import 'package:flutter/material.dart';

enum LoomMotionPreference { system, full, reduced }

/// Normalized accessibility signals consumed by Loom visual primitives.
///
/// Flutter exposes reduce-motion, high-contrast and text-scaling signals through
/// [MediaQuery]. Some platforms do not expose a reduce-transparency preference
/// through Flutter directly; [LoomAccessibilityScope] is the bridge point for
/// a future, platform-specific adapter without coupling widgets to channels.
@immutable
class LoomAccessibility {
  const LoomAccessibility({
    this.reduceMotion = false,
    this.reduceTransparency = false,
    this.highContrast = false,
    this.largeText = false,
  });

  final bool reduceMotion;
  final bool reduceTransparency;
  final bool highContrast;
  final bool largeText;

  static LoomAccessibility fromContext(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final override = LoomAccessibilityScope.maybeOf(context);
    final platform = LoomAccessibility(
      reduceMotion: media?.disableAnimations ?? false,
      // Flutter does not currently provide one portable reduce-transparency
      // signal across all five target platforms. Do not misuse
      // accessibleNavigation as a proxy; native adapters can provide this via
      // LoomAccessibilityScope when implemented in a later phase.
      reduceTransparency: false,
      highContrast: media?.highContrast ?? false,
      largeText: (media?.textScaler.scale(16) ?? 16) >= 20,
    );
    if (override == null) return platform;
    return LoomAccessibility(
      reduceMotion: platform.reduceMotion || (override.reduceMotion ?? false),
      reduceTransparency:
          override.reduceTransparency ?? platform.reduceTransparency,
      highContrast: override.highContrast ?? platform.highContrast,
      largeText: override.largeText ?? platform.largeText,
    );
  }
}

@immutable
class LoomAccessibilityOverrides {
  const LoomAccessibilityOverrides({
    this.reduceMotion,
    this.reduceTransparency,
    this.highContrast,
    this.largeText,
  });

  final bool? reduceMotion;
  final bool? reduceTransparency;
  final bool? highContrast;
  final bool? largeText;
}

class LoomAccessibilityScope extends InheritedTheme {
  const LoomAccessibilityScope({
    required this.overrides,
    required super.child,
    super.key,
  });

  final LoomAccessibilityOverrides overrides;

  static LoomAccessibilityOverrides? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LoomAccessibilityScope>()
      ?.overrides;

  @override
  bool updateShouldNotify(LoomAccessibilityScope oldWidget) =>
      overrides != oldWidget.overrides;

  @override
  Widget wrap(BuildContext context, Widget child) =>
      LoomAccessibilityScope(overrides: overrides, child: child);
}
