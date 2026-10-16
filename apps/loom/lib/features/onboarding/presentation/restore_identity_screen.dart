import 'package:loom_design/loom_design.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../../../app/loom_strings.dart';
import '../application/onboarding_controller.dart';
import 'setup_scaffold.dart';
import 'recovery_qr_scanner.dart';
import '../application/recovery_backup.dart';

class RestoreIdentityScreen extends StatefulWidget {
  const RestoreIdentityScreen({super.key});
  @override
  State<RestoreIdentityScreen> createState() => _RestoreIdentityScreenState();
}

class _RestoreIdentityScreenState extends State<RestoreIdentityScreen>
    with WidgetsBindingObserver {
  bool foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => foreground = state == AppLifecycleState.resumed);
  }

  final words = TextEditingController();
  bool submitting = false;
  bool importing = false;
  String? localError;
  int get wordCount => words.text
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .length;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    words.dispose();
    super.dispose();
  }

  Future<void> _import({required bool qr}) async {
    if (submitting || importing) return;
    setState(() {
      importing = true;
      localError = null;
    });
    try {
      String? sentence;
      if (qr) {
        sentence = await Navigator.push<String>(
          context,
          MaterialPageRoute(builder: (_) => const LoomRecoveryQrScanner()),
        );
      } else {
        final file = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Loom recovery',
              extensions: ['loom', 'json'],
              mimeTypes: ['application/json', 'application/octet-stream'],
              uniformTypeIdentifiers: ['public.data'],
            ),
          ],
        );
        if (file == null) return;
        if (await file.length() > 4096) {
          throw const FormatException('Too large');
        }
        final bytes = await file.readAsBytes();
        try {
          sentence = LoomRecoveryBackup.parse(utf8.decode(bytes)).sentence;
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      if (mounted && sentence != null) setState(() => words.text = sentence!);
    } catch (_) {
      if (mounted) {
        setState(
          () => localError = tr(
            context,
            'This is not a supported Loom recovery file. Import the .loom file or scan the QR on your PDF.',
            'این فایل پشتیبان لوم معتبر نیست. فایل .loom را وارد کن یا QR روی PDF را اسکن کن.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> _restore() async {
    if (submitting || importing) {
      return;
    }
    if (wordCount != 24) {
      setState(
        () => localError = tr(
          context,
          'Enter all 24 words, in their original order.',
          'هر ۲۴ واژه را به‌ترتیب اصلی وارد کنید.',
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      submitting = true;
      localError = null;
    });
    try {
      final ok = await LoomOnboardingScope.of(
        context,
      ).restoreIdentityWords(words.text);
      if (!mounted || !ok) {
        return;
      }
      words.clear();
      // Sign-in owns server selection and verifies it before authentication.
      Navigator.pushReplacementNamed(context, '/sign-in');
    } finally {
      if (mounted) {
        setState(() => submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = LoomOnboardingScope.of(context);
    final busy =
        importing ||
        submitting ||
        controller.status == LoomOnboardingStatus.creatingIdentity;
    return LoomSetupScaffold(
      actions: LoomPressable(
        enabled: !busy,
        child: FilledButton(
          onPressed: busy ? null : _restore,
          child: busy
              ? const LoomBusyIndicator()
              : Text(tr(context, 'Restore account', 'بازیابی حساب')),
        ),
      ),
      canPop: !busy,
      title: tr(context, 'Bring your account back', 'حسابت را برگردان'),
      subtitle: tr(
        context,
        'Import your recovery file or scan the QR on your printed PDF. You can also enter the words. Then sign in to your original home server.',
        'فایل بازیابی را وارد کن یا QR برگهٔ PDF را اسکن کن. وارد کردن واژه‌ها هم ممکن است. سپس وارد حساب سرور اصلی خودت شو.',
      ),
      children: [
        if (controller.committedIdentity != null) ...[
          Text(
            tr(
              context,
              'This device already has an identity. Recovery can repair that same identity; replacing it with another account is not supported here. Your current identity and saved data are kept.',
              'این دستگاه از قبل هویت دارد. بازیابی می‌تواند همان هویت را ترمیم کند؛ جایگزینی آن با حساب دیگری در این دستگاه پشتیبانی نمی‌شود. هویت فعلی و اطلاعات ذخیره‌شده حفظ می‌شوند.',
            ),
          ),
          const SizedBox(height: 16),
        ],
        OutlinedButton.icon(
          onPressed: busy ? null : () => _import(qr: false),
          icon: const Icon(LoomIcons.folder_open),
          label: Text(
            tr(context, 'Import recovery file', 'وارد کردن فایل پشتیبان'),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: busy ? null : () => _import(qr: true),
          icon: const Icon(LoomIcons.qr_code_scanner_rounded),
          label: Text(
            tr(context, 'Scan printed recovery QR', 'اسکن QR برگهٔ بازیابی'),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          tr(context, 'Or enter your words', 'یا واژه‌ها را وارد کن'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 12),
        if (foreground)
          TextField(
            controller: words,
            enabled: !busy,
            minLines: 5,
            maxLines: 8,
            maxLength: 1024,
            textDirection: TextDirection.ltr,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() => localError = null),
            decoration: InputDecoration(
              labelText: tr(context, '24 recovery words', '۲۴ واژه بازیابی'),
              counterText: tr(
                context,
                '$wordCount / 24 words',
                '$wordCount از ۲۴ واژه',
              ),
              errorText: localError,
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
            'Your recovery words stay on this device. They are never sent to the server.',
            'واژه‌های بازیابی روی همین دستگاه پردازش می‌شوند و به سرور فرستاده نمی‌شوند.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
