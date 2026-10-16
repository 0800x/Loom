import 'dart:async';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';

class LoomAppLockGate extends StatefulWidget {
  const LoomAppLockGate({
    required this.child,
    required this.onLocked,
    required this.onUnlocked,
    super.key,
  });
  final Widget child;
  final VoidCallback onLocked;
  final VoidCallback onUnlocked;
  @override
  State<LoomAppLockGate> createState() => _LoomAppLockGateState();
}

class _LoomAppLockGateState extends State<LoomAppLockGate>
    with WidgetsBindingObserver {
  final lock = LoomAppLock.instance;
  bool _covered = false;
  bool _wasLocked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    lock.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialize());
    });
  }

  Future<void> _initialize() async {
    if (mounted) {
      setState(() => _error = null);
    }
    try {
      await lock.initialize();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'unavailable');
      }
    }
  }

  void _changed() {
    if (!mounted) {
      return;
    }
    final state = WidgetsBinding.instance.lifecycleState;
    if (lock.enabled &&
        !lock.locked &&
        !lock.authenticating &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused)) {
      // Authentication may finish after the user backgrounds the OS prompt.
      // Keep the cover up and revoke the released key on the next microtask.
      scheduleMicrotask(() {
        final current = WidgetsBinding.instance.lifecycleState;
        if (!lock.authenticating &&
            (current == AppLifecycleState.hidden ||
                current == AppLifecycleState.paused)) {
          unawaited(lock.lock());
        }
      });
    }
    if (lock.locked && !_wasLocked) {
      widget.onLocked();
    }
    if (!lock.locked && _wasLocked) {
      widget.onUnlocked();
    }
    _wasLocked = lock.locked;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (!lock.authenticating) {
        unawaited(lock.lock());
      }
    }
    if (mounted) {
      setState(() => _covered = state != AppLifecycleState.resumed);
    }
  }

  Future<void> _unlock() async {
    setState(() => _error = null);
    try {
      final success = await lock.unlock(
        tr(context, 'Unlock Loom', 'بازکردن لوم'),
      );
      if (!success && mounted) {
        setState(() => _error = 'cancelled');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is PlatformException
              ? error.code
              : 'app_lock_unexpected_error',
        );
      }
    }
  }

  @override
  void dispose() {
    lock.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!lock.initialized || lock.locked) {
      // Remove the navigator subtree so drafts and selected plaintext in route
      // widgets are disposed. The encrypted database/outbox remain intact.
      return Material(
        color: context.loom.background,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: LoomGlassSurface(
                  liveBackdrop: true,
                  radius: 32,
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LoomIcons.lock_outline_rounded,
                        size: 44,
                        color: context.loom.primary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Loom',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        tr(
                          context,
                          'Your conversations are locked',
                          'گفتگوهای شما قفل‌اند',
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      if (!lock.initialized && _error == null)
                        const CircularProgressIndicator()
                      else if (!lock.initialized)
                        FilledButton(
                          onPressed: _initialize,
                          child: Text(tr(context, 'Retry', 'تلاش دوباره')),
                        )
                      else
                        FilledButton.icon(
                          onPressed: lock.authenticating ? null : _unlock,
                          icon: const Icon(LoomIcons.fingerprint_rounded),
                          label: Text(tr(context, 'Unlock', 'بازکردن قفل')),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            appLockStatusMessage(context, _error!),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    // Cover immediately on focus loss; permission/picker dialogs do not lock
    // until the app is hidden. Screen-reader semantics are covered as well.
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: lock.enabled && _covered, child: widget.child),
        if (lock.enabled && _covered)
          Positioned.fill(
            child: ColoredBox(
              color: context.loom.background,
              child: Center(
                child: Icon(
                  LoomIcons.lock_outline_rounded,
                  size: 40,
                  color: context.loom.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class LoomAppLockSettings extends StatefulWidget {
  const LoomAppLockSettings({super.key});
  @override
  State<LoomAppLockSettings> createState() => _LoomAppLockSettingsState();
}

class _LoomAppLockSettingsState extends State<LoomAppLockSettings>
    with WidgetsBindingObserver {
  final lock = LoomAppLock.instance;
  String? _errorCode;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    lock.addListener(_changed);
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    try {
      await lock.refreshStatus();
    } catch (error) {
      if (mounted) {
        setState(() => _errorCode = _code(error));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshStatus());
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    lock.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _configure(bool value) async {
    setState(() => _errorCode = null);
    try {
      final accepted = await lock.configure(
        value,
        tr(context, 'Protect Loom', 'محافظت از لوم'),
      );
      if (!accepted && mounted) {
        setState(() => _errorCode = 'cancelled');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _errorCode = _code(error));
      }
    }
  }

  String _code(Object error) =>
      error is PlatformException ? error.code : 'app_lock_unexpected_error';

  Future<void> _openDeviceSettings() async {
    try {
      await lock.openDeviceSecuritySettings();
    } catch (error) {
      if (mounted) {
        setState(() => _errorCode = _code(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) => LoomSettingsGroup(
    children: [
      SwitchListTile.adaptive(
        secondary: Icon(
          LoomIcons.fingerprint_rounded,
          color: context.loom.primary,
        ),
        title: Text(tr(context, 'App lock', 'قفل برنامه')),
        subtitle: Text(
          lock.available
              ? tr(
                  context,
                  'Fingerprint, face or device PIN',
                  'اثر انگشت، چهره یا رمز دستگاه',
                )
              : appLockStatusMessage(context, lock.availabilityReason),
        ),
        value: lock.enabled,
        onChanged:
            (!lock.available && !lock.enabled) ||
                lock.changing ||
                lock.authenticating
            ? null
            : _configure,
      ),
      if (lock.changing || lock.authenticating)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LinearProgressIndicator(),
        ),
      if (_errorCode != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Semantics(
            liveRegion: true,
            child: Text(
              appLockStatusMessage(context, _errorCode!),
              style: TextStyle(
                color: _errorCode == 'cancelled'
                    ? context.loom.textSecondary
                    : context.loom.critical,
              ),
            ),
          ),
        ),
      if (lock.availabilityReason == 'not_enrolled')
        TextButton.icon(
          onPressed: _openDeviceSettings,
          icon: const Icon(LoomIcons.fingerprint_rounded),
          label: Text(tr(context, 'Set up device lock', 'تنظیم قفل دستگاه')),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          tr(
            context,
            'Locks when you leave the app. Protects stored identity keys and sessions, hides screenshots, and clears opened messages. Reading and signed receipts resume after unlock.',
            'با خروج از برنامه قفل می‌شود. کلیدهای هویت و نشست را محافظت و اسکرین‌شات را مسدود می‌کند و متن پیام‌های بازشده را پاک می‌کند. خواندن پیام و رسیدهای امضاشده پس از بازکردن قفل ادامه می‌یابند.',
          ),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: context.loom.textSecondary),
        ),
      ),
      if (lock.enabled)
        TextButton.icon(
          onPressed: () => unawaited(lock.lock()),
          icon: const Icon(LoomIcons.lock_outline_rounded),
          label: Text(tr(context, 'Lock now', 'قفل‌کردن همین حالا')),
        ),
    ],
  );
}

String appLockStatusMessage(
  BuildContext context,
  String code,
) => switch (code) {
  'cancelled' => tr(
    context,
    'Authentication was cancelled. No change was made.',
    'احراز هویت لغو شد. تنظیمات تغییر نکرد.',
  ),
  'android_version' || 'vault_unsupported' => tr(
    context,
    'App lock requires Android 11 or newer.',
    'قفل برنامه به اندروید ۱۱ یا جدیدتر نیاز دارد.',
  ),
  'unsupported_platform' => tr(
    context,
    'App lock is currently available on Android.',
    'قفل برنامه در حال حاضر برای اندروید در دسترس است.',
  ),
  'app_lock_native_bridge_missing' => tr(
    context,
    'This APK has an older Android App Lock bridge than the Dart code. Fully rebuild and reinstall the APK; clearing app data is not enough. Support code: app_lock_native_bridge_missing.',
    'پل اندرویدی قفل برنامه در این APK قدیمی‌تر از کد Dart است. APK را کامل rebuild و دوباره نصب کنید؛ پاک‌کردن دادهٔ برنامه کافی نیست. کد پشتیبانی: app_lock_native_bridge_missing.',
  ),
  'not_enrolled' => tr(
    context,
    'Set a device PIN, password or strong biometric in Android settings first.',
    'ابتدا رمز یا اثر انگشت دستگاه را در تنظیمات اندروید فعال کنید.',
  ),
  'authenticator_unavailable' || 'vault_auth_unavailable' => tr(
    context,
    'Device authentication is unavailable. Check your device PIN or strong biometric in Android settings, then retry.',
    'احراز هویت دستگاه در دسترس نیست. رمز یا اثر انگشت را در تنظیمات اندروید بررسی کنید و دوباره تلاش کنید.',
  ),
  'vault_auth_lockout' => tr(
    context,
    'Android temporarily blocked authentication. Unlock your phone with its PIN, then retry.',
    'اندروید احراز هویت را موقتاً مسدود کرده است. گوشی را با رمز باز کنید و دوباره تلاش کنید.',
  ),
  'vault_key_invalidated' || 'vault_key_missing' => tr(
    context,
    'The protected key is unavailable after a device security change. Keep your app data; account recovery may be required.',
    'کلید محافظت‌شده پس از تغییر امنیت دستگاه در دسترس نیست. داده‌های برنامه را پاک نکنید؛ ممکن است بازیابی حساب لازم باشد.',
  ),
  'vault_integrity_failed' => tr(
    context,
    'The saved data could not be authenticated with this device key. Keep app data and report support code: vault_integrity_failed.',
    'دادهٔ ذخیره‌شده با کلید این دستگاه تأیید نشد. داده‌های برنامه را پاک نکنید و این کد را گزارش دهید: vault_integrity_failed.',
  ),
  'vault_auth_required' || 'vault_locked' => tr(
    context,
    'Device authentication did not authorize the protected key. Retry with your fingerprint or device PIN.',
    'احراز هویت دستگاه مجوز بازکردن کلید را نداد. با اثر انگشت یا رمز دستگاه دوباره تلاش کنید.',
  ),
  'vault_not_foreground' => tr(
    context,
    'Return to Loom, then unlock again. Your saved data has not been removed.',
    'به لوم برگردید و دوباره قفل را باز کنید. داده‌های ذخیره‌شده حذف نشده‌اند.',
  ),
  'vault_verification_failed' => tr(
    context,
    'Android could not verify protected storage. Existing credentials were kept; retry after restarting the app.',
    'اندروید نتوانست ذخیره‌سازی محافظت‌شده را تأیید کند. اطلاعات قبلی حفظ شد؛ برنامه را دوباره باز کنید و تلاش کنید.',
  ),
  'vault_persist_failed' => tr(
    context,
    'App Lock could not persist its protected key. Support code: vault_persist_failed.',
    'قفل برنامه نتوانست کلید محافظت‌شده را ذخیره کند. کد پشتیبانی: vault_persist_failed.',
  ),
  'secure_storage_read_failed' => tr(
    context,
    'Loom could not read the Android credential store. Clear app data for this pre-release build and retry. Support code: secure_storage_read_failed.',
    'لوم نتوانست مخزن اعتبارنامهٔ اندروید را بخواند. برای این نسخهٔ آزمایشی داده‌های برنامه را پاک کنید و دوباره تلاش کنید. کد پشتیبانی: secure_storage_read_failed.',
  ),
  'secure_storage_write_failed' => tr(
    context,
    'Loom could not update the Android credential store. Support code: secure_storage_write_failed.',
    'لوم نتوانست مخزن اعتبارنامهٔ اندروید را به‌روزرسانی کند. کد پشتیبانی: secure_storage_write_failed.',
  ),
  'app_lock_unexpected_error' => tr(
    context,
    'App Lock could not finish. Support code: app_lock_unexpected_error.',
    'قفل برنامه کامل نشد. کد پشتیبانی: app_lock_unexpected_error.',
  ),
  'secure_storage_unavailable' => tr(
    context,
    'A protected storage operation failed. Support code: secure_storage_unavailable.',
    'عملیات ذخیره‌سازی محافظت‌شده ناموفق بود. کد پشتیبانی: secure_storage_unavailable.',
  ),
  _ => tr(
    context,
    'Android could not complete protected unlock. Unlock your phone, return here and retry.',
    'اندروید نتوانست قفل محافظت‌شده را باز کند. قفل گوشی را باز کنید، به برنامه برگردید و دوباره تلاش کنید.',
  ),
};
