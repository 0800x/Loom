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
    return LoomSetupScaffold(
      actions: FilledButton(
        onPressed: busy ? null : _verify,
        child: busy
            ? const LoomBusyIndicator()
            : Text(tr(context, 'Finish setup', 'تکمیل راه‌اندازی')),
      ),
      step: 3,
      canPop: !busy,
      title: tr(context, 'A quick backup check', 'یک بررسی کوتاه'),
      subtitle: tr(
        context,
        'Enter words 4 and 17 from your saved list. This makes sure you have a working backup before we finish.',
        'واژه‌های ۴ و ۱۷ را از یادداشت خود وارد کنید تا قبل از پایان، از پشتیبان مطمئن شویم.',
      ),
      children: [
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
              labelText: tr(context, 'Recovery word #17', 'واژهٔ شمارهٔ ۱۷'),
            ),
          ),
        ),
        if (localError != null || controller.errorMessage != null) ...[
          const SizedBox(height: LoomSpacing.sm),
          Text(
            localError ?? controller.errorMessage!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: p.critical),
          ),
        ],
        const SizedBox(height: LoomSpacing.lg),
      ],
    );
  }
}
