import 'dart:async';
import 'dart:io';

import '../../../app/release_metadata.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/loom_strings.dart';
import 'appearance_panel.dart';
import '../../accounts/application/account_workspace.dart';
import '../../calls/application/call_platform_bridge.dart';
import '../../notifications/application/message_notifications.dart';
import '../../notifications/application/notification_preferences.dart';
import '../../messaging/presentation/local_message_cleanup_screen.dart';
import '../../messaging/application/messaging_session_controller.dart';
import '../../security/application/db_encryption.dart';
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
    required this.localePreference,
    required this.onThemeChanged,
    required this.onGlassQualityChanged,
    required this.onLocaleChanged,
    super.key,
  });

  final LoomSettingsSection section;
  final LoomThemeMode themeMode;
  final LoomGlassQuality glassQuality;
  final Locale locale;

  /// The persisted choice: 'en', 'fa' or 'sys' (follow the OS).
  final String localePreference;
  final ValueChanged<LoomThemeMode> onThemeChanged;
  final ValueChanged<LoomGlassQuality> onGlassQualityChanged;
  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<LoomSettingsDetailScreen> createState() =>
      _LoomSettingsDetailScreenState();
}

class _LoomSettingsDetailScreenState extends State<LoomSettingsDetailScreen> {
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

  @override
  void didUpdateWidget(covariant LoomSettingsDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Appearance can also change from Design Lab or onboarding surfaces;
    // mirror the parent state instead of rendering a stale copy.
    if (oldWidget.themeMode != widget.themeMode) {
      themeMode = widget.themeMode;
    }
    if (oldWidget.glassQuality != widget.glassQuality) {
      glassQuality = widget.glassQuality;
    }
    if (oldWidget.locale != widget.locale) {
      locale = widget.locale;
    }
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
      'Loom is a privacy-focused, resilient communication project currently in $loomReleaseChannel development.',
      'لوم یک پروژه ارتباطی مقاوم و حریم‌خصوصی‌محور است که اکنون در مرحله آلفا قرار دارد.',
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
      title: tr(context, 'System default', 'پیش‌فرض سیستم'),
      subtitle: tr(
        context,
        'Follow the device language (Persian or English)',
        'از زبان دستگاه پیروی کن (فارسی یا انگلیسی)',
      ),
      selected: widget.localePreference == 'sys',
      onTap: () => onLocaleChanged(const Locale('sys')),
    ),
    _ChoiceRow(
      title: 'English',
      subtitle: 'Left-to-right',
      selected: widget.localePreference == 'en',
      onTap: () => onLocaleChanged(const Locale('en')),
    ),
    _ChoiceRow(
      title: 'فارسی',
      subtitle: 'راست‌به‌چپ',
      selected: widget.localePreference == 'fa',
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
    const _LocalSearchToggle(),
    const SizedBox(height: 16),
    const _BlockedContactsCard(),
    const SizedBox(height: 16),
    LoomSettingsRow(
      icon: LoomIcons.person_outline,
      title: tr(context, 'Accounts', 'حساب‌ها'),
      subtitle: tr(
        context,
        'Switch or add accounts on this device',
        'تغییر یا افزودن حساب‌ها روی این دستگاه',
      ),
      onTap: () => Navigator.pushNamed(context, '/settings/accounts'),
    ),
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
      const _MessageNotificationToggle(),
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
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
      const _StayConnectedToggle(),
      _StatusRow(
        icon: LoomIcons.notifications_off_outlined,
        title: tr(context, 'Push messages and calls', 'پیام و تماس از طریق Push'),
        value: tr(context, 'Not available yet', 'هنوز فعال نیست'),
      ),
    ] else
      _StatusRow(
        icon: LoomIcons.notifications_off_outlined,
        title: tr(context, 'Push messages and calls', 'پیام و تماس از طریق Push'),
        value: tr(context, 'Not available yet', 'هنوز فعال نیست'),
      ),
  ];

  List<Widget> _storage(BuildContext context) => [
    const _StorageUsageCard(),
    _SectionTitle(tr(context, 'On this device', 'روی این دستگاه')),
    const _DbEncryptionStatusRow(),
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

  List<Widget> _about(BuildContext context) {
    final p = context.loom;
    return [
      // ── Brand hero ──────────────────────────────────────────────────────
      LoomSettingsCard(
        child: Column(
          children: [
            const SizedBox(height: LoomSpacing.sm),
            const LoomBrandMark(size: 76),
            const SizedBox(height: LoomSpacing.md),
            Text(
              tr(context, 'Loom', 'لوم'),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -.3,
              ),
            ),
            const SizedBox(height: LoomSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: p.primary.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: p.primary.withValues(alpha: .25),
                    ),
                  ),
                  child: Text(
                    'v$loomReleaseVersion',
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: p.warning.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: p.warning.withValues(alpha: .25),
                    ),
                  ),
                  child: Text(
                    tr(context, loomReleaseChannel, 'آلفا'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.warning,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: LoomSpacing.md),
            Text(
              tr(
                context,
                'Private, resilient communication you can host yourself.',
                'ارتباط خصوصی و مقاوم که خودتان می‌توانید میزبانی کنید.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: p.textSecondary, fontSize: 13.5),
            ),
            const SizedBox(height: LoomSpacing.sm),
          ],
        ),
      ),
      const SizedBox(height: LoomSpacing.lg),

      // ── Highlights ─────────────────────────────────────────────────────
      _SectionTitle(tr(context, 'Why Loom', 'چرا لوم')),
      _StatusRow(
        icon: LoomIcons.https_rounded,
        title: tr(context, 'End-to-end encryption', 'رمزنگاری سرتاسری'),
        value: tr(
          context,
          'Messages and calls, before they leave your device',
          'پیام‌ها و تماس‌ها، پیش از خروج از دستگاه',
        ),
      ),
      _StatusRow(
        icon: LoomIcons.dns_outlined,
        title: tr(context, 'Your own server', 'سرور خودتان'),
        value: tr(
          context,
          'Community nodes, or host one yourself',
          'نودهای اجتماعی، یا خودتان یکی میزبانی کنید',
        ),
      ),
      _StatusRow(
        icon: LoomIcons.near_me_outlined,
        title: tr(context, 'Works off-grid', 'بدون اینترنت هم کار می‌کند'),
        value: tr(
          context,
          'Nearby delivery over Bluetooth and Wi-Fi',
          'تحویل نزدیک از طریق بلوتوث و وای‌فای',
        ),
      ),
      _StatusRow(
        icon: LoomIcons.shield_outlined,
        title: tr(context, 'No ads, no tracking', 'بدون تبلیغ، بدون ردیابی'),
        value: tr(
          context,
          'Free software under GPLv3',
          'نرم‌افزار آزاد با مجوز GPLv3',
        ),
      ),
      const SizedBox(height: LoomSpacing.lg),

      // ── Links ──────────────────────────────────────────────────────────
      _SectionTitle(tr(context, 'Links', 'پیوندها')),
      LoomSettingsRow(
        icon: LoomIcons.http_rounded,
        title: tr(context, 'Source code', 'کد منبع'),
        subtitle: 'github.com/0800x/Loom',
        showDivider: true,
        onTap: () => unawaited(
          _launchExternal(context, 'https://github.com/0800x/Loom'),
        ),
      ),
      LoomSettingsRow(
        icon: LoomIcons.send_rounded,
        title: tr(context, 'Telegram channel', 'کانال تلگرام'),
        subtitle: 't.me/LoomMessanger',
        showDivider: true,
        onTap: () => unawaited(
          _launchExternal(context, 'https://t.me/LoomMessanger'),
        ),
      ),
      LoomSettingsRow(
        icon: LoomIcons.open_in_new,
        title: tr(context, 'Licenses and attribution', 'مجوزها و انتساب'),
        subtitle: tr(
          context,
          'Third-party components and licenses',
          'اجزای شخص ثالث و مجوزها',
        ),
        showDivider: false,
        onTap: () => showLicensePage(
          context: context,
          applicationName: tr(context, 'Loom', 'لوم'),
          applicationVersion: loomReleaseVersion,
        ),
      ),
      const SizedBox(height: LoomSpacing.lg),

      // ── Installed build ────────────────────────────────────────────────
      _SectionTitle(tr(context, 'Installed build', 'بیلد نصب‌شده')),
      LoomSettingsCard(
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
                      : '\${info.version}+\${info.buildNumber}',
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
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _Notice(
          tr(
            context,
            'Copyright © 2026 Loom contributors. GPLv3-only. Include the package version when reporting a problem.',
            'حق نشر © ۲۰۲۶ مشارکت‌کنندگان لوم. مجوز GPLv3. هنگام گزارش مشکل، نسخهٔ پکیج را هم ارسال کنید.',
          ),
        ),
      ),
    ];
  }

  Future<void> _launchExternal(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(context, 'Could not open link', 'باز کردن لینک ممکن نشد'),
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(context, 'Could not open link', 'باز کردن لینک ممکن نشد'),
            ),
          ),
        );
      }
    }
  }

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

/// Status-driven switch for message notifications. The OS is authoritative:
/// the value is re-queried on start and whenever the app returns to the
/// foreground (the permission dialog may have changed it).
class _MessageNotificationToggle extends StatefulWidget {
  const _MessageNotificationToggle();

  @override
  State<_MessageNotificationToggle> createState() =>
      _MessageNotificationToggleState();
}

class _MessageNotificationToggleState extends State<_MessageNotificationToggle>
    with WidgetsBindingObserver {
  final _bridge = LoomMessageNotificationBridge();
  bool _enabled = false;
  bool _checking = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final status = await _bridge.status();
      if (!mounted) return;
      setState(() {
        _enabled = status['enabled'] == true;
        _checking = false;
      });
    } on MissingPluginException {
      // Test harness or unsupported platform: no OS answer available.
      if (!mounted) return;
      setState(() => _checking = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _checking = false);
    }
  }

  Future<void> _toggle(bool value) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      if (value) {
        // Turning on triggers the POST_NOTIFICATIONS prompt on Android 13+.
        await _bridge.enable();
      } else {
        // Revocation is only possible from the OS settings page.
        await _bridge.settings();
      }
    } on MissingPluginException {
      // Test harness or unsupported platform.
    } catch (_) {
      // Channel unavailable; keep the OS answer below.
    }
    // Give the OS dialog a beat to settle, then trust the real state.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    return LoomSettingsRow(
      icon: LoomIcons.notifications_none_rounded,
      title: tr(context, 'Message notifications', 'اعلان پیام‌ها'),
      subtitle: _checking
          ? tr(context, 'Checking system state…', 'بررسی وضعیت سیستم…')
          : _enabled
          ? tr(
              context,
              'On — encrypted preview; muted and open chats stay silent',
              'روشن — پیش‌نمایش خصوصی؛ چت‌های بی‌صدا و باز اعلان نمی‌دهند',
            )
          : tr(
              context,
              'Off — enable to hear from new chats',
              'خاموش — برای اطلاع از پیام‌های جدید فعال کنید',
            ),
      showDivider: true,
      // Never an indefinite spinner here: unmocked platform channels hang
      // in widget tests and any infinite animation stalls pumpAndSettle.
      trailing: Switch(value: _enabled, onChanged: _working ? null : _toggle),
      onTap: () => _toggle(!_enabled),
    );
  }
}

/// Opt-in Android foreground service that keeps the messaging socket alive
/// after the app is swiped away, so message notifications keep arriving.
/// Honest about its limits: it is a keep-alive, not push.
class _StayConnectedToggle extends StatefulWidget {
  const _StayConnectedToggle();

  @override
  State<_StayConnectedToggle> createState() => _StayConnectedToggleState();
}

class _StayConnectedToggleState extends State<_StayConnectedToggle> {
  final _store = LoomNotificationPreferencesStore();
  final _bridge = LoomMessageNotificationBridge();
  bool? _enabled;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final preferences = await _store.load();
      if (!mounted) return;
      setState(() => _enabled = preferences.stayConnected);
    } catch (_) {
      if (!mounted) return;
      setState(() => _enabled = false);
    }
  }

  Future<void> _toggle(bool value) async {
    if (_working || _enabled == null) return;
    setState(() => _working = true);
    try {
      await _store.save(LoomNotificationPreferences(stayConnected: value));
      if (value) {
        await _bridge.startStayConnected();
      } else {
        await _bridge.stopStayConnected();
      }
      if (!mounted) return;
      setState(() => _enabled = value);
    } catch (_) {
      await _load();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _enabled == true;
    return LoomSettingsRow(
      icon: LoomIcons.sync_rounded,
      iconColor: context.loom.connectivity,
      title: tr(context, 'Stay connected', 'اتصال همیشگی'),
      subtitle: _enabled == null
          ? tr(context, 'Checking…', 'در حال بررسی…')
          : on
          ? tr(
              context,
              'On — messages keep arriving for a while after you close Loom',
              'روشن — پس از بستن لوم هم پیام‌ها به دستتان می‌رسد',
            )
          : tr(
              context,
              'Keep receiving messages after closing the app',
              'پس از بستن برنامه هم پیام دریافت کنید',
            ),
      showDivider: true,
      trailing: Switch(
        value: on,
        onChanged: _working ? null : _toggle,
      ),
      onTap: () => _toggle(!on),
    );
  }
}

/// Device-local search index consent. Turning it off wipes the decrypted
/// preview index immediately; turning it on starts a bounded back-fill.
class _LocalSearchToggle extends StatefulWidget {
  const _LocalSearchToggle();

  @override
  State<_LocalSearchToggle> createState() => _LocalSearchToggleState();
}

class _LocalSearchToggleState extends State<_LocalSearchToggle> {
  bool? _enabled;
  bool _working = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final messaging = LoomMessagingSessionScope.maybeOf(context);
    if (_enabled == null && messaging != null) {
      _enabled = messaging.searchEnabled;
    }
  }

  Future<void> _toggle(bool value) async {
    final messaging = LoomMessagingSessionScope.maybeOf(context);
    if (messaging == null || _working) return;
    setState(() => _working = true);
    try {
      await messaging.setSearchEnabled(value);
      if (mounted) setState(() => _enabled = value);
    } catch (_) {
      // The switch re-reads from the controller on the next rebuild.
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled ?? true;
    return Card(
      elevation: 0,
      color: Theme.of(context).cardColor,
      child: SwitchListTile.adaptive(
        secondary: const Icon(LoomIcons.search_rounded),
        title: Text(tr(context, 'Local message search', 'جستجوی محلی پیام‌ها')),
        subtitle: Text(
          tr(
            context,
            'Keeps decrypted previews on this device so chats stay searchable. Turning it off erases the index.',
            'پیش‌نمایش رمزگشایی‌شدهٔ پیام‌ها روی همین دستگاه نگه داشته می‌شود تا گفتگوها قابل جستجو باشند. خاموش‌کردن آن فهرست را پاک می‌کند.',
          ),
        ),
        value: enabled,
        onChanged: _working ? null : _toggle,
      ),
    );
  }
}

/// Lists blocked addresses with one-tap unblock.
class _BlockedContactsCard extends StatelessWidget {
  const _BlockedContactsCard();

  @override
  Widget build(BuildContext context) {
    final messaging = LoomMessagingSessionScope.maybeOf(context);
    if (messaging == null) return const SizedBox.shrink();
    final blocked = messaging.blockedPeers.toList(growable: false)..sort();
    if (blocked.isEmpty) return const SizedBox.shrink();
    return Card(
      elevation: 0,
      color: Theme.of(context).cardColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
            child: Text(
              tr(context, 'Blocked contacts', 'مخاطبان مسدودشده'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final address in blocked)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18),
              leading: const Icon(LoomIcons.shield_outlined),
              title: Text(address, textDirection: TextDirection.ltr),
              trailing: TextButton(
                onPressed: () => unawaited(messaging.unblockPeer(address)),
                child: Text(tr(context, 'Unblock', 'رفع مسدودی')),
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// Flat storage summary card for Data & Storage.
///
/// Measures the messages database, the other local databases and the media
/// cache directories, then renders a segmented usage bar with a legend and a
/// cache-clearing action. Sizes are informational only; nothing is deleted
/// unless the user presses "Clear media cache".
class _StorageUsageCard extends StatefulWidget {
  const _StorageUsageCard();

  @override
  State<_StorageUsageCard> createState() => _StorageUsageCardState();
}

class _StorageUsageCardState extends State<_StorageUsageCard> {
  Future<_StorageBreakdown>? _breakdown;
  bool _clearing = false;

  /// Mirror of the stale-cache directory list the session controller cleans
  /// on startup; these are the same directories users can clear manually.
  static const _cacheDirNames = [
    'loom_media_view',
    'loom_media_prepare',
    'loom_media_record',
    'loom_media_playback',
    'loom_music_library',
    'loom_media_keyboard',
  ];

  @override
  void initState() {
    super.initState();
    _breakdown = _measure();
  }

  Future<int> _directorySize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  Future<_StorageBreakdown> _measure() async {
    var messages = 0;
    var otherDatabases = 0;
    var mediaCache = 0;
    try {
      final support = Directory((await LoomAccountWorkspace.active()).path);
      if (await support.exists()) {
        await for (final entity in support.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          final size = await entity.length();
          if (name.startsWith('loom-messages-v1.sqlite3')) {
            messages += size;
          } else if (name.contains('.sqlite3')) {
            otherDatabases += size;
          }
        }
      }
    } catch (_) {
      // The workspace may be unavailable (locked vault, fresh install);
      // the card degrades to cache-only numbers instead of failing.
    }
    try {
      final temp = await getTemporaryDirectory();
      for (final name in _cacheDirNames) {
        final dir = Directory('${temp.path}${Platform.pathSeparator}$name');
        if (await dir.exists()) {
          mediaCache += await _directorySize(dir);
        }
      }
    } catch (_) {}
    return _StorageBreakdown(
      messagesDatabase: messages,
      otherDatabases: otherDatabases,
      mediaCache: mediaCache,
    );
  }

  Future<void> _clearCache() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    try {
      try {
        final temp = await getTemporaryDirectory();
        for (final name in _cacheDirNames) {
          try {
            final dir = Directory('${temp.path}${Platform.pathSeparator}$name');
            if (await dir.exists()) {
              await dir.delete(recursive: true);
            }
          } catch (_) {}
        }
      } catch (_) {}
      setState(() => _breakdown = _measure());
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final cacheColor = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFFBBF24)
        : const Color(0xFFD97706);
    return FutureBuilder<_StorageBreakdown>(
      future: _breakdown,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final loading = data == null;
        final messages = data?.messagesDatabase ?? 0;
        final other = data?.otherDatabases ?? 0;
        final cache = data?.mediaCache ?? 0;
        final total = messages + other + cache;
        double fraction(int part) => total <= 0 ? 0 : part / total;
        return Container(
          margin: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 4),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.surfaceElevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: p.primary.withAlphaFraction(.12),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      LoomIcons.storage_outlined,
                      size: 22,
                      color: p.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr(context, 'Storage usage', 'مصرف فضا'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          loading
                              ? tr(
                                  context,
                                  'Measuring local files…',
                                  'در حال اندازه‌گیری فایل‌های محلی…',
                                )
                              : tr(
                                  context,
                                  '${_formatBytes(total)} used by Loom on this device',
                                  '${_formatBytes(total)} توسط لوم روی این دستگاه',
                                ),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: p.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!loading) ...[
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 8,
                    child: Row(
                      children: [
                        Expanded(
                          flex: (fraction(messages) * 1000).round() + 1,
                          child: ColoredBox(color: p.primary),
                        ),
                        Expanded(
                          flex: (fraction(other) * 1000).round() + 1,
                          child: ColoredBox(
                            color: p.secondary.withAlphaFraction(.75),
                          ),
                        ),
                        Expanded(
                          flex: (fraction(cache) * 1000).round() + 1,
                          child: ColoredBox(color: cacheColor),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _StorageLegendRow(
                  color: p.primary,
                  label: tr(
                    context,
                    'Messages database',
                    'پایگاه دادهٔ پیام‌ها',
                  ),
                  value: _formatBytes(messages),
                ),
                _StorageLegendRow(
                  color: p.secondary.withAlphaFraction(.75),
                  label: tr(context, 'Other local data', 'سایر داده‌های محلی'),
                  value: _formatBytes(other),
                ),
                _StorageLegendRow(
                  color: cacheColor,
                  label: tr(context, 'Media cache', 'حافظهٔ موقت رسانه'),
                  value: _formatBytes(cache),
                  last: true,
                ),
                if (cache > 0) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: _clearing ? null : _clearCache,
                      icon: _clearing
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              LoomIcons.delete_outline_rounded,
                              size: 18,
                            ),
                      label: Text(
                        tr(
                          context,
                          'Clear media cache',
                          'پاک‌سازی حافظهٔ موقت',
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _StorageBreakdown {
  const _StorageBreakdown({
    required this.messagesDatabase,
    required this.otherDatabases,
    required this.mediaCache,
  });

  final int messagesDatabase;
  final int otherDatabases;
  final int mediaCache;
}

class _StorageLegendRow extends StatelessWidget {
  const _StorageLegendRow({
    required this.color,
    required this.label,
    required this.value,
    this.last = false,
  });

  final Color color;
  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 6),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: p.textSecondary),
            ),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Data & Storage row that surfaces the live SQLCipher at-rest state and
/// deep-links to the Security screen where the one-way toggle lives.
class _DbEncryptionStatusRow extends StatefulWidget {
  const _DbEncryptionStatusRow();

  @override
  State<_DbEncryptionStatusRow> createState() => _DbEncryptionStatusRowState();
}

class _DbEncryptionStatusRowState extends State<_DbEncryptionStatusRow> {
  Future<bool>? _enabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled ??= LoomDbEncryption.preferenceEnabled();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _enabled,
      builder: (context, snapshot) {
        final enabled = snapshot.data;
        final subtitle = enabled == null
            ? tr(
                context,
                'Encrypted local message history',
                'تاریخچهٔ محلی رمزگذاری‌شده',
              )
            : enabled
            ? tr(
                context,
                'Enabled · messages are encrypted at rest',
                'فعال · پیام‌ها در حالت سکون رمزگذاری می‌شوند',
              )
            : tr(
                context,
                'Disabled · messages are stored in plaintext',
                'غیرفعال · پیام‌ها به‌صورت متنی ذخیره می‌شوند',
              );
        return LoomSettingsRow(
          icon: LoomIcons.lock_outline_rounded,
          title: tr(context, 'Database encryption', 'رمزگذاری پایگاه داده'),
          subtitle: subtitle,
          showDivider: false,
          onTap: () => Navigator.of(context).pushNamed('/security'),
        );
      },
    );
  }
}
