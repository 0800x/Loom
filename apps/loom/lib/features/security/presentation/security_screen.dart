import 'dart:async';
import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../../onboarding/application/committed_recovery_backup.dart';
import '../../onboarding/application/recovery_backup_reminder.dart';
import '../../onboarding/application/recovery_file_export.dart';
import '../application/security_controller.dart';

class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  late final LoomSecurityController controller;
  final _backupReminder = LoomRecoveryBackupReminderStore();
  final _identityCore = LoomIdentityCoreV1();
  LoomRecoveryBackupStatus? _backupStatus;
  String? _backupIdentityId;
  String? _backupMessage;
  bool _exporting = false;
  int _exportEpoch = 0;
  Uint8List? _exportBytes;

  @override
  void initState() {
    super.initState();
    controller = LoomSecurityController();
    LoomAppLock.instance.addListener(_onLockChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final onboarding = LoomOnboardingScope.of(context);
      controller.load(deviceId: onboarding.receipt?.deviceId);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final identityId = LoomOnboardingScope.of(
      context,
    ).committedIdentity?.identityId;
    if (_backupIdentityId != identityId) {
      _exportEpoch++;
      _clearExportBytes();
      _backupIdentityId = identityId;
      _backupStatus = null;
      _backupMessage = null;
      unawaited(_loadBackupStatus(identityId));
    }
  }

  @override
  void dispose() {
    _exportEpoch++;
    LoomAppLock.instance.removeListener(_onLockChanged);
    _clearExportBytes();
    controller.dispose();
    super.dispose();
  }

  void _clearExportBytes() {
    final bytes = _exportBytes;
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
    _exportBytes = null;
  }

  void _onLockChanged() {
    if (LoomAppLock.instance.locked) {
      _exportEpoch++;
      _clearExportBytes();
    } else if (mounted) {
      unawaited(_loadBackupStatus(_backupIdentityId));
    }
  }

  bool _isCurrentExport(int epoch, String identityId) =>
      mounted &&
      epoch == _exportEpoch &&
      !LoomAppLock.instance.locked &&
      LoomOnboardingScope.of(context).committedIdentity?.identityId ==
          identityId;

  Future<void> _loadBackupStatus(String? identityId) async {
    if (identityId == null) return;
    final epoch = _exportEpoch;
    try {
      final status = await _backupReminder.load(identityId);
      if (_isCurrentExport(epoch, identityId)) {
        setState(() => _backupStatus = status);
      }
    } catch (_) {
      // Backup UI metadata must not interrupt the security diagnostics.
    }
  }

  Future<void> _exportRecovery(bool pdf) async {
    if (_exporting || LoomAppLock.instance.locked) return;
    final onboarding = LoomOnboardingScope.of(context);
    final identityId = onboarding.committedIdentity?.identityId;
    if (identityId == null) return;
    final epoch = ++_exportEpoch;
    setState(() {
      _exporting = true;
      _backupMessage = null;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            tr(context, 'Keep this just for you', 'این فقط برای خودت است'),
          ),
          content: Text(
            tr(
              context,
              'This recovery file and its QR are not encrypted. Anyone with a copy can recover your identity. Save it privately and keep a copy away from this device. Your password and chats are not included.',
              'این فایل و QR رمزگذاری نشده‌اند. هرکس نسخه‌ای داشته باشد می‌تواند هویتت را بازیابی کند. خصوصی ذخیره‌اش کن و یک نسخه جدا از این دستگاه نگه دار. رمز حساب و گفتگوها داخل آن نیستند.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'Cancel', 'انصراف')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                tr(context, 'Choose save location', 'انتخاب محل ذخیره'),
              ),
            ),
          ],
        ),
      );
      if (accepted != true || !_isCurrentExport(epoch, identityId)) return;
      final backup = await readCommittedLoomRecoveryBackup(
        identityCore: _identityCore,
        expectedIdentityId: identityId,
      );
      if (!_isCurrentExport(epoch, identityId)) return;
      _exportBytes = pdf ? backup.printablePdf() : backup.fileBytes;
      final result = await saveLoomRecoveryFile(
        _exportBytes!,
        pdf: pdf,
        isCurrent: () => _isCurrentExport(epoch, identityId),
      );
      if (!_isCurrentExport(epoch, identityId)) return;
      final remembered = await _backupReminder.recordExport(identityId, result);
      if (!_isCurrentExport(epoch, identityId)) return;
      await _loadBackupStatus(identityId);
      if (!_isCurrentExport(epoch, identityId)) return;
      setState(() {
        _backupMessage = switch (result) {
          LoomRecoveryExportResult.saved => tr(
            context,
            'Saved. Keep a copy somewhere private and away from this device.',
            'ذخیره شد. یک نسخه در جای خصوصی و جدا از این دستگاه نگه دار.',
          ),
          LoomRecoveryExportResult.cancelled => tr(
            context,
            'Saving was cancelled. Your reminder remains unchanged.',
            'ذخیره لغو شد. وضعیت یادآور تغییری نکرد.',
          ),
          LoomRecoveryExportResult.downloadStarted => tr(
            context,
            'Download started. Check the saved file; this does not clear your reminder.',
            'دانلود شروع شد. ذخیرهٔ فایل را بررسی کن؛ این مرحله یادآور را پاک نمی‌کند.',
          ),
        };
        if (result == LoomRecoveryExportResult.saved && !remembered) {
          _backupMessage =
              '${_backupMessage!} ${tr(context, 'The reminder could not be updated.', 'یادآور به‌روز نشد.')}';
        }
      });
    } catch (_) {
      if (_isCurrentExport(epoch, identityId)) {
        setState(
          () => _backupMessage = tr(
            context,
            'Could not export the recovery backup. Unlock this device and try again. Your existing identity is unchanged.',
            'پشتیبان بازیابی صادر نشد. قفل دستگاه را باز کن و دوباره امتحان کن. هویت فعلی تغییری نکرده است.',
          ),
        );
      }
    } finally {
      _clearExportBytes();
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _recoveryBackupSection(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        tr(context, 'Recovery backup', 'پشتیبان بازیابی'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: LoomSpacing.xs),
      Text(switch (_backupStatus) {
        LoomRecoveryBackupStatus.deferred => tr(
          context,
          'You postponed your recovery backup. Keep one before losing access to this device.',
          'پشتیبان را به بعد موکول کرده‌ای. قبل از از دست دادن دسترسی به این دستگاه، نسخه‌ای نگه دار.',
        ),
        LoomRecoveryBackupStatus.saved => tr(
          context,
          'A recovery file was saved. Keep it safe; this app cannot check whether your copy still exists.',
          'فایل بازیابی ذخیره شده است. امن نگهش دار؛ برنامه نمی‌تواند بررسی کند نسخه‌ات هنوز وجود دارد یا نه.',
        ),
        LoomRecoveryBackupStatus.manuallyConfirmed => tr(
          context,
          'You confirmed keeping a manual backup. Keep all 24 words safe.',
          'نگهداری پشتیبان دستی را تأیید کرده‌ای. هر ۲۴ واژه را امن نگه دار.',
        ),
        null => tr(
          context,
          'Keep a recovery file or printable QR in a private place. Loom cannot recover a lost identity for you.',
          'فایل بازیابی یا QR چاپی را در جای خصوصی نگه دار. لوم نمی‌تواند هویت از دست رفته را برایت بازیابی کند.',
        ),
      }),
      const SizedBox(height: LoomSpacing.sm),
      OutlinedButton.icon(
        onPressed: _exporting ? null : () => _exportRecovery(false),
        icon: const Icon(LoomIcons.download_rounded),
        label: Text(tr(context, 'Save recovery file', 'ذخیرهٔ فایل پشتیبان')),
      ),
      OutlinedButton.icon(
        onPressed: _exporting ? null : () => _exportRecovery(true),
        icon: const Icon(LoomIcons.description_outlined),
        label: Text(
          tr(context, 'Save printable PDF + QR', 'ذخیرهٔ PDF چاپی + QR'),
        ),
      ),
      if (_exporting) const Center(child: LoomBusyIndicator()),
      if (_backupMessage != null)
        Semantics(liveRegion: true, child: Text(_backupMessage!)),
      const SizedBox(height: LoomSpacing.lg),
    ],
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final palette = context.loom;
      return Scaffold(
        appBar: LoomGlassAppBar(title: Text(tr(context, 'Security', 'امنیت'))),
        body: controller.loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(LoomSpacing.md),
                children: <Widget>[
                  if (LoomOnboardingScope.of(context).committedIdentity != null)
                    _recoveryBackupSection(context),
                  if (controller.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: LoomSpacing.md),
                      child: Text(
                        controller.error!,
                        style: TextStyle(color: palette.critical),
                      ),
                    ),
                  Text(
                    tr(context, 'Cryptographic identity', 'هویت رمزنگاری‌شده'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  _SecurityValue(
                    label: tr(
                      context,
                      'Identity fingerprint',
                      'اثر انگشت هویت',
                    ),
                    value:
                        controller.identity?.fingerprint ??
                        tr(
                          context,
                          'No local identity',
                          'هویت محلی وجود ندارد',
                        ),
                    ltr: true,
                  ),
                  const SizedBox(height: LoomSpacing.lg),
                  Text(
                    tr(context, 'This device', 'این دستگاه'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  _SecurityValue(
                    label: tr(
                      context,
                      'Device fingerprint',
                      'اثر انگشت دستگاه',
                    ),
                    value:
                        controller.localDevice?.fingerprint ??
                        tr(
                          context,
                          'Device session unavailable',
                          'نشست دستگاه در دسترس نیست',
                        ),
                    ltr: true,
                  ),
                  _StatusRow(
                    label: tr(
                      context,
                      'Fingerprint integrity',
                      'یکپارچگی اثر انگشت',
                    ),
                    valid: controller.fingerprintValid,
                  ),
                  _StatusRow(
                    label: tr(context, 'Device signature', 'امضای دستگاه'),
                    valid: controller.selfSignatureValid,
                  ),
                  _StatusRow(
                    label: tr(context, 'Identity binding', 'پیوند هویت'),
                    valid: controller.identityBindingValid,
                  ),
                  _SecurityValue(
                    label: tr(context, 'Trust state', 'وضعیت اعتماد'),
                    value: controller.localTrust?.name ?? '—',
                  ),
                  const SizedBox(height: LoomSpacing.lg),
                  Text(
                    tr(context, 'Sessions & devices', 'نشست‌ها و دستگاه‌ها'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  LoomSettingsGroup(
                    children: [
                      LoomSettingsRow(
                        icon: LoomIcons.qr_code_rounded,
                        title: tr(
                          context,
                          'Link a new device',
                          'اتصال دستگاه جدید',
                        ),
                        subtitle: tr(
                          context,
                          'Generate a short-lived QR for a password-authenticated new device',
                          'ساخت QR کوتاه‌عمر برای دستگاه جدیدی که با رمز عبور وارد شده',
                        ),
                        showDivider: false,
                        onTap: () =>
                            Navigator.pushNamed(context, '/link-device'),
                      ),
                    ],
                  ),
                  const SizedBox(height: LoomSpacing.lg),
                  Text(
                    tr(context, 'Security events', 'رویدادهای امنیتی'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  if (controller.recentEvents.isEmpty)
                    Text(
                      tr(
                        context,
                        'No local security events recorded.',
                        'هیچ رویداد امنیتی محلی ثبت نشده است.',
                      ),
                    )
                  else
                    ...controller.recentEvents.map(
                      (event) => LoomSettingsRow(
                        icon: LoomIcons.key_rounded,
                        title: _eventLabel(context, event.kind.name),
                        subtitle: event.createdAt.toLocal().toString(),
                        trailing: const SizedBox.shrink(),
                      ),
                    ),
                  const SizedBox(height: LoomSpacing.xl),
                  Text(
                    tr(
                      context,
                      'MLS group encryption is not active in this build. The native RFC 9420 boundary is defined, but no unvalidated engine is presented as working security.',
                      'رمزنگاری گروهی MLS در این نسخه فعال نیست. مرز بومی RFC 9420 تعریف شده است، اما هیچ موتور تأییدنشده‌ای به‌عنوان امنیت فعال نمایش داده نمی‌شود.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
      );
    },
  );
}

String _eventLabel(BuildContext context, String kind) => switch (kind) {
  'deviceAdded' => tr(context, 'Device added', 'دستگاه افزوده شد'),
  'deviceVerified' => tr(context, 'Device verified', 'دستگاه تأیید شد'),
  'deviceKeyChanged' => tr(
    context,
    'Device key changed',
    'کلید دستگاه تغییر کرد',
  ),
  'deviceRevoked' => tr(context, 'Device revoked', 'دستگاه لغو شد'),
  'identityKeyChanged' => tr(
    context,
    'Identity key changed',
    'کلید هویت تغییر کرد',
  ),
  _ => tr(context, 'Security event', 'رویداد امنیتی'),
};

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.valid});
  final String label;
  final bool? valid;

  @override
  Widget build(BuildContext context) {
    final palette = context.loom;
    final text = switch (valid) {
      true => tr(context, 'Valid', 'معتبر'),
      false => tr(context, 'Invalid', 'نامعتبر'),
      null => tr(context, 'Unavailable', 'در دسترس نیست'),
    };
    final color = switch (valid) {
      true => palette.connectivity,
      false => palette.critical,
      null => palette.textMuted,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LoomSpacing.xs),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _SecurityValue extends StatelessWidget {
  const _SecurityValue({
    required this.label,
    required this.value,
    this.ltr = false,
  });
  final String label;
  final String value;
  final bool ltr;

  @override
  Widget build(BuildContext context) {
    final valueText = SelectableText(value, textAlign: TextAlign.end);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LoomSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label)),
          const SizedBox(width: LoomSpacing.md),
          Flexible(
            child: ltr
                ? Directionality(
                    textDirection: TextDirection.ltr,
                    child: valueText,
                  )
                : valueText,
          ),
        ],
      ),
    );
  }
}
