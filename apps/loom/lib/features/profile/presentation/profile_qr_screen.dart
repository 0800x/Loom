import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/loom_strings.dart';
import '../../onboarding/application/onboarding_controller.dart';

class LoomProfileQrScreen extends StatelessWidget {
  const LoomProfileQrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final onboarding = LoomOnboardingScope.of(context);
    final address = onboarding.receipt?.address.trim() ?? '';
    final displayName = onboarding.displayName.trim();

    return Scaffold(
      appBar: LoomGlassAppBar(
        title: Text(tr(context, 'Profile QR', 'QR پروفایل')),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(LoomSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                children: [
                  Text(
                    displayName.isEmpty
                        ? tr(context, 'My Loom profile', 'پروفایل لوم من')
                        : displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  Text(
                    tr(
                      context,
                      'Scan this QR to get my public Loom address.',
                      'برای دریافت نشانی عمومی لوم من، این QR را اسکن کنید.',
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.loom.textSecondary,
                    ),
                  ),
                  const SizedBox(height: LoomSpacing.lg),
                  if (address.isNotEmpty) ...[
                    LoomGlassSurface(
                      strength: LoomGlassStrength.weak,
                      blur: false,
                      padding: const EdgeInsets.all(LoomSpacing.md),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        color: Colors.white,
                        child: QrImageView(
                          data: address,
                          version: QrVersions.auto,
                          size: 240,
                          backgroundColor: Colors.white,
                          semanticsLabel: tr(
                            context,
                            'QR code for $address',
                            'کد QR برای $address',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: LoomSpacing.md),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: SelectableText(
                        address,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: LoomSpacing.md),
                    FilledButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: address));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            SnackBar(
                              content: Text(
                                tr(
                                  context,
                                  'Loom address copied',
                                  'نشانی لوم کپی شد',
                                ),
                              ),
                            ),
                          );
                      },
                      icon: const Icon(LoomIcons.copy_rounded),
                      label: Text(tr(context, 'Copy address', 'کپی نشانی')),
                    ),
                  ] else
                    LoomGlassSurface(
                      strength: LoomGlassStrength.weak,
                      blur: false,
                      padding: const EdgeInsets.all(LoomSpacing.lg),
                      child: Text(
                        tr(
                          context,
                          'No registered Loom address is available on this device.',
                          'نشانی ثبت‌شده لوم روی این دستگاه در دسترس نیست.',
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: LoomSpacing.md),
                  Text(
                    tr(
                      context,
                      'The QR contains only your public Loom address. It never contains recovery words, passwords, or private keys.',
                      'این QR فقط نشانی عمومی لوم شما را دارد و هرگز شامل کلمات بازیابی، رمز عبور یا کلید خصوصی نیست.',
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.loom.textMuted,
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
