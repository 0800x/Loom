import 'package:loom_design/loom_design.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/loom_strings.dart';
import 'setup_scaffold.dart';
import '../application/device_link_service.dart';
import '../application/onboarding_controller.dart';

class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key});

  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  final LoomDeviceLinkService _service = LoomDeviceLinkService();
  final TextEditingController _pasteController = TextEditingController();
  LoomPendingDeviceLinkSession? _pending;
  LoomCreatedDeviceLink? _created;
  bool _initialized = false;
  bool _working = false;
  String? _error;

  bool get _scannerSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is LoomPendingDeviceLinkSession) {
      _pending = args;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _createInvitation();
    });
  }

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _createInvitation() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final onboarding = LoomOnboardingScope.of(context);
      final created = await _service.createInvitation(onboarding);
      if (!mounted) return;
      setState(() => _created = created);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _redeem(String value) async {
    final pending = _pending;
    final cleaned = value.trim();
    if (_working || pending == null || cleaned.isEmpty) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _service.redeemAndActivate(
        onboarding: LoomOnboardingScope.of(context),
        pending: pending,
        qrPayload: cleaned,
      );
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/messenger', (_) => false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _friendlyError(Object error) {
    final message = error is LoomProtocolException
        ? error.message
        : error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
    return switch (message) {
      'device_link_not_found' => tr(
        context,
        'This QR has expired or is no longer available.',
        'این QR منقضی شده یا دیگر در دسترس نیست.',
      ),
      'device_link_expired' => tr(
        context,
        'This QR has expired. Generate a new one on your signed-in device.',
        'این QR منقضی شده است. روی دستگاه واردشده یک QR جدید بسازید.',
      ),
      'device_link_token_mismatch' => tr(
        context,
        'This device-link QR is invalid.',
        'QR اتصال دستگاه معتبر نیست.',
      ),
      'device_link_account_mismatch' => tr(
        context,
        'The QR belongs to a different Loom account.',
        'این QR مربوط به یک حساب لوم دیگر است.',
      ),
      _ => message,
    };
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return pending == null ? _trustedDeviceView() : _newDeviceView(pending);
  }

  Widget _shell({
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) => LoomSetupScaffold(
    title: title,
    subtitle: subtitle,
    canPop: !_working,
    children: children,
  );

  Widget _trustedDeviceView() {
    final p = context.loom;
    final created = _created;
    return _shell(
      title: tr(context, 'Link a new device', 'اتصال دستگاه جدید'),
      subtitle: tr(
        context,
        'On the new device, sign in with your username and password first, then scan this short-lived QR. The Home Node only relays an encrypted one-time package.',
        'روی دستگاه جدید اول با نام کاربری و رمز عبور وارد شوید و بعد این QR کوتاه‌عمر را اسکن کنید. Home Node فقط یک بسته رمزگذاری‌شده و یک‌بارمصرف را منتقل می‌کند.',
      ),
      children: [
        const SizedBox(height: LoomSpacing.lg),
        LoomGlassSurface(
          strength: LoomGlassStrength.weak,
          blur: false,
          padding: const EdgeInsets.all(LoomSpacing.lg),
          child: AnimatedSwitcher(
            duration: LoomMotion.component,
            child: _working && created == null
                ? const Center(child: CircularProgressIndicator())
                : created == null
                ? Column(
                    children: [
                      Icon(
                        LoomIcons.qr_code_2_rounded,
                        size: 72,
                        color: p.textMuted,
                      ),
                      const SizedBox(height: LoomSpacing.sm),
                      FilledButton.icon(
                        onPressed: _working ? null : _createInvitation,
                        icon: const Icon(LoomIcons.refresh_rounded),
                        label: Text(tr(context, 'Generate QR', 'ساخت QR')),
                      ),
                    ],
                  )
                : Column(
                    key: ValueKey(created.linkId),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        color: Colors.white,
                        child: QrImageView(
                          data: created.qrPayload,
                          version: QrVersions.auto,
                          size: MediaQuery.sizeOf(context).width < 400
                              ? 180
                              : 250,
                          backgroundColor: Colors.white,
                          semanticsLabel: tr(
                            context,
                            'One-time Loom device-link QR',
                            'QR یک‌بارمصرف اتصال دستگاه لوم',
                          ),
                        ),
                      ),
                      const SizedBox(height: LoomSpacing.md),
                      Text(
                        tr(
                          context,
                          'Expires at ${_shortTime(created.expiresAt)}',
                          'انقضا در ${_shortTime(created.expiresAt)}',
                        ),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: p.textSecondary),
                      ),
                      const SizedBox(height: LoomSpacing.sm),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: LoomSpacing.xs,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: created.qrPayload),
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      tr(
                                        context,
                                        'Pairing code copied',
                                        'کد اتصال کپی شد',
                                      ),
                                    ),
                                  ),
                                );
                            },
                            icon: const Icon(LoomIcons.copy_rounded),
                            label: Text(tr(context, 'Copy code', 'کپی کد')),
                          ),
                          OutlinedButton.icon(
                            onPressed: _working ? null : _createInvitation,
                            icon: const Icon(LoomIcons.refresh_rounded),
                            label: Text(tr(context, 'New QR', 'QR جدید')),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: LoomSpacing.sm),
          Text(
            _error!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: p.critical),
          ),
        ],
        const SizedBox(height: LoomSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LoomIcons.lock_outline_rounded, size: 18, color: p.textMuted),
            const SizedBox(width: LoomSpacing.xs),
            Expanded(
              child: Text(
                tr(
                  context,
                  'The QR never contains your password or recovery words in plaintext. Your old signing key is not copied to the new device.',
                  'این QR هرگز رمز عبور یا واژه‌های بازیابی را به‌صورت متن ساده ندارد. کلید امضای دستگاه قبلی هم به دستگاه جدید کپی نمی‌شود.',
                ),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: p.textMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _newDeviceView(LoomPendingDeviceLinkSession pending) {
    final p = context.loom;
    return _shell(
      title: tr(context, 'Connect this device', 'اتصال این دستگاه'),
      subtitle: tr(
        context,
        'Password accepted for @${pending.username}. Now scan the QR shown on an already signed-in Loom device. After verification, this device gets its own fresh keys and message sync starts.',
        'رمز عبور برای @${pending.username} پذیرفته شد. حالا QR روی یکی از دستگاه‌های لوم که از قبل وارد حساب است را اسکن کنید. بعد از تأیید، این دستگاه کلیدهای جدید خودش را می‌گیرد و همگام‌سازی پیام‌ها شروع می‌شود.',
      ),
      children: [
        const SizedBox(height: LoomSpacing.lg),
        if (_scannerSupported)
          ClipRRect(
            borderRadius: BorderRadius.circular(LoomRadii.surface),
            child: SizedBox(
              height: 310,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    onDetect: (capture) {
                      if (_working || capture.barcodes.isEmpty) return;
                      final value = capture.barcodes.first.rawValue;
                      if (value != null &&
                          value.startsWith('loom-device-link:')) {
                        _redeem(value);
                      }
                    },
                  ),
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 2),
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                    ),
                  ),
                  if (_working)
                    ColoredBox(
                      color: Colors.black.withAlphaFraction(.35),
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
          )
        else
          LoomGlassSurface(
            strength: LoomGlassStrength.weak,
            blur: false,
            padding: const EdgeInsets.all(LoomSpacing.md),
            child: Row(
              children: [
                Icon(LoomIcons.qr_code_rounded, color: p.primary),
                const SizedBox(width: LoomSpacing.sm),
                Expanded(
                  child: Text(
                    tr(
                      context,
                      'Camera QR scanning is not available on this desktop platform. Copy the pairing code from your trusted device and paste it below.',
                      'اسکن QR با دوربین روی این پلتفرم دسکتاپ در دسترس نیست. کد اتصال را از دستگاه مورد اعتماد کپی و پایین وارد کنید.',
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: LoomSpacing.md),
        TextField(
          controller: _pasteController,
          enabled: !_working,
          minLines: 2,
          maxLines: 5,
          textDirection: TextDirection.ltr,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr(
              context,
              'Or paste pairing code',
              'یا کد اتصال را وارد کنید',
            ),
            prefixIcon: const Icon(LoomIcons.qr_code_rounded),
          ),
        ),
        const SizedBox(height: LoomSpacing.sm),
        FilledButton.icon(
          onPressed: _working ? null : () => _redeem(_pasteController.text),
          icon: _working
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LoomIcons.verified_user_outlined),
          label: Text(tr(context, 'Verify and link', 'تأیید و اتصال')),
        ),
        if (_error != null) ...[
          const SizedBox(height: LoomSpacing.sm),
          Text(
            _error!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: p.critical),
          ),
        ],
        const SizedBox(height: LoomSpacing.md),
        TextButton.icon(
          onPressed: _working
              ? null
              : () => Navigator.pushReplacementNamed(context, '/restore'),
          icon: const Icon(LoomIcons.key_rounded),
          label: Text(
            tr(
              context,
              'Use recovery words instead',
              'استفاده از واژه‌های بازیابی',
            ),
          ),
        ),
      ],
    );
  }

  String _shortTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
