import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import '../../../app/appearance_preferences.dart';
import '../../../app/chat_wallpaper.dart';
import '../../../app/loom_strings.dart';
import 'chat_wallpaper_editor.dart';

class LoomAppearancePanel extends StatefulWidget {
  const LoomAppearancePanel({
    required this.mode,
    required this.quality,
    required this.onThemeChanged,
    required this.onQualityChanged,
    super.key,
  });
  final LoomThemeMode mode;
  final LoomGlassQuality quality;
  final ValueChanged<LoomThemeMode> onThemeChanged;
  final ValueChanged<LoomGlassQuality> onQualityChanged;

  @override
  State<LoomAppearancePanel> createState() => _LoomAppearancePanelState();
}

class _LoomAppearancePanelState extends State<LoomAppearancePanel>
    with SingleTickerProviderStateMixin {
  static const int _sectionCount = 7;
  static const int _staggerMs = 60;
  static const int _fadeMs = 280;
  static const int _entranceMs = _staggerMs * (_sectionCount - 1) + _fadeMs;

  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _entranceMs),
  );
  bool _played = false;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appearance = LoomAppearanceScope.maybeOf(context);
    _reduceMotion =
        LoomAccessibility.fromContext(context).reduceMotion ||
        appearance?.motion == LoomMotionPreference.reduced;
    _entrance.duration = _reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: _entranceMs);
    if (!_played) {
      _played = true;
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  /// Fade + 12 px rise, staggered 60 ms per section.
  Widget _entranceWrap(int index, Widget child) {
    if (_reduceMotion) return child;
    final animation = CurvedAnimation(
      parent: _entrance,
      curve: Interval(
        _staggerMs * index / _entranceMs,
        (_staggerMs * index + _fadeMs) / _entranceMs,
        curve: LoomMotion.standard,
      ),
    );
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, 12 * (1 - animation.value)),
        child: FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    Widget child, {
    String? detail,
  }) => LoomSettingsGroup(
    children: [
      Padding(
        padding: const EdgeInsets.all(LoomSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.loom.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: LoomSpacing.sm),
            child,
          ],
        ),
      ),
    ],
  );

  Widget _previewColumn(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _PreviewCard(),
      const SizedBox(height: LoomSpacing.xs),
      Text(
        tr(
          context,
          'Changes apply immediately. Text size follows your device.',
          'تغییرات فوراً اعمال می‌شوند. اندازهٔ متن طبق تنظیمات دستگاه است.',
        ),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );

  Widget _themeCards(BuildContext context) {
    const modes = LoomThemeMode.values;
    return Row(
      children: [
        for (var i = 0; i < modes.length; i++) ...[
          if (i > 0) const SizedBox(width: LoomSpacing.xs),
          Expanded(
            child: _ThemeModeCard(
              key: ValueKey('appearance-theme-${modes[i].name}'),
              mode: modes[i],
              selected: widget.mode == modes[i],
              onTap: () => widget.onThemeChanged(modes[i]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _accentSwatches(
    BuildContext context,
    LoomAppearanceScope? appearance,
  ) {
    final p = context.loom;
    return Wrap(
      spacing: LoomSpacing.xs,
      runSpacing: LoomSpacing.xs,
      children: [
        for (final option in <(int?, String)>[
          (null, tr(context, 'Default', 'پیش‌فرض')),
          (0xFF3B82F6, tr(context, 'Blue', 'آبی')),
          (0xFF8B5CF6, tr(context, 'Purple', 'بنفش')),
          (0xFF14B8A6, tr(context, 'Teal', 'سبزآبی')),
          (0xFFEC4899, tr(context, 'Pink', 'صورتی')),
          (0xFFF59E0B, tr(context, 'Amber', 'کهربایی')),
        ])
          _AccentSwatch(
            label: option.$2,
            color: option.$1 == null ? p.primary : Color(option.$1!),
            selected: appearance?.accent == option.$1,
            onTap: appearance?.onAccentChanged == null
                ? null
                : () => appearance!.onAccentChanged!(option.$1),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final appearance = LoomAppearanceScope.maybeOf(context);
    final sections = <Widget>[
      _entranceWrap(0, _previewColumn(context)),
      _entranceWrap(
        1,
        _section(context, tr(context, 'Theme', 'تم'), _themeCards(context)),
      ),
      _entranceWrap(
        2,
        _section(
          context,
          tr(context, 'Accent color', 'رنگ اصلی'),
          _accentSwatches(context, appearance),
        ),
      ),
      _entranceWrap(
        3,
        LoomSettingsGroup(
          children: [
            LoomSettingsRow(
              icon: LoomIcons.wallpaper_rounded,
              title: tr(context, 'Chat wallpaper', 'پس‌زمینهٔ گفتگوها'),
              subtitle: tr(
                context,
                'Photo, presets, dimming and blur',
                'عکس، الگو، تیرگی و تاری',
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LoomWallpaperEditor()),
              ),
            ),
          ],
        ),
      ),
      _entranceWrap(
        4,
        _section(
          context,
          tr(context, 'Chat layout', 'چیدمان گفتگو'),
          _LoomSegmented<LoomChatDensity>(
            segments: [
              (
                LoomChatDensity.comfortable,
                LoomIcons.chat_bubble_outline_rounded,
                tr(context, 'Comfortable', 'راحت'),
              ),
              (
                LoomChatDensity.compact,
                LoomIcons.chat_bubble_rounded,
                tr(context, 'Compact', 'فشرده'),
              ),
            ],
            value: appearance?.chatDensity ?? LoomChatDensity.comfortable,
            onChanged: appearance?.onChatDensityChanged,
          ),
        ),
      ),
      _entranceWrap(
        5,
        _section(
          context,
          tr(context, 'Motion', 'حرکت'),
          _LoomSegmented<LoomMotionPreference>(
            segments: [
              (
                LoomMotionPreference.system,
                LoomIcons.devices_outlined,
                tr(context, 'Follow system', 'طبق سیستم'),
              ),
              (
                LoomMotionPreference.full,
                LoomIcons.shuffle_rounded,
                tr(context, 'Full motion', 'انیمیشن کامل'),
              ),
              (
                LoomMotionPreference.reduced,
                LoomIcons.pause,
                tr(context, 'Reduced motion', 'حرکت کمتر'),
              ),
            ],
            value: appearance?.motion ?? LoomMotionPreference.system,
            onChanged: appearance?.onMotionChanged,
          ),
          detail: tr(
            context,
            'System reduced motion is always respected.',
            'حرکت کمتر در تنظیمات سیستم همیشه رعایت می‌شود.',
          ),
        ),
      ),
      _entranceWrap(
        6,
        _section(
          context,
          tr(context, 'Glass effects', 'جلوه‌های شیشه‌ای'),
          _LoomSegmented<LoomGlassQuality>(
            segments: [
              (
                LoomGlassQuality.high,
                LoomIcons.auto_awesome_rounded,
                tr(context, 'Full', 'کامل'),
              ),
              (
                LoomGlassQuality.reduced,
                LoomIcons.contrast_rounded,
                tr(context, 'Reduced', 'کمتر'),
              ),
              (
                LoomGlassQuality.disabled,
                LoomIcons.visibility_off_outlined,
                tr(context, 'Off', 'خاموش'),
              ),
            ],
            value: widget.quality,
            onChanged: widget.onQualityChanged,
          ),
          detail: tr(
            context,
            'Use reduced effects for smoother scrolling. Accessibility settings still apply.',
            'برای پیمایش روان‌تر، جلوه‌ها را کمتر کنید. تنظیمات دسترس‌پذیری همچنان رعایت می‌شوند.',
          ),
        ),
      ),
    ];
    final preview = sections.first;
    final groups = sections.sublist(1);
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in groups) ...[
          section,
          const SizedBox(height: LoomSpacing.md),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 680
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: preview),
                const SizedBox(width: LoomSpacing.lg),
                Expanded(flex: 3, child: controls),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                preview,
                const SizedBox(height: LoomSpacing.lg),
                controls,
              ],
            ),
    );
  }
}

/// Header + framed live wallpaper preview with rounded 20 corners.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard();

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
        boxShadow: [
          BoxShadow(
            color: p.shadow.withAlphaFraction(
              Theme.of(context).brightness == Brightness.dark
                  ? LoomOpacity.chromeShadowDark
                  : LoomOpacity.chromeShadowLight,
            ),
            blurRadius: LoomElevation.chromeBlur,
            offset: const Offset(0, LoomElevation.chromeOffset),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LoomSpacing.md,
              LoomSpacing.sm,
              LoomSpacing.md,
              LoomSpacing.xs,
            ),
            child: Row(
              children: [
                Icon(
                  LoomIcons.auto_awesome_rounded,
                  size: LoomIconSize.compact,
                  color: p.primary,
                ),
                const SizedBox(width: LoomSpacing.xs),
                Expanded(
                  child: Text(
                    tr(context, 'Preview', 'پیش‌نمایش'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: p.border),
          const ClipRRect(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(19)),
            child: LoomWallpaperBackdrop(
              child: LoomAppearancePreviewMessages(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Miniature chat rendered with the palette of one theme mode.
class _ThemeMockPalette {
  const _ThemeMockPalette({
    required this.canvas,
    required this.chrome,
    required this.line,
    required this.outgoing,
    required this.onOutgoing,
  });
  final Color canvas;
  final Color chrome;
  final Color line;
  final Color outgoing;
  final Color onOutgoing;

  static const light = _ThemeMockPalette(
    canvas: Color(0xFFF6F1EC),
    chrome: Color(0xFFFFFFFF),
    line: Color(0xFFE2D8CF),
    outgoing: Color(0xFFA03D28),
    onOutgoing: Color(0x9CFFFFFF),
  );
  static const dark = _ThemeMockPalette(
    canvas: Color(0xFF0F1115),
    chrome: Color(0xFF20222A),
    line: Color(0xFF39414E),
    outgoing: Color(0xFFF5A089),
    onOutgoing: Color(0x8C301409),
  );
  static const oled = _ThemeMockPalette(
    canvas: Color(0xFF000000),
    chrome: Color(0xFF121216),
    line: Color(0xFF2A2A31),
    outgoing: Color(0xFFF5A089),
    onOutgoing: Color(0x8C301409),
  );
}

class _ThemeModeCard extends StatelessWidget {
  const _ThemeModeCard({
    required this.mode,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final LoomThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  static const _mockPalettes = <LoomThemeMode, _ThemeMockPalette>{
    LoomThemeMode.light: _ThemeMockPalette.light,
    LoomThemeMode.dark: _ThemeMockPalette.dark,
    LoomThemeMode.oled: _ThemeMockPalette.oled,
  };

  Widget _bubble({
    required Color fill,
    required Color ink,
    required List<double> widths,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widths.length; i++) ...[
          if (i > 0) const SizedBox(height: 3),
          Container(
            width: widths[i],
            height: 4,
            decoration: BoxDecoration(
              color: ink,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _mock(_ThemeMockPalette palette) => ClipRRect(
    borderRadius: BorderRadius.circular(LoomRadii.compact),
    child: ColoredBox(
      color: palette.canvas,
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 14,
              alignment: AlignmentDirectional.centerStart,
              padding: const EdgeInsetsDirectional.only(start: 5),
              decoration: BoxDecoration(
                color: palette.chrome,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: palette.outgoing,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    width: 24,
                    height: 3,
                    decoration: BoxDecoration(
                      color: palette.line,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: _bubble(
                fill: palette.chrome,
                ink: palette.line,
                widths: const [34, 22],
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _bubble(
                fill: palette.outgoing,
                ink: palette.onOutgoing,
                widths: const [28],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    const radius = BorderRadius.all(Radius.circular(16));
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: LoomMotion.component,
        curve: LoomMotion.standard,
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: radius,
          border: Border.all(
            color: selected ? p.primary : p.border,
            width: selected ? 2 : 1,
          ),
          // Subtle lift for the selected card only.
          boxShadow: [
            BoxShadow(
              color: p.shadow.withAlphaFraction(selected ? .12 : .05),
              blurRadius: selected ? 12 : 6,
              offset: Offset(0, selected ? 4 : 2),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Column(
                children: [
                  Stack(
                    children: [
                      _mock(_mockPalettes[mode]!),
                      PositionedDirectional(
                        top: 12,
                        end: 12,
                        child: AnimatedContainer(
                          duration: LoomMotion.component,
                          curve: LoomMotion.standard,
                          width: 18,
                          height: 18,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected ? p.primary : p.surface,
                            border: Border.all(
                              color: selected ? p.primary : p.textMuted,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: selected
                              ? Icon(
                                  LoomIcons.check,
                                  size: 12,
                                  color: p.onPrimary,
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    switch (mode) {
                      LoomThemeMode.light => tr(context, 'Light', 'روشن'),
                      LoomThemeMode.dark => tr(context, 'Dark', 'تاریک'),
                      LoomThemeMode.oled => 'OLED',
                    },
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: selected ? p.primary : p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 40 px colour dot with a 2 px offset ring and a white check when selected.
class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.label,
    required this.color,
    required this.selected,
    this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: label,
      child: AnimatedContainer(
        duration: LoomMotion.component,
        curve: LoomMotion.standard,
        width: 48,
        height: 48,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? color : Colors.transparent,
            width: 2,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: AnimatedContainer(
              duration: LoomMotion.component,
              curve: LoomMotion.standard,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              alignment: Alignment.center,
              child: selected
                  ? const Icon(LoomIcons.check, size: 18, color: Colors.white)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Segmented control with an icon + label per segment; the active segment
/// lifts onto the surface colour with a soft shadow.
class _LoomSegmented<T> extends StatelessWidget {
  const _LoomSegmented({
    required this.segments,
    required this.value,
    this.onChanged,
  });

  final List<(T, IconData, String)> segments;
  final T value;
  final ValueChanged<T>? onChanged;

  Widget _segment(BuildContext context, (T, IconData, String) segment) {
    final p = context.loom;
    final selected = segment.$1 == value;
    return Semantics(
      button: onChanged != null,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(LoomRadii.control - 3),
          onTap: onChanged == null ? null : () => onChanged!(segment.$1),
          child: AnimatedContainer(
            duration: LoomMotion.component,
            curve: LoomMotion.standard,
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
            decoration: BoxDecoration(
              color: selected ? p.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(LoomRadii.control - 3),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: p.shadow.withAlphaFraction(.08),
                        blurRadius: 5,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : const <BoxShadow>[],
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      segment.$2,
                      size: 15,
                      color: selected ? p.primary : p.textMuted,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      segment.$3,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: selected ? p.textPrimary : p.textSecondary,
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
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.surfaceMuted,
        borderRadius: BorderRadius.circular(LoomRadii.control),
      ),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(child: _segment(context, segments[i])),
          ],
        ],
      ),
    );
  }
}
