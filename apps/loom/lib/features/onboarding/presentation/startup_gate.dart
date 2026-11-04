import 'dart:async';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../home/presentation/messenger_shell.dart';
import '../../../app/loom_strings.dart';
import '../application/onboarding_controller.dart';
import 'welcome_screen.dart';
import 'setup_scaffold.dart';
import 'sign_in_screen.dart';

class LoomStartupGate extends StatefulWidget {
  const LoomStartupGate({
    required this.controller,
    required this.onThemeChanged,
    required this.onLocaleChanged,
    super.key,
  });

  final LoomOnboardingController controller;
  final ValueChanged<LoomThemeMode> onThemeChanged;
  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<LoomStartupGate> createState() => _LoomStartupGateState();
}

class _LoomStartupGateState extends State<LoomStartupGate> {
  final LoomAppLock _lock = LoomAppLock.instance;
  bool loading = true;
  bool restored = false;
  bool failed = false;
  bool _restoring = false;
  String? failureCode;

  @override
  void initState() {
    super.initState();
    _lock.addListener(_onLockChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_restore()));
  }

  void _onLockChanged() {
    if (!mounted ||
        !_lock.initialized ||
        _lock.locked ||
        _lock.authenticating ||
        restored ||
        _restoring) {
      return;
    }
    unawaited(_restore());
  }

  Future<void> _restore() async {
    if (!mounted || _restoring) {
      return;
    }
    _restoring = true;
    try {
      await _lock.initialize();
      if (!mounted) {
        return;
      }
      if (_lock.enabled && _lock.locked) {
        setState(() {
          loading = true;
          failed = false;
          failureCode = null;
        });
        return;
      }
      setState(() {
        loading = true;
        failed = false;
        failureCode = null;
      });
      final result = await widget.controller.restorePersistedSession();
      if (mounted) {
        setState(() {
          restored = result;
          loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        if (_lock.locked) {
          // A lock that raced this restore is expected; the next successful
          // unlock listener retries instead of presenting a false data error.
          setState(() {
            loading = true;
            failed = false;
            failureCode = null;
          });
        } else {
          setState(() {
            failed = true;
            loading = false;
            // Bounded support codes only: no exception text, account or secrets.
            failureCode =
                error is PlatformException &&
                    const {
                      'vault_locked',
                      'vault_key_missing',
                      'vault_key_invalidated',
                      'vault_auth_required',
                      'vault_integrity_failed',
                      'vault_unavailable',
                    }.contains(error.code)
                ? error.code
                : error is FormatException
                ? 'saved_account_invalid'
                : 'saved_account_unavailable';
          });
        }
      }
    } finally {
      _restoring = false;
    }
  }

  @override
  void dispose() {
    _lock.removeListener(_onLockChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading || failed) {
      return Scaffold(
        body: LoomSetupBackdrop(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LoomReveal(
                    order: 1,
                    child: LoomBrandMark(size: 76, glow: false),
                  ),
                  const SizedBox(height: 20),
                  LoomReveal(
                    order: 2,
                    child: Text(
                      tr(context, 'Loom', 'لوم'),
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (loading) ...[
                    if (!MediaQuery.disableAnimationsOf(context))
                      SizedBox(
                        width: 160,
                        child: Semantics(
                          label: tr(context, 'Loading', 'در حال بارگذاری'),
                          child: LinearProgressIndicator(
                            minHeight: 3,
                            borderRadius: BorderRadius.circular(8),
                            color: context.loom.primary,
                            backgroundColor: context.loom.surfaceMuted,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      tr(
                        context,
                        'Opening your conversations…',
                        'در حال باز کردن گفتگوها…',
                      ),
                    ),
                  ] else ...[
                    Text(
                      tr(
                        context,
                        'Your saved account could not be opened. Unlock your device and retry. Do not create another account or clear app data.',
                        'حساب ذخیره‌شده باز نشد. قفل دستگاه را باز کنید و دوباره تلاش کنید. حساب جدید نسازید و داده‌های برنامه را پاک نکنید.',
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    if (failureCode != null)
                      SelectableText(
                        '${tr(context, 'Support code', 'کد پشتیبانی')}: $failureCode',
                        textDirection: TextDirection.ltr,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    FilledButton(
                      onPressed: _restore,
                      child: Text(tr(context, 'Try again', 'تلاش دوباره')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (restored) {
      return const MessengerShell();
    }
    if (widget.controller.committedIdentity != null) {
      // A retained identity belongs to an existing account, including after
      // explicit sign-out. Never steer it into creating a replacement identity.
      return const LoomSignInScreen();
    }
    return WelcomeScreen(
      onThemeChanged: widget.onThemeChanged,
      onLocaleChanged: widget.onLocaleChanged,
    );
  }
}
