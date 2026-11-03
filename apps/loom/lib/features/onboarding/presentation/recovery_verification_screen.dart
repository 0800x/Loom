import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/onboarding_controller.dart';
import 'onboarding_chrome.dart';

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
    return LoomOnboardingShell(
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
      error: expired ? null : (localError ?? controller.errorMessage),
      ctaLabel: expired
          ? tr(context, 'Back to start', 'بازگشت به ابتدا')
          : tr(context, 'Finish setup', 'تکمیل راه‌اندازی'),
      onCta: expired
          ? () => Navigator.of(context).popUntil((route) => route.isFirst)
          : busy
          ? null
          : _verify,
      ctaBusy: busy,
      child: expired
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  LoomIcons.lock_outline_rounded,
                  size: LoomIconSize.emptyState,
                  color: p.textMuted,
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _WordSlot(
                  index: 4,
                  controller: word4,
                  label: tr(context, 'Recovery word #4', 'واژهٔ شمارهٔ ۴'),
                  enabled: !busy,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: LoomSpacing.sm),
                _WordSlot(
                  index: 17,
                  controller: word17,
                  label: tr(context, 'Recovery word #17', 'واژهٔ شمارهٔ ۱۷'),
                  enabled: !busy,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _verify(),
                ),
              ],
            ),
    );
  }
}

/// A numbered word slot: the round badge fills with a check once a word has
/// been entered, so the saved/filled state is readable at a glance. The
/// field itself keeps the theme input style and all validation wiring.
class _WordSlot extends StatelessWidget {
  const _WordSlot({
    required this.index,
    required this.controller,
    required this.label,
    required this.enabled,
    required this.textInputAction,
    this.onSubmitted,
  });

  final int index;
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return LoomGlassSurface(
      strength: LoomGlassStrength.weak,
      blur: false,
      radius: LoomRadii.control,
      padding: const EdgeInsets.symmetric(
        horizontal: LoomSpacing.sm,
        vertical: LoomSpacing.xs,
      ),
      child: Row(
        children: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final filled = value.text.trim().isNotEmpty;
              return AnimatedContainer(
                duration:
                    LoomAccessibility.fromContext(context).reduceMotion
                    ? Duration.zero
                    : LoomMotion.component,
                curve: LoomMotion.standard,
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? p.primary : p.surfaceMuted,
                  border: Border.all(color: filled ? p.primary : p.border),
                ),
                child: ExcludeSemantics(
                  child: filled
                      ? Icon(
                          LoomIcons.check_rounded,
                          size: LoomIconSize.compact,
                          color: p.onPrimary,
                        )
                      : Text(
                          '$index',
                          textDirection: TextDirection.ltr,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: p.textSecondary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                ),
              );
            },
          ),
          const SizedBox(width: LoomSpacing.sm),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: TextField(
                controller: controller,
                enabled: enabled,
                maxLength: 16,
                textInputAction: textInputAction,
                onSubmitted: onSubmitted,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: label),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
