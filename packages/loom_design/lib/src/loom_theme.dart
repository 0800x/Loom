import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'loom_tokens.dart';
import 'loom_interactions.dart';

enum LoomThemeMode { light, dark, oled }

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
    );
  }
}

abstract final class LoomTheme {
  static const LoomPalette _light = LoomPalette(
    background: Color(0xFFF7F3F0),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFEEE7E2),
    surfaceElevated: Color(0xFFFCF8F5),
    textPrimary: Color(0xFF2D2522),
    textSecondary: Color(0xFF756660),
    textMuted: Color(0xFF7B6D66),
    border: Color(0x16111C2D),
    borderStrong: Color(0x2A111C2D),
    primary: Color(0xFFA8422C),
    secondary: Color(0xFF88684F),
    connectivity: Color(0xFF087E63),
    warning: Color(0xFFB97B20),
    critical: Color(0xFFBC4E5C),
    info: Color(0xFF8B604E),
    onPrimary: Color(0xFFFFFFFF),
    shadow: Color(0xFF000000),
  );

  static const LoomPalette _dark = LoomPalette(
    background: Color(0xFF111318),
    surface: Color(0xFF1B1C21),
    surfaceMuted: Color(0xFF24252A),
    surfaceElevated: Color(0xFF2C2D32),
    textPrimary: Color(0xFFF2F5F8),
    textSecondary: Color(0xFFAAB4C1),
    textMuted: Color(0xFF94A2B4),
    border: Color(0x16FFFFFF),
    borderStrong: Color(0x2BFFFFFF),
    primary: Color(0xFFF4A28C),
    secondary: Color(0xFFD8B59A),
    connectivity: Color(0xFF45D0A5),
    warning: Color(0xFFD19A4A),
    critical: Color(0xFFD86672),
    info: Color(0xFFD4B6A8),
    onPrimary: Color(0xFF2B1710),
    shadow: Color(0xFF000000),
  );

  static const LoomPalette _oled = LoomPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF0B0B0D),
    surfaceMuted: Color(0xFF131315),
    surfaceElevated: Color(0xFF1C1C20),
    textPrimary: Color(0xFFF4F7FA),
    textSecondary: Color(0xFFA6B0BD),
    textMuted: Color(0xFF96A3B4),
    border: Color(0x18FFFFFF),
    borderStrong: Color(0x30FFFFFF),
    primary: Color(0xFFF4A28C),
    secondary: Color(0xFFD8B59A),
    connectivity: Color(0xFF45A99D),
    warning: Color(0xFFD19A4A),
    critical: Color(0xFFD86672),
    info: Color(0xFFD4B6A8),
    onPrimary: Color(0xFF2B1710),
    shadow: Color(0xFF000000),
  );

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
        secondary: p.secondary,
        surface: p.surface,
        error: p.critical,
      ),
    );
    return base.copyWith(
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
  }
}

extension LoomThemeContext on BuildContext {
  LoomPalette get loom =>
      Theme.of(this).extension<LoomPalette>() ??
      LoomTheme.light().extension<LoomPalette>()!;
}
