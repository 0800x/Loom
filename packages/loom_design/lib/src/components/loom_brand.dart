import 'package:flutter/material.dart';

/// Shared Loom artwork supplied by the product owner.
class LoomBrandMark extends StatelessWidget {
  const LoomBrandMark({this.size = 42, this.glow = true, super.key});

  final double size;
  // Retained for caller compatibility. The approved artwork is rendered as supplied.
  final bool glow;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: Localizations.localeOf(context).languageCode == 'fa'
        ? 'لوم'
        : 'Loom',
    child: Image.asset(
      Theme.of(context).brightness == Brightness.light
          ? 'assets/branding/loom_logo_light.png'
          : 'assets/branding/loom_logo.png',
      package: 'loom_design',
      width: size,
      height: size,
      fit: BoxFit.contain,
      cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
          .ceil()
          .clamp(1, 1024)
          .toInt(),
      filterQuality: FilterQuality.high,
      excludeFromSemantics: true,
    ),
  );
}
