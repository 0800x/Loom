import 'package:flutter/material.dart';

abstract final class LoomSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double ml = 20;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 40;
  static const double xxxl = 48;
}

abstract final class LoomRadii {
  static const double compact = 10;
  static const double control = 14;
  static const double surface = 18;
  static const double navigation = 24;
  static const double sheet = 28;
  static const double hero = 32;
  static const double pill = 999;
}

abstract final class LoomBorders {
  static const double hairline = 0.5;
  static const double standard = 1;
  static const double emphasis = 1.5;
  static const double selectedRail = 2;
}

abstract final class LoomElevation {
  static const double chromeBlur = 10;
  static const double floatingBlur = 16;
  static const double chromeOffset = 3;
  static const double floatingOffset = 7;
}

abstract final class LoomIconSize {
  static const double statusDot = 7;
  static const double micro = 13;
  static const double compact = 16;
  static const double standard = 20;
  static const double action = 22;
  static const double navigation = 22;
  static const double hero = 28;
  static const double emptyState = 34;
}

abstract final class LoomSizing {
  static const double minTouch = 48;
  static const double compactAvatar = 40;
  static const double avatar = 48;
  static const double nodeFlag = 42;
  static const double largeAvatar = 76;
  static const double detailsAvatar = 82;
  static const double profileAvatar = 108;
  static const double profileHeroMin = 270;
  static const double navRail = 84;
  static const double settingsIconSlot = 34;
  static const double mobileNavMinHeight = 52;
  static const double compactRowHeight = 68;
  static const double folderStripHeight = 36;
  static const double profileTabsHeight = 38;
  static const double headerMinHeight = 58;
  static const double searchHeight = 44;
  static const double composerMinHeight = 52;
  static const double audioRowMin = 72;
  static const double messageMax = 600;
  static const double onboardingMax = 620;
  static const double dialogMax = 440;
  static const double contextMenuMin = 180;
  static const double contextMenuMax = 260;
  static const double contentMax = 920;
  static const double formMax = 620;
  static const double detailsMax = 760;
}

abstract final class LoomOpacity {
  static const double selectedSubtle = 0.06;
  static const double selected = 0.09;
  static const double selectedStrong = 0.12;
  static const double mutedTint = 0.10;
  static const double borderSelected = 0.16;

  static const double statusSurface = 0.08;
  static const double statusBorder = 0.14;
  static const double unreadSurface = 0.16;
  static const double sentBubbleSurface = 0.18;
  static const double sentBubbleBorder = 0.22;
  static const double focusBorder = 0.58;

  static const double chromeShadowLight = 0.04;
  static const double chromeShadowDark = 0.08;
  static const double floatingShadowLight = 0.06;
  static const double floatingShadowDark = 0.12;
}

abstract final class LoomTypeScale {
  static const double headline = 30;
  static const double titleLarge = 23;
  static const double title = 18;
  static const double bodyLarge = 16;
  static const double body = 14.5;
  static const double bodySmall = 12.5;
  static const double label = 12.5;
  static const double labelSmall = 11.5;

  static const double headlineHeight = 1.16;
  static const double titleLargeHeight = 1.20;
  static const double titleHeight = 1.28;
  static const double bodyLargeHeight = 1.42;
  static const double bodyHeight = 1.38;
  static const double bodySmallHeight = 1.36;
  static const double labelHeight = 1.30;
}

abstract final class LoomMotion {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration component = Duration(milliseconds: 180);
  static const Duration route = Duration(milliseconds: 260);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Cubic(0.2, 0.8, 0.2, 1);
  static const Curve exit = Curves.easeInCubic;
}

@immutable
class LoomGlassRecipe {
  const LoomGlassRecipe({
    required this.blur,
    required this.lightAlpha,
    required this.darkAlpha,
    required this.borderAlpha,
  });

  final double blur;
  final double lightAlpha;
  final double darkAlpha;
  final double borderAlpha;
}

abstract final class LoomGlassRecipes {
  static const LoomGlassRecipe weak = LoomGlassRecipe(
    blur: 14,
    lightAlpha: 0.78,
    darkAlpha: 0.72,
    borderAlpha: 0.28,
  );
  static const LoomGlassRecipe standard = LoomGlassRecipe(
    blur: 22,
    lightAlpha: 0.72,
    darkAlpha: 0.66,
    borderAlpha: 0.34,
  );
  static const LoomGlassRecipe strong = LoomGlassRecipe(
    blur: 30,
    lightAlpha: 0.82,
    darkAlpha: 0.76,
    borderAlpha: 0.42,
  );

  static const double reducedBlurFactor = 0.35;
  static const double reducedOpacityBoost = 0.10;
}

extension LoomColorAlpha on Color {
  Color withAlphaFraction(double opacity) =>
      withAlpha((opacity.clamp(0.0, 1.0) * 255).round());
}
