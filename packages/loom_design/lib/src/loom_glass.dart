import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'loom_accessibility.dart';
import 'loom_theme.dart';
import 'loom_tokens.dart';

enum LoomGlassStrength { weak, standard, strong }

enum LoomGlassQuality { high, reduced, disabled }

/// Automatic quality follows raster performance; accessibility wins in surfaces.
class LoomGlassScope extends StatefulWidget {
  const LoomGlassScope({
    required this.quality,
    required this.child,
    super.key,
  });
  final LoomGlassQuality quality; // Compatibility with older app callers.
  final Widget child;
  static LoomGlassQuality qualityOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_AutomaticGlassQuality>()
          ?.quality ??
      LoomGlassQuality.high;
  @override
  State<LoomGlassScope> createState() => _GlassScopeState();
}

class _GlassScopeState extends State<LoomGlassScope>
    with WidgetsBindingObserver {
  LoomGlassQuality _quality = LoomGlassQuality.high;
  int _frames = 0, _slow = 0, _healthyWindows = 0;
  bool _active = true;
  double _budget = 16000;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_timings);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hz = View.of(context).display.refreshRate;
    _budget = 1000000 / (hz > 0 ? hz : 60);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _frames = _slow = _healthyWindows = 0;
  }

  void _timings(List<FrameTiming> frames) {
    if (!_active || !mounted || widget.quality != LoomGlassQuality.high) {
      return;
    }
    for (final frame in frames) {
      _frames++;
      if (frame.rasterDuration.inMicroseconds > _budget * .85) _slow++;
    }
    if (_frames < 60) return;
    var next = _quality;
    if (_slow / _frames > .20) {
      next = LoomGlassQuality.reduced;
      _healthyWindows = 0;
    } else if (_slow == 0) {
      if (++_healthyWindows >= 8) next = LoomGlassQuality.high;
    } else {
      _healthyWindows = 0;
    }
    _frames = _slow = 0;
    if (next != _quality) setState(() => _quality = next);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AutomaticGlassQuality(
    quality: widget.quality == LoomGlassQuality.high
        ? _quality
        : widget.quality,
    child: widget.child,
  );
}

class _AutomaticGlassQuality extends InheritedWidget {
  const _AutomaticGlassQuality({required this.quality, required super.child});
  final LoomGlassQuality quality;
  @override
  bool updateShouldNotify(_AutomaticGlassQuality oldWidget) =>
      quality != oldWidget.quality;
}

class LoomGlassSurface extends StatelessWidget {
  const LoomGlassSurface({
    required this.child,
    this.strength = LoomGlassStrength.standard,
    this.radius = LoomRadii.surface,
    this.padding = EdgeInsets.zero,
    this.blur = true,
    this.liveBackdrop = false,
    super.key,
  });

  final Widget child;
  final LoomGlassStrength strength;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool blur;

  /// Chrome over moving content uses the compositor backdrop directly.
  final bool liveBackdrop;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final accessibility = LoomAccessibility.fromContext(context);
    final quality = accessibility.reduceTransparency
        ? LoomGlassQuality.disabled
        : LoomGlassScope.qualityOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final recipe = switch (strength) {
      LoomGlassStrength.weak => LoomGlassRecipes.weak,
      LoomGlassStrength.standard => LoomGlassRecipes.standard,
      LoomGlassStrength.strong => LoomGlassRecipes.strong,
    };
    final alpha = accessibility.highContrast
        ? .96
        : dark
        ? recipe.darkAlpha
        : recipe.lightAlpha;
    final effectiveAlpha = switch (quality) {
      LoomGlassQuality.high => alpha,
      LoomGlassQuality.reduced =>
        (alpha + LoomGlassRecipes.reducedOpacityBoost).clamp(0.0, 1.0),
      LoomGlassQuality.disabled => 1.0,
    };
    final effectiveBlur = switch (quality) {
      LoomGlassQuality.high => recipe.blur,
      LoomGlassQuality.reduced =>
        recipe.blur * LoomGlassRecipes.reducedBlurFactor,
      LoomGlassQuality.disabled => 0.0,
    };
    final surfaceColor = strength == LoomGlassStrength.strong
        ? p.surfaceElevated
        : p.surface;
    final shadowOpacity = switch (strength) {
      LoomGlassStrength.weak => 0.0,
      LoomGlassStrength.standard =>
        dark ? LoomOpacity.chromeShadowDark : LoomOpacity.chromeShadowLight,
      LoomGlassStrength.strong =>
        dark
            ? LoomOpacity.floatingShadowDark
            : LoomOpacity.floatingShadowLight,
    };
    final borderColor = accessibility.highContrast ? p.borderStrong : p.border;
    final content = Padding(padding: padding, child: child);

    // Reduced transparency and explicitly solid surfaces bypass the shader
    // entirely. This preserves accessibility and avoids unnecessary GPU work.
    if (!blur || effectiveBlur == 0) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: surfaceColor.withAlphaFraction(effectiveAlpha),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: borderColor),
          boxShadow: shadowOpacity == 0
              ? const <BoxShadow>[]
              : <BoxShadow>[
                  BoxShadow(
                    color: p.shadow.withAlphaFraction(shadowOpacity),
                    blurRadius: strength == LoomGlassStrength.strong
                        ? LoomElevation.floatingBlur
                        : LoomElevation.chromeBlur,
                    offset: Offset(
                      0,
                      strength == LoomGlassStrength.strong
                          ? LoomElevation.floatingOffset
                          : LoomElevation.chromeOffset,
                    ),
                  ),
                ],
        ),
        child: content,
      );
    }

    if (liveBackdrop) {
      final sigma = quality == LoomGlassQuality.reduced ? 7.0 : 16.0;
      final tint = accessibility.highContrast ? .96 : effectiveAlpha * .72;
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: p.shadow.withAlphaFraction(dark ? .22 : .08),
              blurRadius: 20,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    surfaceColor.withAlphaFraction(tint),
                    surfaceColor.withAlphaFraction(
                      (tint + .1).clamp(0.0, 1.0).toDouble(),
                    ),
                  ],
                ),
                border: Border.all(
                  color: accessibility.highContrast
                      ? p.borderStrong
                      : Colors.white.withAlphaFraction(dark ? .16 : .7),
                ),
              ),
              child: content,
            ),
          ),
        ),
      );
    }

    // Reduced quality keeps the glass material while avoiding refraction and
    // shader capture work. Clip the filter to this surface, never the page.
    if (quality == LoomGlassQuality.reduced) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surfaceColor.withAlphaFraction(effectiveAlpha),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: borderColor),
            ),
            child: content,
          ),
        ),
      );
    }

    // liquid_glass_easy notes that large blur sigmas are costly and look less
    // convincing on the Skia capture path. Refraction supplies the depth, so
    // cap blur at seven while keeping the design token free to describe the
    // stronger legacy/fallback recipe.
    final lensBlur = effectiveBlur.clamp(0.0, 7.0).toDouble();
    final distortion = switch (strength) {
      LoomGlassStrength.weak => .045,
      LoomGlassStrength.standard => .065,
      LoomGlassStrength.strong => .085,
    };
    final distortionWidth = switch (strength) {
      LoomGlassStrength.weak => 18.0,
      LoomGlassStrength.standard => 24.0,
      LoomGlassStrength.strong => 30.0,
    };

    return RepaintBoundary(
      child: LiquidGlassLens(
        style: LiquidGlassStyle(
          shape: LiquidGlassShape.continuousRoundedRectangle(
            cornerRadius: radius,
            borderWidth: accessibility.highContrast ? 1.5 : 1,
            borderColor: borderColor.withAlphaFraction(recipe.borderAlpha),
            lightIntensity: dark ? .72 : .9,
          ),
          appearance: LiquidGlassAppearance(
            color: surfaceColor.withAlphaFraction(effectiveAlpha),
            blur: LiquidGlassBlur(sigmaX: lensBlur, sigmaY: lensBlur),
            saturation: dark ? 1.06 : 1.1,
            shadow: shadowOpacity == 0
                ? null
                : LiquidGlassShadow(
                    blur: strength == LoomGlassStrength.strong ? 7 : 4,
                    opacity: shadowOpacity,
                    color: p.shadow,
                    cornerRadius: radius,
                  ),
          ),
          refraction: LiquidGlassRefraction(
            distortion: distortion,
            distortionWidth: distortionWidth,
            magnification: strength == LoomGlassStrength.strong
                ? 1.018
                : 1.01,
            chromaticAberration: dark ? .0015 : .002,
          ),
        ),
        child: content,
      ),
    );
  }
}

/// A bounded backdrop that fades into the scroll content below. Put this
/// beneath header controls, and let the page paint behind the system status bar.
class LoomTopGlassFade extends StatelessWidget {
  const LoomTopGlassFade({required this.height, super.key});
  final double height;

  @override
  Widget build(BuildContext context) {
    final access = LoomAccessibility.fromContext(context);
    final quality = access.reduceTransparency
        ? LoomGlassQuality.disabled : LoomGlassScope.qualityOf(context);
    final color = context.loom.background;
    final sigma = switch (quality) {
      LoomGlassQuality.high => 10.0,
      LoomGlassQuality.reduced => 4.0,
      LoomGlassQuality.disabled => 0.0,
    };
    final tint = ColoredBox(
      color: color.withAlphaFraction(
        quality == LoomGlassQuality.disabled
            ? 1
            : access.highContrast
            ? .96
            : .58,
      ),
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0, .35, 1],
            ).createShader(bounds),
            child: ClipRect(
              child: sigma == 0 ? tint : BackdropFilter(
                blendMode: BlendMode.src,
                filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: tint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared glass chrome for routes; explicit media-viewer colours still win.
/// Keep expensive refraction off scrolling headers and reuse one clipped blur.
class LoomGlassAppBar extends AppBar {
  LoomGlassAppBar({
    super.key,
    super.leading,
    super.automaticallyImplyLeading,
    super.title,
    super.actions,
    super.bottom,
    super.centerTitle,
    super.primary,
    super.leadingWidth,
    super.toolbarHeight,
    super.foregroundColor,
    super.systemOverlayStyle,
    Color? backgroundColor,
    super.surfaceTintColor = Colors.transparent,
    super.elevation = 0,
    super.scrolledUnderElevation = 0,
    super.flexibleSpace,
  }) : super(
    backgroundColor: backgroundColor ?? Colors.transparent,
  );
}
