import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/onboarding_controller.dart';
import 'setup_scaffold.dart';

class RecoveryVerificationScreen extends StatefulWidget {
  const RecoveryVerificationScreen({super.key});
  @override
  State<RecoveryVerificationScreen> createState() =>
      _RecoveryVerificationScreenState();
}

class _RecoveryVerificationScreenState
    extends State<RecoveryVerificationScreen> {
  final word4 = TextEditingController();
  final word17 = TextEditingController();
  String? localError;
  bool submitting = false;

  @override
  void dispose() {
    word4.dispose();
    word17.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (submitting) {
      return;
    }
    final controller = LoomOnboardingScope.of(context);
    final valid =
        controller.verifyRecoveryWord(4, word4.text) &&
        controller.verifyRecoveryWord(17, word17.text);
    if (!valid) {
      setState(
        () => localError = tr(
          context,
          'Those words do not match your recovery phrase.',
          'این واژه‌ها با عبارت بازیابی شما مطابقت ندارند.',
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      localError = null;
      submitting = true;
    });
    final ok = await controller.commitAndRegister();
    if (!mounted) {
      return;
    }
    setState(() => submitting = false);
    if (ok) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/ready',
        (route) => route.isFirst,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = LoomOnboardingScope.of(context);
    final p = context.loom;
    final busy =
        submitting || controller.status == LoomOnboardingStatus.registering;
    // An app lock mid-setup discards the pending identity. Without this
    // fallback the words never validate and the user is stuck forever.
    final expired = controller.pendingIdentity == null;
    return LoomSetupScaffold(
      actions: expired
          ? FilledButton(
              onPressed: () => Navigator.of(context)
                  .popUntil((route) => route.isFirst),
              child: Text(
                tr(context, 'Back to start', 'بازگشت به ابتدا'),
              ),
            )
          : FilledButton(
              onPressed: busy ? null : _verify,
              child: busy
                  ? const LoomBusyIndicator()
                  : Text(tr(context, 'Finish setup', 'تکمیل راه‌اندازی')),
            ),
      step: 3,
      canPop: !busy,
      title: expired
          ? tr(context, 'Setup session ended', 'جلسهٔ راه‌اندازی پایان یافت')
          : tr(context, 'A quick backup check', 'یک بررسی کوتاه'),
      subtitle: expired
          ? tr(
              context,
              'Loom was locked while setting up, so the in-progress identity was cleared for safety. Nothing was lost — please create the identity again from the start.',
              'لوم حین راه‌اندازی قفل شد و به دلایل امنیتی هویت نیمه‌کاره پاک شد. چیزی از دست نرفته — لطفاً هویت را دوباره از ابتدا بسازید.',
            )
          : tr(
              context,
              'Enter words 4 and 17 from your saved list. This makes sure you have a working backup before we finish.',
              'واژه‌های ۴ و ۱۷ را از یادداشت خود وارد کنید تا قبل از پایان، از پشتیبان مطمئن شویم.',
            ),
      children: expired
          ? [
              Icon(
                LoomIcons.lock_outline_rounded,
                size: LoomIconSize.emptyState,
                color: p.textMuted,
              ),
              const SizedBox(height: LoomSpacing.lg),
            ]
          : [
              Directionality(
                textDirection: TextDirection.ltr,
                child: TextField(
                  controller: word4,
                  enabled: !busy,
                  maxLength: 16,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Recovery word #4', 'واژهٔ شمارهٔ ۴'),
                  ),
                ),
              ),
              const SizedBox(height: LoomSpacing.sm),
              Directionality(
                textDirection: TextDirection.ltr,
                child: TextField(
                  controller: word17,
                  enabled: !busy,
                  maxLength: 16,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _verify(),
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText:
                        tr(context, 'Recovery word #17', 'واژهٔ شمارهٔ ۱۷'),
                  ),
                ),
              ),
              AnimatedSize(
                duration: LoomMotion.component,
                curve: LoomMotion.standard,
                alignment: Alignment.topCenter,
                child: (localError != null || controller.errorMessage != null)
                    ? Padding(
                        padding: const EdgeInsets.only(
                          top: LoomSpacing.sm,
                        ),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            localError ?? controller.errorMessage!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: p.critical),
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: LoomSpacing.lg),
            ],
    );
  }
}
