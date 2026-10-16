import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/device_link_service.dart';
import '../application/onboarding_controller.dart';
import 'onboarding_flow.dart';
import 'setup_scaffold.dart';

class LoomSignInScreen extends StatefulWidget {
  const LoomSignInScreen({this.localIdentityProbe, super.key});

  final Future<bool> Function()? localIdentityProbe;

  @override
  State<LoomSignInScreen> createState() => _LoomSignInScreenState();
}

class _LoomSignInScreenState extends State<LoomSignInScreen> {
  final _form = GlobalKey<FormState>();
  final nodeDomain = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final LoomPasswordLoginBootstrap _bootstrap =
      LoomPasswordLoginBootstrap();
  bool obscurePassword = true;
  bool identityCheckStarted = false;
  bool checkingIdentity = true;
  bool identityCheckFailed = false;
  bool hasLocalIdentity = false;
  bool nodePrefilled = false;
  bool submitting = false;
  String? localError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = LoomOnboardingScope.of(context);
    if (!nodePrefilled) {
      nodePrefilled = true;
      final selected = controller.nodes.selectedNode;
      if (selected != null && controller.nodes.selectedNodeVerified) {
        nodeDomain.text = selected.domain;
      }
    }
    if (!identityCheckStarted) {
      identityCheckStarted = true;
      _checkIdentity(controller);
    }
  }

  Future<void> _checkIdentity(LoomOnboardingController controller) async {
    setState(() {
      checkingIdentity = true;
      identityCheckFailed = false;
      localError = null;
    });
    try {
      var available =
          controller.pendingIdentity != null ||
          controller.committedIdentity != null;
      if (!available) {
        final probe = widget.localIdentityProbe;
        available = probe != null
            ? await probe()
            : await LoomIdentityCoreV1().readIdentity() != null;
      }
      if (mounted) {
        setState(() {
          hasLocalIdentity = available;
          checkingIdentity = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          checkingIdentity = false;
          identityCheckFailed = true;
          localError = tr(
            context,
            'Could not read this device’s identity. You can try signing in again or use your recovery words.',
            'هویت این دستگاه خوانده نشد. می‌توانید دوباره وارد شوید یا از واژه‌های بازیابی استفاده کنید.',
          );
        });
      }
    }
  }

  Future<void> _chooseNode() async {
    await Navigator.pushNamed(
      context,
      '/nodes',
      arguments: LoomNodeSelectionPurpose.signIn,
    );
    if (!mounted) {
      return;
    }
    final nodes = LoomOnboardingScope.of(context).nodes;
    if (nodes.selectedNodeVerified && nodes.selectedNode != null) {
      setState(() => nodeDomain.text = nodes.selectedNode!.domain);
    }
  }

  @override
  void dispose() {
    nodeDomain.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (submitting ||
        checkingIdentity ||
        identityCheckFailed ||
        !(_form.currentState?.validate() ?? false)) {
      return;
    }
    FocusScope.of(context).unfocus();
    final controller = LoomOnboardingScope.of(context);
    setState(() {
      submitting = true;
      localError = null;
    });
    try {
      if (hasLocalIdentity) {
        final ok = await controller.signIn(
          nodeDomain: nodeDomain.text,
          username: username.text,
          password: password.text,
        );
        if (!mounted || !ok) {
          return;
        }
        Navigator.pushNamedAndRemoveUntil(context, '/messenger', (_) => false);
        return;
      }

      final pending = await _bootstrap.authenticateNewDevice(
        onboarding: controller,
        nodeDomain: nodeDomain.text,
        username: username.text,
        password: password.text,
      );
      if (!mounted) {
        return;
      }
      password.clear();
      Navigator.pushReplacementNamed(
        context,
        '/link-device',
        arguments: pending,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = error is LoomProtocolException
          ? error.message
          : error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
      setState(() {
        localError = message == 'invalid_credentials'
            ? tr(
                context,
                'The username or password is incorrect.',
                'نام کاربری یا رمز عبور نادرست است.',
              )
            : message;
      });
    } finally {
      if (mounted) {
        setState(() => submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = LoomOnboardingScope.of(context);
    final palette = context.loom;
    final busy =
        submitting || controller.status == LoomOnboardingStatus.registering;
    final lockedNode =
        controller.nodes.selectedNodeVerified &&
        controller.nodes.selectedNode != null;

    return LoomSetupScaffold(
      step: null,
      canPop: !busy,
      title: tr(context, 'Welcome back', 'خوش برگشتی'),
      subtitle: checkingIdentity
          ? tr(context, 'Checking this device…', 'در حال بررسی این دستگاه…')
          : hasLocalIdentity
          ? tr(
              context,
              'Enter your password to continue.',
              'برای ادامه گذرواژه را وارد کنید.',
            )
          : tr(
              context,
              'Sign in, then securely link this device or restore your recovery words.',
              'وارد شوید و دستگاه را امن متصل کنید یا از واژه‌های بازیابی استفاده کنید.',
            ),
      actions: FilledButton.icon(
        onPressed: busy || checkingIdentity || identityCheckFailed
            ? null
            : _signIn,
        icon: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                hasLocalIdentity
                    ? LoomIcons.arrow_forward_rounded
                    : LoomIcons.qr_code_rounded,
              ),
        label: Text(
          !hasLocalIdentity && !checkingIdentity
              ? tr(context, 'Sign in and link device', 'ورود و اتصال دستگاه')
              : tr(context, 'Sign in', 'ورود'),
        ),
      ),
      children: [
        LoomGlassSurface(
          blur: false,
          radius: LoomRadii.surface,
          strength: LoomGlassStrength.standard,
          padding: const EdgeInsets.all(LoomSpacing.md),
          child: Form(
            key: _form,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: AutofillGroup(
              child: Column(
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextFormField(
                      controller: nodeDomain,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? tr(
                              context,
                              'Enter your server address.',
                              'نشانی سرور را وارد کنید.',
                            )
                          : null,
                      enabled: !busy,
                      readOnly: lockedNode,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: tr(context, 'Home server', 'سرور میزبان'),
                        hintText: '192.168.1.10:7483 or chat.example.org',
                        suffixIcon: lockedNode
                            ? const Icon(LoomIcons.verified_user_outlined)
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: LoomSpacing.sm),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextFormField(
                      controller: username,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? tr(
                              context,
                              'Enter your username.',
                              'نام کاربری را وارد کنید.',
                            )
                          : null,
                      enabled: !busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: tr(context, 'Username', 'نام کاربری'),
                      ),
                    ),
                  ),
                  const SizedBox(height: LoomSpacing.sm),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextFormField(
                      controller: password,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      validator: (value) => value == null || value.isEmpty
                          ? tr(
                              context,
                              'Enter your password.',
                              'گذرواژه را وارد کنید.',
                            )
                          : null,
                      enabled: !busy,
                      obscureText: obscurePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      onFieldSubmitted: busy ? null : (_) => _signIn(),
                      decoration: InputDecoration(
                        labelText: tr(context, 'Password', 'رمز عبور'),
                        suffixIcon: IconButton(
                          tooltip: obscurePassword
                              ? tr(context, 'Show password', 'نمایش گذرواژه')
                              : tr(
                                  context,
                                  'Hide password',
                                  'پنهان کردن گذرواژه',
                                ),
                          onPressed: () => setState(
                            () => obscurePassword = !obscurePassword,
                          ),
                          icon: Icon(
                            obscurePassword
                                ? LoomIcons.visibility_rounded
                                : LoomIcons.visibility_off_rounded,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if ((localError ?? controller.errorMessage) != null) ...[
          const SizedBox(height: LoomSpacing.sm),
          Text(
            localError ?? controller.errorMessage!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: palette.critical),
          ),
        ],
        if (identityCheckFailed)
          TextButton.icon(
            onPressed: busy || checkingIdentity
                ? null
                : () => _checkIdentity(controller),
            icon: const Icon(LoomIcons.refresh_rounded),
            label: Text(
              tr(context, 'Retry device check', 'بررسی دوبارهٔ دستگاه'),
            ),
          ),
        const SizedBox(height: LoomSpacing.lg),

        const SizedBox(height: LoomSpacing.sm),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => Navigator.pushNamed(context, '/restore'),
          icon: const Icon(LoomIcons.key_rounded),
          label: Text(
            tr(
              context,
              'Use recovery words instead',
              'استفاده از واژه‌های بازیابی',
            ),
          ),
        ),
        ...[
          const SizedBox(height: LoomSpacing.xs),
          TextButton(
            onPressed: busy ? null : _chooseNode,
            child: Text(
              tr(
                context,
                lockedNode ? 'Change home server' : 'Choose home server',
                lockedNode ? 'تغییر سرور میزبان' : 'انتخاب سرور میزبان',
              ),
            ),
          ),
        ],
      ],
    );
  }
}
