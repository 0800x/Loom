import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/loom_strings.dart';
import '../application/onboarding_controller.dart';
import 'setup_scaffold.dart';
import '../application/recovery_backup.dart';
import '../application/recovery_file_export.dart';
import '../application/recovery_backup_reminder.dart';

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key});
  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen>
    with WidgetsBindingObserver {
  bool exporting = false;
  String? exportMessage;
  bool acknowledged = false;
  bool backupSaved = false;
  bool submitting = false;
  bool revealed = false;
  bool hasRevealed = false;
  final _backupReminder = LoomRecoveryBackupReminderStore();
  int _exportEpoch = 0;
  Uint8List? _activeExportBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LoomAppLock.instance.addListener(_onLockChanged);
  }

  @override
  void dispose() {
    _exportEpoch++;
    _clearExportBytes();
    LoomAppLock.instance.removeListener(_onLockChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onLockChanged() {
    if (LoomAppLock.instance.locked) {
      _exportEpoch++;
      _clearExportBytes();
      if (mounted) setState(() => revealed = false);
    }
  }

  void _clearExportBytes() {
    final bytes = _activeExportBytes;
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
    _activeExportBytes = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && revealed) {
      setState(() => revealed = false);
    }
  }

  Future<void> _export(bool pdf) async {
    if (exporting || submitting || LoomAppLock.instance.locked) return;
    final onboarding = LoomOnboardingScope.of(context);
    final pending = onboarding.pendingIdentity;
    if (pending == null) return;
    final epoch = ++_exportEpoch;
    bool isCurrent() =>
        mounted &&
        epoch == _exportEpoch &&
        !LoomAppLock.instance.locked &&
        onboarding.pendingIdentity == pending;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          tr(context, 'Keep this just for you', 'این فقط برای خودت است'),
        ),
        content: Text(
          tr(
            context,
            'This file and its QR are not encrypted. Anyone with a copy can recover your identity. Save it privately, then move it to a safe place. Your password and chats are not included.',
            'این فایل و QR رمزگذاری نشده‌اند. هرکس نسخه‌ای داشته باشد می‌تواند هویتت را بازیابی کند. خصوصی ذخیره‌اش کن و بعد به جای امن منتقلش کن. رمز حساب و گفتگوها داخل آن نیستند.',
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
    if (!isCurrent() || accepted != true) {
      return;
    }
    setState(() {
      exporting = true;
      exportMessage = null;
      revealed = false;
    });
    Uint8List? bytes;
    try {
      final backup = LoomRecoveryBackup(words: pending.recovery.mnemonicWords);
      bytes = pdf ? backup.printablePdf() : backup.fileBytes;
      _activeExportBytes = bytes;
      final saved = await saveLoomRecoveryFile(
        bytes,
        pdf: pdf,
        isCurrent: isCurrent,
      );
      if (!isCurrent()) return;
      final remembered = await _backupReminder.recordExport(
        pending.identity.identityId,
        saved,
      );
      if (!isCurrent()) return;
      setState(() {
        backupSaved = backupSaved || saved == LoomRecoveryExportResult.saved;
        exportMessage = saved == LoomRecoveryExportResult.downloadStarted
            ? tr(
                context,
                'Download started. Check that the file is saved before leaving.',
                'دانلود شروع شد. پیش از خروج بررسی کن فایل ذخیره شده باشد.',
              )
            : saved == LoomRecoveryExportResult.saved
            ? tr(
                context,
                'Saved. Move it somewhere private and safe; keep a copy away from this device.',
                'ذخیره شد. به جای خصوصی و امن منتقلش کن؛ یک نسخه هم جدا از این دستگاه نگه دار.',
              )
            : tr(
                context,
                'Saving was cancelled. You can try again or write the words down.',
                'ذخیره لغو شد. دوباره امتحان کن یا واژه‌ها را یادداشت کن.',
              );
        if (saved == LoomRecoveryExportResult.saved && !remembered) {
          exportMessage =
              '${exportMessage!} ${tr(context, 'The backup-status reminder could not be updated on this device.', 'وضعیت یادآور پشتیبان روی این دستگاه به‌روز نشد.')}';
        }
      });
    } catch (_) {
      if (isCurrent()) {
        setState(
          () => exportMessage = tr(
            context,
            'Could not save on this device. Try again, or write all 24 words down.',
            'ذخیره روی این دستگاه ممکن نشد. دوباره امتحان کن یا هر ۲۴ واژه را یادداشت کن.',
          ),
        );
      }
    } finally {
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      _activeExportBytes = null;
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> _finish({required bool defer}) async {
    if (exporting || submitting) return;
    final onboarding = LoomOnboardingScope.of(context);
    final pending = onboarding.pendingIdentity;
    if (pending == null) return;
    if (defer) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            tr(context, 'Keep a recovery backup', 'پشتیبان بازیابی را نگه دار'),
          ),
          content: Text(
            tr(
              context,
              'If you lose access to your devices without a backup, Loom cannot recover your identity. Continue for now?',
              'اگر بدون پشتیبان دسترسی به دستگاه‌ها را از دست بدهی، لوم نمی‌تواند هویتت را برگرداند. فعلاً ادامه می‌دهی؟',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'Save a backup', 'ذخیرهٔ پشتیبان')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'Continue for now', 'فعلاً ادامه')),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
    }
    setState(() {
      submitting = true;
      revealed = false;
    });
    final remembered = defer
        ? await _backupReminder.defer(pending.identity.identityId)
        : acknowledged && !backupSaved
        ? await _backupReminder.confirmManualBackup(pending.identity.identityId)
        : true;
    if (!mounted || onboarding.pendingIdentity != pending) {
      if (mounted) setState(() => submitting = false);
      return;
    }
    final ok = await onboarding.commitAndRegister();
    if (!mounted) return;
    setState(() => submitting = false);
    if (ok) {
      if (!remembered) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'The backup reminder could not be saved. Back up from Settings → Devices → Recovery backup.',
                'یادآور ذخیره نشد. از تنظیمات ← دستگاه‌ها ← پشتیبان بازیابی، نسخهٔ پشتیبان بگیر.',
              ),
            ),
          ),
        );
      }
      if (defer) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'You deferred your recovery backup. Save one from Settings → Devices → Recovery backup.',
                'پشتیبان را به بعد موکول کردی. از تنظیمات ← دستگاه‌ها ← پشتیبان بازیابی، نسخه‌ای ذخیره کن.',
              ),
            ),
          ),
        );
      }
      Navigator.pushNamedAndRemoveUntil(
        context,
        '/ready',
        (route) => route.isFirst,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = LoomOnboardingScope.of(context).pendingIdentity;
    final p = context.loom;
    if (pending == null) {
      return LoomSetupScaffold(
        step: 3,
        title: tr(
          context,
          'Let’s start with your profile',
          'اول پروفایل را بسازیم',
        ),
        subtitle: tr(
          context,
          'Your backup will be created in the next step.',
          'پشتیبان در مرحلهٔ بعد ساخته می‌شود.',
        ),
        children: [
          FilledButton(
            onPressed: () =>
                Navigator.pushReplacementNamed(context, '/identity'),
            child: Text(tr(context, 'Create profile', 'ساخت پروفایل')),
          ),
        ],
      );
    }
    final words = pending.recovery.mnemonicWords;
    return LoomSetupScaffold(
      actions: FilledButton(
        onPressed: exporting || submitting
            ? null
            : () => _finish(defer: !(backupSaved || acknowledged)),
        child: submitting
            ? const LoomBusyIndicator()
            : Text(tr(context, 'Finish setup', 'تکمیل راه‌اندازی')),
      ),
      step: 3,
      canPop: !exporting && !submitting,
      title: tr(context, 'Keep a way back', 'راه برگشت را نگه دار'),
      subtitle: tr(
        context,
        'Save a recovery file or printable QR. You can also keep the words as a manual backup.',
        'فایل پشتیبان یا QR چاپی ذخیره کن. یادداشت واژه‌ها هم به‌عنوان روش دستی در دسترس است.',
      ),
      children: [
        LoomGlassSurface(
          strength: LoomGlassStrength.weak,
          blur: false,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    tr(context, 'Recovery words', 'واژه‌های بازیابی'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  TextButton.icon(
                    onPressed: exporting
                        ? null
                        : () => setState(() {
                            revealed = !revealed;
                            hasRevealed = true;
                          }),
                    icon: Icon(
                      revealed
                          ? LoomIcons.visibility_off_outlined
                          : LoomIcons.visibility_outlined,
                    ),
                    label: Text(
                      revealed
                          ? tr(context, 'Hide', 'پنهان')
                          : tr(context, 'Reveal', 'نمایش'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Never animate an outgoing secret: hiding removes the words now.
              if (!revealed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  child: Column(
                    children: [
                      Icon(
                        LoomIcons.lock_outline_rounded,
                        color: p.primary,
                        size: 32,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        tr(
                          context,
                          'Only reveal when you’re ready to save them.',
                          'وقتی آمادهٔ یادداشت هستید، «نمایش» را بزنید.',
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final columns =
                          MediaQuery.textScalerOf(context).scale(14) > 22
                          ? 1
                          : constraints.maxWidth >= 420
                          ? 3
                          : 2;
                      final width =
                          (constraints.maxWidth - 8 * (columns - 1)) / columns;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < words.length; i++)
                            Container(
                              width: width,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: p.surfaceMuted,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${i + 1}. ${words[i]}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        if (revealed) ...[
          const SizedBox(height: 16),
          Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: ExcludeSemantics(
              child: QrImageView(
                data: LoomRecoveryBackup(words: words).encoded,
                size: 232,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: !submitting && !exporting ? () => _export(false) : null,
          icon: const Icon(LoomIcons.download_rounded),
          label: Text(tr(context, 'Save recovery file', 'ذخیرهٔ فایل پشتیبان')),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: !submitting && !exporting ? () => _export(true) : null,
          icon: const Icon(LoomIcons.description_outlined),
          label: Text(
            tr(context, 'Save printable PDF + QR', 'ذخیرهٔ PDF چاپی + QR'),
          ),
        ),
        if (exporting)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: LoomBusyIndicator()),
          ),
        if (exportMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Semantics(liveRegion: true, child: Text(exportMessage!)),
          ),
        const SizedBox(height: 20),
        Text(
          tr(
            context,
            'Anyone with these words can access your identity. Loom cannot recover them for you.',
            'هرکس این واژه‌ها را داشته باشد می‌تواند به هویت شما دسترسی پیدا کند. لوم نمی‌تواند آن‌ها را برای شما بازیابی کند.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: acknowledged,
          onChanged: hasRevealed && !exporting && !submitting
              ? (value) => setState(() => acknowledged = value ?? false)
              : null,
          title: Text(
            tr(
              context,
              'I saved all 24 words in a safe place.',
              'هر ۲۴ واژه را در جای امن ذخیره کردم.',
            ),
          ),
        ),
        const SizedBox(height: 16),

        if (!backupSaved)
          TextButton(
            onPressed: exporting || submitting
                ? null
                : () => _finish(defer: true),
            child: Text(tr(context, 'Back up later', 'پشتیبان‌گیری بعداً')),
          ),
        if (hasRevealed)
          TextButton(
            onPressed: exporting || submitting
                ? null
                : () => Navigator.pushNamed(context, '/recovery-verify'),
            child: Text(
              tr(
                context,
                'Check words manually (optional)',
                'بررسی دستی واژه‌ها (اختیاری)',
              ),
            ),
          ),
        if (LoomOnboardingScope.of(context).errorMessage != null)
          Text(
            LoomOnboardingScope.of(context).errorMessage!,
            style: TextStyle(color: p.critical),
          ),
      ],
    );
  }
}
