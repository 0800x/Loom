import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';
import '../application/onboarding_controller.dart';
import 'setup_scaffold.dart';

class ReadyScreen extends StatelessWidget {
  const ReadyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = LoomOnboardingScope.of(context);
    final receipt = controller.receipt;
    final identity = controller.committedIdentity;
    return LoomSetupScaffold(
      step: receipt == null ? null : 4,
      title:
          receipt == null
              ? tr(context, 'One more step', 'یک قدم دیگر مانده')
              : tr(context, 'You’re right at home.', 'به خانهٔ خودت خوش آمدی.'),
      subtitle:
          receipt == null
              ? tr(
                context,
                'Finish setup to start chatting.',
                'برای شروع گفتگو، راه‌اندازی را کامل کنید.',
              )
              : tr(
                context,
                'Share your address with a friend or find someone to start your first conversation.',
                'نشانی‌تان را به یک دوست بدهید یا او را پیدا کنید و اولین گفتگو را شروع کنید.',
              ),
      children: [
        if (receipt != null) ...[
          LoomReveal(
            child: Center(
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.loom.connectivity.withAlphaFraction(.12),
                ),
                child: Icon(
                  LoomIcons.check_rounded,
                  color: context.loom.connectivity,
                  size: 44,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          LoomGlassSurface(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                Text(
                  tr(context, 'Your Loom address', 'نشانی شما در لوم'),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 10),
                SelectableText(
                  receipt.address,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: receipt.address),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            tr(context, 'Address copied', 'نشانی کپی شد'),
                          ),
                        ),
                      );
                    }
                  },
                  icon: const Icon(LoomIcons.copy_rounded),
                  label: Text(tr(context, 'Copy address', 'کپی نشانی')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          LoomPressable(
            child: FilledButton(
              onPressed:
                  () => Navigator.pushNamedAndRemoveUntil(
                    context,
                    '/messenger',
                    (_) => false,
                  ),
              child: Text(tr(context, 'Start chatting', 'شروع گفتگو')),
            ),
          ),
          const SizedBox(height: 20),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              tr(context, 'Account details', 'جزئیات حساب'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            children: [
              _ReadyRow(
                label: tr(context, 'Home server', 'سرور میزبان'),
                value: receipt.homeNode,
              ),
              _ReadyRow(
                label: tr(context, 'Identity ID', 'شناسه هویت'),
                value: identity?.identityId ?? '—',
              ),
              _ReadyRow(
                label: tr(context, 'Fingerprint', 'اثر انگشت'),
                value: identity?.fingerprint ?? '—',
              ),
            ],
          ),
        ] else
          FilledButton(
            onPressed:
                () => Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/',
                  (_) => false,
                ),
            child: Text(tr(context, 'Return to start', 'بازگشت به شروع')),
          ),
      ],
    );
  }
}

class _ReadyRow extends StatelessWidget {
  const _ReadyRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        SelectableText(
          value,
          textDirection: TextDirection.ltr,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}
