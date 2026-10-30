import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'loom_tokens.dart';
import 'loom_interactions.dart';

enum LoomThemeMode { light, dark, oled }

/// A theme-aware modal scrim so barriers melt into both appearances.
@immutable
class LoomPalette extends ThemeExtension<LoomPalette> {
  const LoomPalette({
    required this.background,
    required this.surface,
    required this.surfaceMuted,
    required this.surfaceElevated,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.border,
    required this.borderStrong,
    required this.primary,
    required this.secondary,
    required this.connectivity,
    required this.warning,
    required this.critical,
    required this.info,
    required this.onPrimary,
    required this.shadow,
    this.scrim = const Color(0x59000000),
  });

  final Color background;
  final Color surface;
  final Color surfaceMuted;
  final Color surfaceElevated;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color border;
  final Color borderStrong;
  final Color primary;
  final Color secondary;
  final Color connectivity;
  final Color warning;
  final Color critical;
  final Color info;
  final Color onPrimary;
  final Color shadow;

  /// Barrier colour for modal routes, menus and popups.
  final Color scrim;

  @override
  LoomPalette copyWith({
    Color? background,
    Color? surface,
    Color? surfaceMuted,
    Color? surfaceElevated,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? border,
    Color? borderStrong,
    Color? primary,
    Color? secondary,
    Color? connectivity,
    Color? warning,
    Color? critical,
    Color? info,
    Color? onPrimary,
    Color? shadow,
    Color? scrim,
  }) =>
      LoomPalette(
        background: background ?? this.background,
        surface: surface ?? this.surface,
        surfaceMuted: surfaceMuted ?? this.surfaceMuted,
        surfaceElevated: surfaceElevated ?? this.surfaceElevated,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textMuted: textMuted ?? this.textMuted,
        border: border ?? this.border,
        borderStrong: borderStrong ?? this.borderStrong,
        primary: primary ?? this.primary,
        secondary: secondary ?? this.secondary,
        connectivity: connectivity ?? this.connectivity,
        warning: warning ?? this.warning,
        critical: critical ?? this.critical,
        info: info ?? this.info,
        onPrimary: onPrimary ?? this.onPrimary,
        shadow: shadow ?? this.shadow,
        scrim: scrim ?? this.scrim,
      );

  @override
  LoomPalette lerp(covariant LoomPalette? other, double t) {
    if (other == null) {
      return this;
    }
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return LoomPalette(
      background: c(background, other.background),
      surface: c(surface, other.surface),
      surfaceMuted: c(surfaceMuted, other.surfaceMuted),
      surfaceElevated: c(surfaceElevated, other.surfaceElevated),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textMuted: c(textMuted, other.textMuted),
      border: c(border, other.border),
      borderStrong: c(borderStrong, other.borderStrong),
      primary: c(primary, other.primary),
      secondary: c(secondary, other.secondary),
      connectivity: c(connectivity, other.connectivity),
      warning: c(warning, other.warning),
      critical: c(critical, other.critical),
      info: c(info, other.info),
      onPrimary: c(onPrimary, other.onPrimary),
      shadow: c(shadow, other.shadow),
      scrim: c(scrim, other.scrim),
    );
  }
}

abstract final class LoomTheme {
  // Porcelain — airy warm light. Text pairs keep AAA body contrast on all
  // surfaces; the terracotta primary keeps the Loom brand warm and human.
  static const LoomPalette _light = LoomPalette(
    background: Color(0xFFF6F1EC),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFEDE5DE),
    surfaceElevated: Color(0xFFFCF8F4),
    textPrimary: Color(0xFF26201C),
    textSecondary: Color(0xFF6B5D55),
    textMuted: Color(0xFF95847B),
    border: Color(0x141A2230),
    borderStrong: Color(0x2A1A2230),
    primary: Color(0xFFA03D28),
    secondary: Color(0xFF7D6752),
    connectivity: Color(0xFF0B7A5E),
    warning: Color(0xFFA6721C),
    critical: Color(0xFFB8454F),
    info: Color(0xFF7C5A47),
    onPrimary: Color(0xFFFFFFFF),
    shadow: Color(0xFF2A1A10),
    scrim: Color(0x521E150F),
  );

  // Midnight — deep blue-charcoal with a calm coral accent. Glass surfaces
  // gain their depth from the low-luminance background underneath.
  static const LoomPalette _dark = LoomPalette(
    background: Color(0xFF0F1115),
    surface: Color(0xFF17191F),
    surfaceMuted: Color(0xFF20222A),
    surfaceElevated: Color(0xFF272A32),
    textPrimary: Color(0xFFF1F4F8),
    textSecondary: Color(0xFFAAB4C1),
    textMuted: Color(0xFF8B99AB),
    border: Color(0x18FFFFFF),
    borderStrong: Color(0x2EFFFFFF),
    primary: Color(0xFFF5A089),
    secondary: Color(0xFFD8B79E),
    connectivity: Color(0xFF3ED598),
    warning: Color(0xFFE2A94F),
    critical: Color(0xFFEF6E7A),
    info: Color(0xFFC9B4A6),
    onPrimary: Color(0xFF301409),
    shadow: Color(0xFF000000),
    scrim: Color(0x8C05070C),
  );

  // Void — true black for OLED panels; surfaces stay hairline-separated.
  static const LoomPalette _oled = LoomPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF0A0A0D),
    surfaceMuted: Color(0xFF121216),
    surfaceElevated: Color(0xFF1A1A20),
    textPrimary: Color(0xFFF3F6FA),
    textSecondary: Color(0xFFA8B2BF),
    textMuted: Color(0xFF8E9BAD),
    border: Color(0x1AFFFFFF),
    borderStrong: Color(0x32FFFFFF),
    primary: Color(0xFFF5A089),
    secondary: Color(0xFFD8B79E),
    connectivity: Color(0xFF3EC9A9),
    warning: Color(0xFFE2A94F),
    critical: Color(0xFFEF6E7A),
    info: Color(0xFFC9B4A6),
    onPrimary: Color(0xFF301409),
    shadow: Color(0xFF000000),
    scrim: Color(0x9E000000),
  );

  /// The midnight palette as data, for surfaces that stay intentionally dark
  /// regardless of the active theme (active call stage, media viewers).
  static LoomPalette get darkPalette => _dark;

  static ThemeData light({String? fontFamily, Color? accent}) => _build(
        _accent(_light, Brightness.light, accent),
        Brightness.light,
        fontFamily: fontFamily,
      );

  static ThemeData dark({String? fontFamily, Color? accent}) => _build(
        _accent(_dark, Brightness.dark, accent),
        Brightness.dark,
        fontFamily: fontFamily,
      );
  static ThemeData oled({String? fontFamily, Color? accent}) => _build(
        _accent(_oled, Brightness.dark, accent),
        Brightness.dark,
        fontFamily: fontFamily,
      );

  static LoomPalette _accent(
    LoomPalette palette,
    Brightness brightness,
    Color? accent,
  ) {
    if (accent == null) {
      return palette;
    }
    final colors = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    );
    return palette.copyWith(
      primary: colors.primary,
      onPrimary: colors.onPrimary,
      secondary: colors.secondary,
      info: colors.tertiary,
    );
  }

  static ThemeData _build(
    LoomPalette p,
    Brightness brightness, {
    String? fontFamily,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: p.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: p.primary,
        brightness: brightness,
      ).copyWith(
        primary: p.primary,
        onPrimary: p.onPrimary,
        primaryContainer: p.primary.withAlphaFraction(.16),
        onPrimaryContainer: p.primary,
        secondary: p.secondary,
        onSecondary: p.onPrimary,
        secondaryContainer: p.secondary.withAlphaFraction(.18),
        onSecondaryContainer: p.textPrimary,
        tertiary: p.info,
        onTertiary: p.onPrimary,
        surface: p.surface,
        onSurface: p.textPrimary,
        onSurfaceVariant: p.textSecondary,
        surfaceContainerHighest: p.surfaceMuted,
        surfaceContainerHigh: p.surfaceMuted,
        surfaceContainer: p.surfaceMuted,
        surfaceContainerLow: p.surface,
        surfaceContainerLowest: p.surface,
        outline: p.borderStrong,
        outlineVariant: p.border,
        error: p.critical,
        onError: brightness == Brightness.dark
            ? const Color(0xFF3A0A10)
            : Colors.white,
        inverseSurface: p.textPrimary,
        onInverseSurface: p.background,
        scrim: p.scrim,
        shadow: p.shadow,
      ),
    );
    // Persian text frequently appears inside English-mode strings (contact
    // names, message snippets). The platform default family has no
    // Arabic-script coverage, so Vazirmatn rides along as the first
    // fallback for every style; the explicit fa family keeps its own chain.
    final fallback = <String>[
      if (fontFamily != null) fontFamily,
      'Vazirmatn',
    ];
    TextStyle fb(TextStyle? style) =>
        style?.copyWith(fontFamilyFallback: fallback) ??
        const TextStyle();
    final themed = base.copyWith(
      extensions: <ThemeExtension<dynamic>>[p],
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: LoomPageTransitionsBuilder(),
          TargetPlatform.iOS: LoomPageTransitionsBuilder(),
          TargetPlatform.macOS: LoomPageTransitionsBuilder(),
          TargetPlatform.windows: LoomPageTransitionsBuilder(),
          TargetPlatform.linux: LoomPageTransitionsBuilder(),
          TargetPlatform.fuchsia: LoomPageTransitionsBuilder(),
        },
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          disabledBackgroundColor: p.surfaceMuted,
          disabledForegroundColor: p.textMuted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LoomRadii.control),
          ),
          textStyle: TextStyle(
            fontFamily: fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 50),
          foregroundColor: p.textPrimary,
          side: BorderSide(color: p.borderStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LoomRadii.control),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(LoomSizing.minTouch),
          foregroundColor: p.textSecondary,
          shape: const CircleBorder(),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.primary,
        selectionColor: p.primary.withAlphaFraction(.22),
        selectionHandleColor: p.primary,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.surfaceElevated,
        contentTextStyle: TextStyle(color: p.textPrimary),
        actionTextColor: p.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoomRadii.control),
          side: BorderSide(color: p.borderStrong),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoomRadii.sheet),
          side: BorderSide(color: p.borderStrong),
        ),
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: p.textPrimary,
          fontSize: LoomTypeScale.title,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: base.textTheme.bodyMedium?.copyWith(
          color: p.textPrimary,
          fontSize: LoomTypeScale.body,
          height: LoomTypeScale.bodyHeight,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(LoomRadii.sheet),
          ),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.onPrimary
              : p.surfaceElevated,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.primary
              : p.borderStrong,
        ),
        trackOutlineColor: WidgetStatePropertyAll(p.border),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceMuted,
        selectedColor: p.primary.withAlphaFraction(LoomOpacity.selectedStrong),
        checkmarkColor: p.primary,
        side: BorderSide(color: p.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoomRadii.control),
        ),
        labelStyle: base.textTheme.labelMedium?.copyWith(
          color: p.textPrimary,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.primary,
        inactiveTrackColor: p.borderStrong,
        thumbColor: p.primary,
        overlayColor: p.primary.withAlphaFraction(.12),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.primary,
        linearTrackColor: p.borderStrong,
        circularTrackColor: p.border,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoomRadii.control),
          side: BorderSide(color: p.borderStrong),
        ),
        textStyle: base.textTheme.bodyMedium?.copyWith(color: p.textPrimary),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(LoomSizing.minTouch, LoomSizing.minTouch),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LoomRadii.control),
          ),
        ),
      ),
      dividerColor: p.border,
      dividerTheme: DividerThemeData(
        color: p.border,
        thickness: LoomBorders.hairline,
      ),
      splashFactory: InkRipple.splashFactory,
      iconTheme: IconThemeData(
        color: p.textSecondary,
        size: LoomIconSize.standard,
      ),
      appBarTheme: AppBarTheme(
        systemOverlayStyle: (base.brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark)
            .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarContrastEnforced: false,
        ),
        backgroundColor: p.surface,
        foregroundColor: p.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 24,
          height: 1.18,
          fontWeight: FontWeight.w700,
          color: p.textPrimary,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontSize: LoomTypeScale.headline,
          height: LoomTypeScale.headlineHeight,
          fontWeight: FontWeight.w700,
          color: p.textPrimary,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: LoomTypeScale.titleLarge,
          height: LoomTypeScale.titleLargeHeight,
          fontWeight: FontWeight.w700,
          color: p.textPrimary,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: LoomTypeScale.title,
          height: LoomTypeScale.titleHeight,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontSize: 15,
          height: 1.30,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 13,
          height: LoomTypeScale.labelHeight,
          fontWeight: FontWeight.w700,
          color: p.textPrimary,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          fontSize: LoomTypeScale.bodyLarge,
          height: LoomTypeScale.bodyLargeHeight,
          color: p.textPrimary,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: LoomTypeScale.body,
          height: LoomTypeScale.bodyHeight,
          color: p.textPrimary,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: LoomTypeScale.bodySmall,
          height: LoomTypeScale.bodySmallHeight,
          color: p.textSecondary,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: LoomTypeScale.label,
          height: LoomTypeScale.labelHeight,
          fontWeight: FontWeight.w600,
          color: p.textSecondary,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(
          fontSize: LoomTypeScale.labelSmall,
          height: LoomTypeScale.labelHeight,
          fontWeight: FontWeight.w500,
          color: p.textSecondary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        helperMaxLines: 3,
        errorMaxLines: 3,
        filled: true,
        fillColor: p.surfaceMuted,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: LoomSpacing.sm,
          vertical: LoomSpacing.sm,
        ),
        hintStyle: TextStyle(color: p.textMuted),
        prefixIconColor: p.textMuted,
        suffixIconColor: p.textMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LoomRadii.control),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LoomRadii.control),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LoomRadii.control),
          borderSide: BorderSide(
            color: p.primary.withAlphaFraction(LoomOpacity.focusBorder),
            width: LoomBorders.standard,
          ),
        ),
      ),
    );
    // The large copyWith above rebuilds its own textTheme; layer the
    // fallback chain on the finished result so every customized style
    // (sizes, colors, weights) keeps its overrides AND gains the fallback.
    final finished = themed.textTheme;
    return themed.copyWith(
      textTheme: finished.copyWith(
        displayLarge: fb(finished.displayLarge),
        displayMedium: fb(finished.displayMedium),
        displaySmall: fb(finished.displaySmall),
        headlineLarge: fb(finished.headlineLarge),
        headlineMedium: fb(finished.headlineMedium),
        headlineSmall: fb(finished.headlineSmall),
        titleLarge: fb(finished.titleLarge),
        titleMedium: fb(finished.titleMedium),
        titleSmall: fb(finished.titleSmall),
        bodyLarge: fb(finished.bodyLarge),
        bodyMedium: fb(finished.bodyMedium),
        bodySmall: fb(finished.bodySmall),
        labelLarge: fb(finished.labelLarge),
        labelMedium: fb(finished.labelMedium),
        labelSmall: fb(finished.labelSmall),
      ),
    );
  }
}

extension LoomThemeContext on BuildContext {
  LoomPalette get loom =>
      Theme.of(this).extension<LoomPalette>() ??
      LoomTheme.light().extension<LoomPalette>()!;
}
