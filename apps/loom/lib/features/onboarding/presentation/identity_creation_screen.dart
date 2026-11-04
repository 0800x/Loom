import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../../nodes/application/node_directory_controller.dart';
import '../application/onboarding_controller.dart';
import 'setup_scaffold.dart';

class IdentityCreationScreen extends StatefulWidget {
  const IdentityCreationScreen({super.key});
  @override
  State<IdentityCreationScreen> createState() => _IdentityCreationScreenState();
}

class _IdentityCreationScreenState extends State<IdentityCreationScreen> {
  final _form = GlobalKey<FormState>();
  final username = TextEditingController();
  final displayName = TextEditingController();
  final password = TextEditingController();
  bool obscure = true;
  bool submitting = false;

  @override
  void dispose() {
    username.dispose();
    displayName.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (submitting || !(_form.currentState?.validate() ?? false)) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => submitting = true);
    try {
      final ok = await LoomOnboardingScope.of(context).createIdentity(
        username: username.text,
        displayName: displayName.text,
        password: password.text,
      );
      if (mounted && ok) {
        await Navigator.pushNamed(context, '/recovery');
      }
    } finally {
      if (mounted) {
        setState(() => submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = LoomOnboardingScope.of(context);
    final node = LoomNodeDirectoryScope.of(context).selectedNode;
    final busy =
        submitting ||
        controller.status == LoomOnboardingStatus.creatingIdentity;
    return LoomSetupScaffold(
      actions: LoomPressable(
        enabled: !busy,
        child: FilledButton(
          onPressed: busy ? null : _continue,
          child: busy
              ? const LoomBusyIndicator()
              : Text(tr(context, 'Continue', 'ادامه')),
        ),
      ),
      step: 2,
      canPop: !busy,
      title: tr(context, 'Make it yours', 'اینجا، خودت باش'),
      subtitle: tr(
        context,
        'Choose how people find you. Next, we’ll help you back up your account.',
        'نامی انتخاب کنید که دوستانتان شما را با آن پیدا کنند. مرحلهٔ بعد، پشتیبان‌گیری حساب است.',
      ),
      children: [
        Form(
          key: _form,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: AutofillGroup(
            child: Column(
              children: [
                TextFormField(
                  controller: displayName,
                  enabled: !busy,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.nickname],
                  validator: (value) => value == null || value.trim().isEmpty
                      ? tr(
                          context,
                          'Enter the name people will see.',
                          'نامی که دیگران می‌بینند را وارد کنید.',
                        )
                      : null,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Your name', 'نام شما'),
                    prefixIcon: const Icon(LoomIcons.person_outline_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: username,
                  enabled: !busy,
                  maxLength: 32,
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.newUsername],
                  validator: (value) =>
                      RegExp(
                        r'^[a-z0-9_][a-z0-9_.-]{2,31}$',
                      ).hasMatch((value ?? '').trim().toLowerCase())
                      ? null
                      : tr(
                          context,
                          'Use 3–32 English letters, numbers, _ . or -. Start with a letter, number or _.',
                          '۳ تا ۳۲ حرف انگلیسی، عدد یا _ . - ؛ با حرف، عدد یا _ شروع کنید.',
                        ),
                  decoration: InputDecoration(
                    labelText: tr(context, 'Username', 'نام کاربری'),
                    prefixText: '@',
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: username,
                  builder: (context, value, _) => Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      '@${value.text.trim().toLowerCase().isEmpty ? 'username' : value.text.trim().toLowerCase()}:${node?.domain ?? '…'}',
                      textDirection: TextDirection.ltr,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: password,
                  enabled: !busy,
                  obscureText: obscure,
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.newPassword],
                  onFieldSubmitted: (_) => _continue(),
                  validator: (value) =>
                      value == null || value.length < 12 || value.length > 256
                      ? tr(
                          context,
                          'Use a password with 12–256 characters.',
                          'گذرواژه باید ۱۲ تا ۲۵۶ نویسه داشته باشد.',
                        )
                      : null,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Password', 'گذرواژه'),
                    helperText: tr(
                      context,
                      'At least 12 characters. You’ll use this to sign in.',
                      'حداقل ۱۲ نویسه؛ برای ورود به حساب استفاده می‌شود.',
                    ),
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => obscure = !obscure),
                      tooltip: obscure
                          ? tr(context, 'Show password', 'نمایش گذرواژه')
                          : tr(context, 'Hide password', 'پنهان کردن گذرواژه'),
                      icon: Icon(
                        obscure
                            ? LoomIcons.visibility_outlined
                            : LoomIcons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (controller.errorMessage != null) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              controller.errorMessage!,
              style: TextStyle(color: context.loom.critical),
            ),
          ),
        ],
        const SizedBox(height: 24),

        const SizedBox(height: 16),
        Text(
          tr(
            context,
            'Your account will be hosted by ${node?.name ?? '…'}.',
            'حساب شما روی ${node?.name ?? '…'} میزبانی می‌شود.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
