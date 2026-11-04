import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import '../../../app/appearance_preferences.dart';
import '../../../app/chat_wallpaper.dart';
import '../../../app/loom_strings.dart';
import 'chat_wallpaper_editor.dart';

class LoomAppearancePanel extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final appearance = LoomAppearanceScope.maybeOf(context);
    final preview = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr(context, 'Your conversation', 'گفتگوی شما'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: LoomSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(LoomRadii.surface),
          child: const LoomWallpaperBackdrop(
            child: LoomAppearancePreviewMessages(),
          ),
        ),
        const SizedBox(height: LoomSpacing.sm),
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
    final sections = <Widget>[
      _section(
        context,
        tr(context, 'Theme', 'تم'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in LoomThemeMode.values)
              ChoiceChip(
                key: ValueKey('appearance-theme-${value.name}'),
                label: Text(switch (value) {
                  LoomThemeMode.light => tr(context, 'Light', 'روشن'),
                  LoomThemeMode.dark => tr(context, 'Dark', 'تاریک'),
                  LoomThemeMode.oled => 'OLED',
                }),
                selected: mode == value,
                onSelected: (_) => onThemeChanged(value),
              ),
          ],
        ),
      ),
      _section(
        context,
        tr(context, 'Accent color', 'رنگ اصلی'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in <(int?, String)>[
              (null, tr(context, 'Default', 'پیش‌فرض')),
              (0xFF3B82F6, tr(context, 'Blue', 'آبی')),
              (0xFF8B5CF6, tr(context, 'Purple', 'بنفش')),
              (0xFF14B8A6, tr(context, 'Teal', 'سبزآبی')),
              (0xFFEC4899, tr(context, 'Pink', 'صورتی')),
              (0xFFF59E0B, tr(context, 'Amber', 'کهربایی')),
            ])
              ChoiceChip(
                label: Text(option.$2),
                avatar: CircleAvatar(
                  radius: 8,
                  backgroundColor: option.$1 == null
                      ? context.loom.primary
                      : Color(option.$1!),
                ),
                selected: appearance?.accent == option.$1,
                onSelected: appearance?.onAccentChanged == null
                    ? null
                    : (_) => appearance!.onAccentChanged!(option.$1),
              ),
          ],
        ),
      ),
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
      _section(
        context,
        tr(context, 'Chat layout', 'چیدمان گفتگو'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in LoomChatDensity.values)
              ChoiceChip(
                label: Text(
                  value == LoomChatDensity.comfortable
                      ? tr(context, 'Comfortable', 'راحت')
                      : tr(context, 'Compact', 'فشرده'),
                ),
                selected:
                    (appearance?.chatDensity ?? LoomChatDensity.comfortable) ==
                    value,
                onSelected: appearance?.onChatDensityChanged == null
                    ? null
                    : (_) => appearance!.onChatDensityChanged!(value),
              ),
          ],
        ),
      ),
      _section(
        context,
        tr(context, 'Motion', 'حرکت'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in LoomMotionPreference.values)
              ChoiceChip(
                label: Text(switch (value) {
                  LoomMotionPreference.system => tr(
                    context,
                    'Follow system',
                    'طبق سیستم',
                  ),
                  LoomMotionPreference.full => tr(
                    context,
                    'Full motion',
                    'انیمیشن کامل',
                  ),
                  LoomMotionPreference.reduced => tr(
                    context,
                    'Reduced motion',
                    'حرکت کمتر',
                  ),
                }),
                selected:
                    (appearance?.motion ?? LoomMotionPreference.system) ==
                    value,
                onSelected: appearance?.onMotionChanged == null
                    ? null
                    : (_) => appearance!.onMotionChanged!(value),
              ),
          ],
        ),
        detail: tr(
          context,
          'System reduced motion is always respected.',
          'حرکت کمتر در تنظیمات سیستم همیشه رعایت می‌شود.',
        ),
      ),
      _section(
        context,
        tr(context, 'Glass effects', 'جلوه‌های شیشه‌ای'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in LoomGlassQuality.values)
              ChoiceChip(
                label: Text(switch (value) {
                  LoomGlassQuality.high => tr(context, 'Full', 'کامل'),
                  LoomGlassQuality.reduced => tr(context, 'Reduced', 'کمتر'),
                  LoomGlassQuality.disabled => tr(context, 'Off', 'خاموش'),
                }),
                selected: quality == value,
                onSelected: (_) => onQualityChanged(value),
              ),
          ],
        ),
        detail: tr(
          context,
          'Use reduced effects for smoother scrolling. Accessibility settings still apply.',
          'برای پیمایش روان‌تر، جلوه‌ها را کمتر کنید. تنظیمات دسترس‌پذیری همچنان رعایت می‌شوند.',
        ),
      ),
    ];
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in sections) ...[
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
