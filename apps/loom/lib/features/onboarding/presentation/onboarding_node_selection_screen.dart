import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../../nodes/application/local_https_trust.dart';

import '../../../app/loom_strings.dart';
import '../../nodes/application/node_directory_controller.dart';
import 'onboarding_flow.dart';
import 'setup_scaffold.dart';
import '../../nodes/application/node_share_link.dart';
import '../../nodes/presentation/node_qr_screen.dart';

class LoomOnboardingNodeSelectionScreen extends StatefulWidget {
  const LoomOnboardingNodeSelectionScreen({super.key});

  @override
  State<LoomOnboardingNodeSelectionScreen> createState() =>
      _LoomOnboardingNodeSelectionScreenState();
}

class _LoomOnboardingNodeSelectionScreenState
    extends State<LoomOnboardingNodeSelectionScreen> {
  final manualDomain = TextEditingController();
  LoomNodeSelectionPurpose purpose = LoomNodeSelectionPurpose.register;
  bool purposeRead = false;
  bool selecting = false;
  bool scanning = false;
  bool verifiedHere = false;
  String? domainError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final controller = LoomNodeDirectoryScope.of(context);
      if (controller.state == LoomNodeDirectoryState.idle) {
        controller.refreshRegistry();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (purposeRead) {
      return;
    }
    purposeRead = true;
    final argument = ModalRoute.of(context)?.settings.arguments;
    if (argument is LoomNodeSelectionPurpose) {
      purpose = argument;
    }
  }

  @override
  void dispose() {
    manualDomain.dispose();
    super.dispose();
  }

  Future<void> _manageLocalCertificates() async {
    final fingerprints = await LoomLocalHttpsTrust.fingerprints();
    if (!mounted) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          tr(context, 'Local HTTPS certificates', 'گواهی‌های HTTPS محلی'),
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr(
                    context,
                    'Select a certificate to remove its trust. Restart Loom after removal.',
                    'برای حذف اعتماد، گواهی را انتخاب کنید. سپس Loom را دوباره باز کنید.',
                  ),
                ),
                for (final fingerprint in fingerprints)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, fingerprint),
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(fingerprint),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr(context, 'Close', 'بستن')),
          ),
        ],
      ),
    );
    if (selected == null) return;
    await LoomLocalHttpsTrust.forget(selected);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr(
            context,
            'Certificate removed. Restart Loom to apply.',
            'گواهی حذف شد. برای اعمال تغییر، Loom را دوباره باز کنید.',
          ),
        ),
      ),
    );
  }

  Future<void> _trustLocalCertificate() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Public certificate',
            extensions: ['pem', 'crt'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      if (await file.length() > LoomLocalHttpsTrust.maximumBytes) {
        throw const FormatException('Certificate is too large.');
      }
      final bytes = await file.readAsBytes();
      final fingerprint = await LoomLocalHttpsTrust.fingerprint(bytes);
      if (!mounted) return;
      var checked = false;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text(
              tr(
                context,
                'Trust local HTTPS certificate',
                'اعتماد به گواهی HTTPS محلی',
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(
                      context,
                      'Compare this SHA256 fingerprint with the server installer using a trusted channel. Import only the public certificate; never its private key.',
                      'اثر انگشت SHA256 را از یک مسیر مطمئن با خروجی نصب سرور مقایسه کنید. فقط گواهی عمومی را وارد کنید؛ هرگز کلید خصوصی را منتقل نکنید.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: SelectableText(fingerprint),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: checked,
                    onChanged: (value) =>
                        setDialogState(() => checked = value ?? false),
                    title: Text(
                      tr(
                        context,
                        'I checked the fingerprint on my server',
                        'اثر انگشت را روی سرور خودم بررسی کردم',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(tr(context, 'Cancel', 'لغو')),
              ),
              FilledButton(
                onPressed: checked
                    ? () => Navigator.pop(dialogContext, true)
                    : null,
                child: Text(
                  tr(context, 'Trust certificate', 'اعتماد به گواهی'),
                ),
              ),
            ],
          ),
        ),
      );
      if (accepted != true) return;
      await LoomLocalHttpsTrust.accept(bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              context,
              'Certificate saved. Restart Loom before connecting to the local server.',
              'گواهی ذخیره شد. پیش از اتصال به سرور محلی، Loom را دوباره باز کنید.',
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              context,
              'Could not import this public certificate. No TLS checks were disabled.',
              'گواهی عمومی وارد نشد. هیچ بررسی TLS غیرفعال نشده است.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _scan() async {
    if (selecting || scanning) return;
    setState(() => scanning = true);
    try {
      final raw = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const LoomNodeQrScanner()),
      );
      if (!mounted || raw == null) return;
      final link = LoomNodeShareLink.parse(raw);
      manualDomain.text = link.endpoint.authority;
      await _select(
        () => LoomNodeDirectoryScope.of(context).discoverAndSelectDomain(
          link.endpoint.authority,
          expectedNodeId: link.nodeId,
          expectedFingerprint: link.fingerprint,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => domainError = tr(
            context,
            'Could not read this server QR. Try again or enter its address.',
            'خواندن QR سرور ممکن نشد؛ دوباره امتحان کن یا آدرس بده.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  void _continue() {
    final directory = LoomNodeDirectoryScope.of(context);
    if (!verifiedHere ||
        !directory.selectedNodeVerified ||
        (purpose == LoomNodeSelectionPurpose.register &&
            directory.selectedLiveInfo?.registration != 'open')) {
      return;
    }
    if (purpose == LoomNodeSelectionPurpose.signIn) {
      Navigator.pop(context);
    } else {
      Navigator.pushNamed(context, '/identity');
    }
  }

  Future<void> _discoverManual() async {
    if (selecting) {
      return;
    }
    if (manualDomain.text.trim().isEmpty) {
      setState(
        () => domainError = tr(
          context,
          'Enter your server address.',
          'نشانی سرور را وارد کنید.',
        ),
      );
      return;
    }
    setState(() => domainError = null);
    await _select(
      () => LoomNodeDirectoryScope.of(
        context,
      ).discoverAndSelectDomain(manualDomain.text),
    );
  }

  Future<void> _selectNode(LoomNodeDescriptor node) => _select(
    () => LoomNodeDirectoryScope.of(context).selectRegistryNode(node),
  );

  Future<void> _select(Future<void> Function() verify) async {
    if (selecting) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      selecting = true;
      verifiedHere = false;
    });
    try {
      await verify();
      if (mounted && LoomNodeDirectoryScope.of(context).selectedNodeVerified) {
        setState(() => verifiedHere = true);
      }
    } finally {
      if (mounted) {
        setState(() => selecting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = LoomNodeDirectoryScope.of(context);
    final palette = context.loom;
    final loading =
        scanning ||
        selecting ||
        controller.state == LoomNodeDirectoryState.loading;
    final signingIn = purpose == LoomNodeSelectionPurpose.signIn;
    return LoomSetupScaffold(
      step: signingIn ? null : 1,
      canPop: !selecting,
      title: tr(
        context,
        'Choose your home server',
        'سرور میزبان را انتخاب کنید',
      ),
      subtitle: signingIn
          ? tr(
              context,
              'Use the server where you created your account.',
              'سروری را انتخاب کنید که حسابتان روی آن ساخته شده است.',
            )
          : tr(
              context,
              'Scan its QR, enter an address or choose a verified server.',
              'QR را اسکن کنید، نشانی بدهید یا سرور تأییدشده‌ای انتخاب کنید.',
            ),
      actions: verifiedHere && controller.selectedNodeVerified
          ? FilledButton(
              onPressed:
                  loading ||
                      (!signingIn &&
                          controller.selectedLiveInfo!.registration != 'open')
                  ? null
                  : _continue,
              child: Text(
                tr(context, 'Continue with this server', 'ادامه با این سرور'),
              ),
            )
          : null,
      children: [
        LoomGlassSurface(
          blur: false,
          radius: LoomRadii.surface,
          strength: LoomGlassStrength.standard,
          padding: const EdgeInsets.all(LoomSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: loading ? null : _scan,
                icon: const Icon(LoomIcons.qr_code_scanner_rounded),
                label: Text(tr(context, 'Scan server QR', 'اسکن QR سرور')),
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  context,
                  'Got a QR from your server? Point your camera at it.',
                  'سرورت QR دارد؟ دوربین را روبه‌روی آن بگیر.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Text(
                tr(context, 'Have a server address?', 'نشانی سرور را دارید؟'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: LoomSpacing.sm),
              Directionality(
                textDirection: TextDirection.ltr,
                child: TextField(
                  controller: manualDomain,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  enabled: !loading,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: loading ? null : (_) => _discoverManual(),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(LoomIcons.dns_outlined),
                    labelText: tr(context, 'Server address', 'نشانی سرور'),
                    hintText: 'chat.example.org',
                    errorText: domainError,
                  ),
                ),
              ),
              const SizedBox(height: LoomSpacing.sm),
              FilledButton.icon(
                onPressed: loading ? null : _discoverManual,
                icon: selecting
                    ? const LoomBusyIndicator()
                    : const Icon(LoomIcons.verified_user_outlined),
                label: Text(tr(context, 'Check this server', 'بررسی این سرور')),
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: loading ? null : _trustLocalCertificate,
          icon: const Icon(LoomIcons.verified_user_outlined),
          label: Text(
            tr(
              context,
              'Import local HTTPS certificate',
              'واردکردن گواهی HTTPS محلی',
            ),
          ),
        ),
        TextButton(
          onPressed: loading ? null : _manageLocalCertificates,
          child: Text(
            tr(
              context,
              'Manage local HTTPS trust',
              'مدیریت اعتماد به HTTPS محلی',
            ),
          ),
        ),
        if (verifiedHere && controller.selectedNodeVerified) ...[
          const SizedBox(height: 16),
          LoomGlassSurface(
            blur: false,
            radius: 24,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      LoomIcons.verified_user_outlined,
                      color: palette.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        tr(
                          context,
                          'Server identity verified',
                          'هویت سرور تأیید شد',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  controller.selectedEndpoint!.authority,
                  textDirection: TextDirection.ltr,
                ),
                const SizedBox(height: 8),
                Text(
                  _registration(
                    context,
                    controller.selectedLiveInfo!.registration,
                  ),
                ),
                const SizedBox(height: 16),

                if (!signingIn &&
                    controller.selectedLiveInfo!.registration != 'open') ...[
                  const SizedBox(height: 12),
                  Text(
                    tr(
                      context,
                      'This server is not accepting open sign-ups. Choose another server or sign in to an existing account.',
                      'ثبت‌نام آزاد روی این سرور ممکن نیست. سرور دیگری انتخاب کن یا وارد حساب قبلی شو.',
                    ),
                  ),
                  TextButton(
                    onPressed: loading
                        ? null
                        : () => Navigator.pushNamed(context, '/sign-in'),
                    child: Text(
                      tr(context, 'I have an account here', 'اینجا حساب دارم'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (controller.errorMessage != null) ...[
          const SizedBox(height: LoomSpacing.sm),
          Text(
            controller.errorMessage!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: palette.critical),
          ),
        ],
        const SizedBox(height: LoomSpacing.xl),
        Row(
          children: [
            Expanded(
              child: Text(
                tr(context, 'Available servers', 'سرورهای موجود'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (loading)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              IconButton(
                onPressed: controller.refreshRegistry,
                icon: const Icon(LoomIcons.refresh_rounded),
                tooltip: tr(context, 'Refresh', 'به‌روزرسانی'),
              ),
          ],
        ),
        const SizedBox(height: LoomSpacing.xs),
        if (controller.nodes.isEmpty && !loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: LoomSpacing.lg),
            child: Text(
              tr(
                context,
                'The server list is empty. Enter your server address above or try refreshing.',
                'فهرست سرورها خالی است. نشانی سرور را در بالا وارد کنید یا فهرست را دوباره دریافت کنید.',
              ),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.textMuted),
            ),
          )
        else
          for (final node in controller.nodes.take(30)) ...[
            _NodeChoice(
              node: node,
              onTap: loading ? null : () => _selectNode(node),
            ),
            const SizedBox(height: LoomSpacing.xs),
          ],
      ],
    );
  }
}

class _NodeChoice extends StatelessWidget {
  const _NodeChoice({required this.node, required this.onTap});

  final LoomNodeDescriptor node;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.loom;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LoomRadii.surface),
      child: LoomGlassSurface(
        strength: LoomGlassStrength.weak,
        blur: false,
        padding: const EdgeInsets.all(LoomSpacing.md),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.primary.withAlphaFraction(.10),
                borderRadius: BorderRadius.circular(LoomRadii.control),
              ),
              child: const Icon(LoomIcons.hub_outlined),
            ),
            const SizedBox(width: LoomSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      node.domain,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: LoomSpacing.xxs),
                  Text(
                    node.federation
                        ? tr(
                            context,
                            'Federation supported · ${_registration(context, node.registration)}',
                            'پشتیبانی از فدریشن · ${_registration(context, node.registration)}',
                          )
                        : tr(
                            context,
                            'Local server · ${_registration(context, node.registration)}',
                            'سرور مستقل · ${_registration(context, node.registration)}',
                          ),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            const LoomDirectionalIcon(LoomIcons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

String _registration(BuildContext context, String value) => switch (value) {
  'open' => tr(context, 'Sign-up open', 'ثبت‌نام باز'),
  'approval' => tr(context, 'Operator approval required', 'نیاز به تأیید مدیر'),
  'closed' => tr(context, 'Sign-up closed', 'ثبت‌نام بسته'),
  'invite' || 'invite_only' => tr(context, 'Invite required', 'نیاز به دعوت'),
  _ => tr(context, 'Check sign-up availability', 'بررسی امکان ثبت‌نام'),
};
