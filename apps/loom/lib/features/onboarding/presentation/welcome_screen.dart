import '../../../app/dev_surface_policy.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import 'onboarding_chrome.dart';
import 'onboarding_flow.dart';
import 'setup_scaffold.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    required this.onThemeChanged,
    required this.onLocaleChanged,
    super.key,
  });

  final ValueChanged<LoomThemeMode> onThemeChanged;
  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  @override
  Widget build(BuildContext context) {
    return LoomOnboardingShell(
      title: tr(context, 'Hey, welcome in.', 'سلام، چه خوب که اومدی.'),
      subtitle: tr(
        context,
        'Let’s make a little space for you and your people. We’ll get you settled, one step at a time.',
        'اینجا یه جا برای تو و آدم‌های خودته. قدم‌به‌قدم آماده‌اش می‌کنیم؛ بیا شروع کنیم.',
      ),
      headerTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<LoomThemeMode>(
            tooltip: tr(context, 'Theme', 'پوسته'),
            icon: const Icon(LoomIcons.contrast_rounded),
            onSelected: widget.onThemeChanged,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: LoomThemeMode.light,
                child: Text(tr(context, 'Light', 'روشن')),
              ),
              PopupMenuItem(
                value: LoomThemeMode.dark,
                child: Text(tr(context, 'Dark', 'تیره')),
              ),
              const PopupMenuItem(
                value: LoomThemeMode.oled,
                child: Text('OLED'),
              ),
            ],
          ),
          PopupMenuButton<Locale>(
            tooltip: tr(context, 'Language', 'زبان'),
            icon: const Icon(LoomIcons.language_rounded),
            onSelected: widget.onLocaleChanged,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: Locale('en'),
                child: Text('English'),
              ),
              PopupMenuItem(
                value: Locale('fa'),
                child: Text('فارسی'),
              ),
            ],
          ),
        ],
      ),
      actions: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LoomOnboardingCta(
            label: tr(context, 'Let’s get started', 'بزن بریم'),
            onPressed: () => Navigator.pushNamed(
              context,
              '/nodes',
              arguments: LoomNodeSelectionPurpose.register,
            ),
          ),
          const SizedBox(height: LoomSpacing.xxs),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/sign-in'),
                  child: Text(tr(context, 'Sign in', 'ورود')),
                ),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/restore'),
                  child: Text(
                    tr(context, 'Use recovery kit', 'بازیابی حساب'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: LoomSetupEmblem(
              icon: LoomIcons.chat_bubble_outline_rounded,
              size: 64,
            ),
          ),
          const SizedBox(height: LoomSpacing.lg),
          LoomSettingsGroup(
            children: [
              ExpansionTile(
                title: Text(
                  tr(
                    context,
                    'How setup works',
                    'مراحل راه‌اندازی',
                  ),
                ),
                childrenPadding: const EdgeInsets.all(12),
                children: [
                  _WelcomeStep(
                    icon: LoomIcons.qr_code_scanner_rounded,
                    title: tr(
                      context,
                      'Find your home server',
                      'سرور خودت را پیدا کن',
                    ),
                    detail: tr(
                      context,
                      'Scan its QR, enter an address, or choose from the list.',
                      'QR را اسکن کن، آدرس بده یا از فهرست انتخاب کن.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  _WelcomeStep(
                    icon: LoomIcons.person_outline_rounded,
                    title: tr(
                      context,
                      'Make your profile',
                      'خودت را معرفی کن',
                    ),
                    detail: tr(
                      context,
                      'A name your friends will recognize.',
                      'با اسمی که دوست‌هایت می‌شناسند.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  _WelcomeStep(
                    icon: LoomIcons.key_rounded,
                    title: tr(
                      context,
                      'Keep a way back',
                      'یک راه برگشت نگه دار',
                    ),
                    detail: tr(
                      context,
                      'Save your recovery kit or print it for safekeeping.',
                      'پشتیبان را ذخیره کن یا برای نگهداری امن چاپش کن.',
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (loomDevelopmentSurfacesEnabled) ...[
            const SizedBox(height: LoomSpacing.md),
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/design-lab'),
              child: const Text('Design Lab · debug only'),
            ),
          ],
        ],
      ),
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title, detail;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: context.loom.primary, size: 22),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              detail,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.loom.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
