import 'package:loom_design/loom_design.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../app/loom_strings.dart';
import 'appearance_panel.dart';
import '../../calls/application/call_platform_bridge.dart';
import '../../notifications/application/message_notifications.dart';
import '../../messaging/presentation/local_message_cleanup_screen.dart';
import '../../security/presentation/app_lock_gate.dart';

enum LoomSettingsSection {
  privacy,
  notifications,
  storage,
  appearance,
  nearby,
  federation,
  calls,
  language,
  advanced,
  about,
  sharedMedia,
}

class LoomSettingsDetailScreen extends StatefulWidget {
  const LoomSettingsDetailScreen({
    required this.section,
    required this.themeMode,
    required this.glassQuality,
    required this.locale,
    required this.onThemeChanged,
    required this.onGlassQualityChanged,
    required this.onLocaleChanged,
    super.key,
  });

  final LoomSettingsSection section;
  final LoomThemeMode themeMode;
  final LoomGlassQuality glassQuality;
  final Locale locale;
  final ValueChanged<LoomThemeMode> onThemeChanged;
  final ValueChanged<LoomGlassQuality> onGlassQualityChanged;
  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<LoomSettingsDetailScreen> createState() =>
      _LoomSettingsDetailScreenState();
}

class _LoomSettingsDetailScreenState
    extends State<LoomSettingsDetailScreen> {
  late LoomThemeMode themeMode;
  late LoomGlassQuality glassQuality;
  late Locale locale;
  Future<PackageInfo>? _installedPackage;

  LoomSettingsSection get section => widget.section;

  @override
  void initState() {
    super.initState();
    themeMode = widget.themeMode;
    glassQuality = widget.glassQuality;
    locale = widget.locale;
  }

  void onThemeChanged(LoomThemeMode value) {
    setState(() => themeMode = value);
    widget.onThemeChanged(value);
  }

  void onGlassQualityChanged(LoomGlassQuality value) {
    setState(() => glassQuality = value);
    widget.onGlassQualityChanged(value);
  }

  void onLocaleChanged(Locale value) {
    setState(() => locale = value);
    widget.onLocaleChanged(value);
  }

  String _title(BuildContext context) => switch (section) {
    LoomSettingsSection.privacy => tr(context, 'Privacy', 'حریم خصوصی'),
    LoomSettingsSection.notifications =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
          ? tr(
              context,
              'Incoming calls appear in Loom while the app is running. Calls cannot arrive while the app is fully closed.',
              'تماس‌های ورودی هنگام اجرای برنامه داخل لوم نمایش داده می‌شوند. هنگام بسته بودن کامل برنامه تماس دریافت نمی‌شود.',
            )
          : tr(context, 'Notifications', 'اعلان‌ها'),
    LoomSettingsSection.storage => tr(
      context,
      'Data & Storage',
      'داده و ذخیره‌سازی',
    ),
    LoomSettingsSection.appearance => tr(context, 'Appearance', 'ظاهر'),
    LoomSettingsSection.nearby => tr(context, 'Nearby', 'نزدیک'),
    LoomSettingsSection.federation => tr(context, 'Federation', 'فدراسیون'),
    LoomSettingsSection.calls => tr(context, 'Calls', 'تماس‌ها'),
    LoomSettingsSection.language => tr(context, 'Language', 'زبان'),
    LoomSettingsSection.advanced => tr(context, 'Advanced', 'پیشرفته'),
    LoomSettingsSection.about => tr(context, 'About Loom', 'درباره لوم'),
    LoomSettingsSection.sharedMedia => tr(
      context,
      'Shared media',
      'رسانه‌های مشترک',
    ),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LoomGlassAppBar(title: Text(_title(context))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              LoomSpacing.md,
              LoomSpacing.sm,
              LoomSpacing.md,
              LoomSpacing.xl,
            ),
            children: [
              ..._groupedContent(context),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _Notice(_summary(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _groupedContent(BuildContext context) {
    final result = <Widget>[];
    var rows = <Widget>[];
    void flush() {
      if (rows.isEmpty) return;
      result.add(
        LoomSettingsGroup(
          children: [
            for (var index = 0; index < rows.length; index++) ...[
              rows[index],
              if (index < rows.length - 1)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 62),
                  child: Divider(height: 1, color: context.loom.border),
                ),
            ],
          ],
        ),
      );
      rows = <Widget>[];
    }

    for (final child in _content(context)) {
      if (child is _StatusRow ||
          child is _ChoiceRow ||
          child is _ValueRow ||
          child is LoomSettingsRow) {
        rows.add(child);
      } else {
        flush();
        result.add(child);
      }
    }
    flush();
    return result;
  }

  String _summary(BuildContext context) => switch (section) {
    LoomSettingsSection.privacy => tr(
      context,
      'Protect access to Loom with your device lock. Direct messages are encrypted before they leave your device.',
      'با قفل دستگاه، از ورود به لوم محافظت کنید. پیام‌های مستقیم پیش از خروج از دستگاه رمزگذاری می‌شوند.',
    ),
    LoomSettingsSection.notifications => tr(
      context,
      'Message and call notifications work while Loom is running. Choose Android sounds, vibration and visibility in system settings. Delivery with the app fully closed still requires Push.',
      'اعلان پیام و تماس هنگام اجرای لوم نمایش داده می‌شود. صدا، لرزش و نمایش اندروید را در تنظیمات سیستم انتخاب کنید. دریافت با برنامهٔ کاملاً بسته هنوز به Push نیاز دارد.',
    ),
    LoomSettingsSection.storage => tr(
      context,
      'Manage messages saved on this device. Local cleanup does not remove messages from another device.',
      'پیام‌های ذخیره‌شده روی این دستگاه را مدیریت کنید. پاک‌سازی محلی پیام‌ها را از دستگاه دیگر حذف نمی‌کند.',
    ),
    LoomSettingsSection.appearance => tr(
      context,
      'Your theme and visual effects are saved on this device.',
      'تم و جلوه‌های تصویری روی همین دستگاه ذخیره می‌شوند.',
    ),
    LoomSettingsSection.nearby => tr(
      context,
      'Use Nearby messaging to exchange encrypted messages over supported Bluetooth and Wi-Fi links.',
      'با پیام‌رسانی نزدیک، پیام‌های رمزگذاری‌شده را از مسیرهای پشتیبانی‌شدهٔ بلوتوث و وای‌فای جابه‌جا کنید.',
    ),
    LoomSettingsSection.federation => tr(
      context,
      'Internet federation is experimental and is accepted only through a trusted HTTPS endpoint. Cleartext IP federation is rejected.',
      'فدراسیون اینترنتی فعال است و فقط از endpoint معتبر HTTPS پذیرفته می‌شود. فدراسیون HTTP روی IP رد می‌شود.',
    ),
    LoomSettingsSection.calls => tr(
      context,
      'Make audio and video calls. Android and Windows play waiting and incoming-call tones. Calls require a working Home Node RTC connection.',
      'تماس صوتی و تصویری برقرار کنید. اندروید و ویندوز بوق انتظار و زنگ تماس ورودی دارند. تماس به اتصال RTC فعال روی Home Node نیاز دارد.',
    ),
    LoomSettingsSection.language => tr(
      context,
      'English and Persian are available. Layout direction changes immediately with the selected language.',
      'انگلیسی و فارسی در دسترس‌اند. جهت چیدمان با انتخاب زبان بلافاصله تغییر می‌کند.',
    ),
    LoomSettingsSection.advanced => tr(
      context,
      'Manage your connection and inspect Nearby status.',
      'اتصال خود را مدیریت و وضعیت پیام‌رسانی نزدیک را بررسی کنید.',
    ),
    LoomSettingsSection.about => tr(
      context,
      'Loom is a privacy-focused, resilient communication project currently in pre-alpha development.',
      'لوم یک پروژه ارتباطی مقاوم و حریم‌خصوصی‌محور است که اکنون در مرحله پیش‌آلفا قرار دارد.',
    ),
    LoomSettingsSection.sharedMedia => tr(
      context,
      'Shared-media indexing is not connected. No placeholder gallery is presented as real conversation data.',
      'فهرست‌سازی رسانه‌های مشترک متصل نیست و گالری نمایشی به‌عنوان داده واقعی گفتگو نشان داده نمی‌شود.',
    ),
  };

  List<Widget> _content(BuildContext context) => switch (section) {
    LoomSettingsSection.appearance => _appearance(context),
    LoomSettingsSection.language => _language(context),
    LoomSettingsSection.federation => _federation(context),
    LoomSettingsSection.calls => _calls(context),
    LoomSettingsSection.privacy => _privacy(context),
    LoomSettingsSection.notifications => _notifications(context),
    LoomSettingsSection.storage => _storage(context),
    LoomSettingsSection.nearby => _nearby(context),
    LoomSettingsSection.advanced => _advanced(context),
    LoomSettingsSection.about => _about(context),
    LoomSettingsSection.sharedMedia => _sharedMedia(context),
  };

  List<Widget> _appearance(BuildContext context) => [
    LoomAppearancePanel(
      mode: themeMode,
      quality: glassQuality,
      onThemeChanged: onThemeChanged,
      onQualityChanged: onGlassQualityChanged,
    ),
  ];

  List<Widget> _language(BuildContext context) => [
    _ChoiceRow(
      title: 'English',
      subtitle: 'Left-to-right',
      selected: locale.languageCode == 'en',
      onTap: () => onLocaleChanged(const Locale('en')),
    ),
    _ChoiceRow(
      title: 'فارسی',
      subtitle: 'راست‌به‌چپ',
      selected: locale.languageCode == 'fa',
      onTap: () => onLocaleChanged(const Locale('fa')),
    ),
  ];

  List<Widget> _federation(BuildContext context) => [
    _StatusRow(
      icon: LoomIcons.https_rounded,
      title: tr(context, 'Trusted HTTPS', 'HTTPS معتبر'),
      value: tr(context, 'Required', 'الزامی'),
    ),
    _StatusRow(
      icon: LoomIcons.http_rounded,
      title: tr(context, 'Cleartext IP federation', 'فدراسیون HTTP روی IP'),
      value: tr(context, 'Rejected', 'رد می‌شود'),
    ),
    _StatusRow(
      icon: LoomIcons.science_outlined,
      title: tr(context, 'Production validation', 'اعتبارسنجی تولید'),
      value: tr(context, 'Not complete', 'کامل نیست'),
    ),
    const SizedBox(height: LoomSpacing.md),
    FilledButton.icon(
      onPressed: () => Navigator.pushNamed(context, '/nodes'),
      icon: const Icon(LoomIcons.dns_outlined),
      label: Text(tr(context, 'Open Node directory', 'باز کردن فهرست Node')),
    ),
  ];

  List<Widget> _calls(BuildContext context) => [
    _StatusRow(
      icon: LoomIcons.person_outline_rounded,
      title: tr(context, 'One-to-one calls', 'تماس یک‌به‌یک'),
      value: tr(context, 'Available', 'فعال'),
    ),
    _StatusRow(
      icon: LoomIcons.groups_outlined,
      title: tr(context, 'Group calls and SFU', 'تماس گروهی و SFU'),
      value: tr(context, 'Planned', 'برنامه‌ریزی‌شده'),
    ),
    const SizedBox(height: LoomSpacing.md),
    FilledButton.icon(
      onPressed: () => Navigator.pushNamed(context, '/calls'),
      icon: const Icon(LoomIcons.call_outlined),
      label: Text(tr(context, 'Open call history', 'باز کردن سابقه تماس')),
    ),
  ];

  List<Widget> _privacy(BuildContext context) => [
    const LoomAppLockSettings(),
    const SizedBox(height: 16),
    _StatusRow(
      icon: LoomIcons.analytics_outlined,
      title: tr(context, 'Usage analytics', 'تحلیل رفتار'),
      value: tr(context, 'Not included', 'وجود ندارد'),
    ),
    _StatusRow(
      icon: LoomIcons.ad_units_outlined,
      title: tr(context, 'Advertising', 'تبلیغات'),
      value: tr(context, 'Not included', 'وجود ندارد'),
    ),
    _StatusRow(
      icon: LoomIcons.lock_outline_rounded,
      title: tr(context, 'Direct messages', 'پیام‌های مستقیم'),
      value: tr(
        context,
        'Encrypted direct messages',
        'گفتگوهای مستقیم رمزنگاری‌شده',
      ),
    ),
  ];

  List<Widget> _notifications(BuildContext context) => [
    _SectionTitle(tr(context, 'Messages', 'پیام‌ها')),
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.windows)) ...[
      LoomSettingsRow(
        icon: LoomIcons.notifications_none_rounded,
        title: tr(
          context,
          'Enable message notifications',
          'فعال‌کردن اعلان پیام',
        ),
        subtitle: tr(
          context,
          'Encrypted preview; respects muted and open chats',
          'پیش‌نمایش خصوصی؛ با رعایت سکوت و چت باز',
        ),
        onTap: () async {
          try {
            final bridge = LoomMessageNotificationBridge();
            await bridge.enable();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  tr(
                    context,
                    'Allow notifications in the system prompt or settings.',
                    'اعلان‌ها را در درخواست سیستم یا تنظیمات مجاز کنید.',
                  ),
                ),
              ),
            );
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    tr(
                      context,
                      'System notifications are unavailable.',
                      'اعلان سیستم در دسترس نیست.',
                    ),
                  ),
                ),
              );
            }
          }
        },
      ),
      LoomSettingsRow(
        icon: LoomIcons.settings_outlined,
        title: tr(
          context,
          'System notification settings',
          'تنظیمات اعلان سیستم',
        ),
        showDivider: false,
        onTap: () => LoomMessageNotificationBridge().settings(),
      ),
    ],
    const SizedBox(height: 24),
    _SectionTitle(tr(context, 'Calls', 'تماس‌ها')),
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
      LoomSettingsRow(
        icon: LoomIcons.notifications_none_rounded,
        title: tr(context, 'Incoming call notifications', 'اعلان تماس ورودی'),
        subtitle: tr(
          context,
          'Ringtone, vibration and visibility',
          'صدای زنگ، لرزش و نمایش',
        ),
        showDivider: false,
        onTap: () => const LoomCallPlatformSettings().openIncomingSettings(),
      ),
    _StatusRow(
      icon: LoomIcons.call_outlined,
      title: tr(context, 'Outgoing waiting tone', 'بوق انتظار تماس خروجی'),
      value:
          !kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.windows)
          ? tr(context, 'Enabled', 'فعال')
          : tr(
              context,
              'Unavailable on this platform',
              'روی این پلتفرم در دسترس نیست',
            ),
    ),
    const SizedBox(height: 24),
    _SectionTitle(
      tr(context, 'When the app is closed', 'هنگام بسته‌بودن برنامه'),
    ),
    _StatusRow(
      icon: LoomIcons.notifications_off_outlined,
      title: tr(context, 'Push messages and calls', 'پیام و تماس از طریق Push'),
      value: tr(context, 'Not available yet', 'هنوز فعال نیست'),
    ),
  ];

  List<Widget> _storage(BuildContext context) => [
    _SectionTitle(tr(context, 'On this device', 'روی این دستگاه')),
    LoomSettingsRow(
      icon: LoomIcons.cleaning_services_outlined,
      title: tr(context, 'Manage local messages', 'مدیریت پیام‌های محلی'),
      subtitle: tr(
        context,
        'Review and remove local history',
        'بررسی و حذف تاریخچهٔ محلی',
      ),
      showDivider: false,
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const LoomLocalMessageCleanupScreen(),
        ),
      ),
    ),
  ];

  List<Widget> _nearby(BuildContext context) => [
    LoomSettingsRow(
      icon: LoomIcons.near_me_outlined,
      title: tr(context, 'Nearby messaging', 'پیام‌رسانی نزدیک'),
      subtitle: tr(
        context,
        'Bluetooth and Wi-Fi links',
        'مسیرهای بلوتوث و وای‌فای',
      ),
      showDivider: false,
      onTap: () => Navigator.pushNamed(context, '/settings/nearby'),
    ),
  ];

  List<Widget> _advanced(BuildContext context) => [
    LoomSettingsRow(
      icon: LoomIcons.dns_outlined,
      title: tr(context, 'Node directory', 'فهرست Node'),
      subtitle: tr(
        context,
        'Inspect or enter a Node endpoint manually',
        'بررسی یا ورود دستی endpoint یک Node',
      ),
      showDivider: false,
      onTap: () => Navigator.pushNamed(context, '/nodes'),
    ),
    LoomSettingsRow(
      icon: LoomIcons.fingerprint_rounded,
      title: tr(context, 'Security diagnostics', 'عیب‌یابی امنیت'),
      subtitle: tr(
        context,
        'Inspect local identity and device fingerprints',
        'بررسی اثرانگشت هویت و دستگاه محلی',
      ),
      showDivider: false,
      onTap: () => Navigator.pushNamed(context, '/security'),
    ),
  ];

  List<Widget> _about(BuildContext context) => [
    _ValueRow(label: tr(context, 'License', 'مجوز'), value: 'GPLv3'),
    TextButton(
      onPressed: () => showLicensePage(
        context: context,
        applicationName: tr(context, 'Loom', 'لوم'),
      ),
      child: Text(tr(context, 'Licenses and attribution', 'مجوزها و انتساب')),
    ),
    LoomGlassSurface(
      liveBackdrop: true,
      padding: const EdgeInsets.all(LoomSpacing.md),
      child: FutureBuilder<PackageInfo>(
        // Read the installed native package, including --build-name/number
        // overrides. Never substitute a source constant for an unknown build.
        future: _installedPackage ??= PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    context,
                    'Could not read the installed app version.',
                    'خواندن نسخهٔ نصب‌شدهٔ برنامه ممکن نشد.',
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _installedPackage = PackageInfo.fromPlatform();
                  }),
                  child: Text(tr(context, 'Retry', 'تلاش دوباره')),
                ),
              ],
            );
          }
          final info = snapshot.data;
          if (info == null) {
            return LinearProgressIndicator(
              semanticsLabel: tr(
                context,
                'Reading installed version',
                'در حال خواندن نسخهٔ نصب‌شده',
              ),
            );
          }
          final version = info.version.isEmpty ? '—' : info.version;
          final build = info.buildNumber.isEmpty ? '—' : info.buildNumber;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ValueRow(label: tr(context, 'Version', 'نسخه'), value: version),
              _ValueRow(
                label: tr(context, 'Build number', 'شمارهٔ بیلد'),
                value: build,
              ),
              _ValueRow(
                label: tr(context, 'Package version', 'نسخهٔ پکیج'),
                value: info.version.isEmpty
                    ? '—'
                    : info.buildNumber.isEmpty
                    ? info.version
                    : '${info.version}+${info.buildNumber}',
              ),
              _ValueRow(
                label: tr(context, 'Application ID', 'شناسهٔ برنامه'),
                value: info.packageName.isEmpty ? '—' : info.packageName,
              ),
            ],
          );
        },
      ),
    ),
    const SizedBox(height: LoomSpacing.md),
    _ValueRow(
      label: tr(context, 'Status', 'وضعیت'),
      value: tr(context, 'Pre-alpha', 'پیش‌آلفا'),
    ),
    const SizedBox(height: LoomSpacing.md),
    _Notice(
      tr(
        context,
        'These numbers identify the app installed on this device. Include the package version when reporting a problem.',
        'این شماره‌ها مربوط به برنامهٔ نصب‌شده روی همین دستگاه‌اند. هنگام گزارش مشکل، نسخهٔ پکیج را هم ارسال کنید.',
      ),
    ),
  ];

  List<Widget> _sharedMedia(BuildContext context) => [
    _StatusRow(
      icon: LoomIcons.photo_library_outlined,
      title: tr(context, 'Media index', 'فهرست رسانه'),
      value: tr(context, 'Not connected', 'متصل نیست'),
    ),
    _StatusRow(
      icon: LoomIcons.folder_outlined,
      title: tr(context, 'File index', 'فهرست فایل'),
      value: tr(context, 'Not connected', 'متصل نیست'),
    ),
    _StatusRow(
      icon: LoomIcons.link_outlined,
      title: tr(context, 'Link index', 'فهرست پیوند'),
      value: tr(context, 'Not connected', 'متصل نیست'),
    ),
  ];
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 10),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(color: context.loom.primary),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: context.loom.textSecondary),
  );
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => LoomSettingsRow(
    icon: LoomIcons.translate_rounded,
    title: title,
    subtitle: subtitle.isEmpty ? null : subtitle,
    showDivider: false,
    trailing: selected
        ? Icon(LoomIcons.check_circle_rounded, color: context.loom.primary)
        : const Icon(LoomIcons.circle_outlined),
    onTap: onTap,
  );
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return LoomSettingsRow(
      icon: icon,
      title: title,
      subtitle: value,
      showDivider: false,
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: LoomSpacing.md),
        Flexible(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SelectableText(value, textAlign: TextAlign.end),
          ),
        ),
      ],
    ),
  );
}
