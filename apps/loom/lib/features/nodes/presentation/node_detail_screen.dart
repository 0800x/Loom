import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';
import '../application/node_directory_controller.dart';
import '../application/node_share_link.dart';
import 'node_qr_screen.dart';

class NodeDetailScreen extends StatelessWidget {
  const NodeDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = LoomNodeDirectoryScope.of(context);
    final node = controller.selectedNode;
    final live = controller.selectedLiveInfo;
    final p = context.loom;
    if (node == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: FilledButton(
              onPressed: () =>
                  Navigator.pushReplacementNamed(context, '/nodes'),
              child: Text(tr(context, 'Choose a Node', 'یک Node انتخاب کنید')),
            ),
          ),
        ),
      );
    }
    String capacity() {
      if (live?.capacityLimit == null) return '—';
      if (live?.capacityUsed == null) return '${live!.capacityLimit}';
      return '${live!.capacityUsed} / ${live.capacityLimit}';
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(LoomSpacing.md),
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: Navigator.of(context).pop,
                      icon: const Icon(LoomIcons.arrow_back_rounded),
                    ),
                    const SizedBox(width: LoomSpacing.xs),
                    const LoomRouteMark(),
                    const SizedBox(width: LoomSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            node.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(node.domain),
                          ),
                        ],
                      ),
                    ),
                    _VerificationPill(
                      verified: controller.selectedNodeVerified,
                    ),
                  ],
                ),
                const SizedBox(height: LoomSpacing.ml),
                if (controller.errorMessage != null)
                  Text(
                    controller.errorMessage!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: p.critical),
                  ),
                _Section(
                  title: tr(context, 'Node identity', 'هویت Node'),
                  children: [
                    _Info(
                      tr(context, 'Node ID', 'شناسه Node'),
                      node.nodeId,
                      ltr: true,
                    ),
                    _Info(
                      tr(context, 'Fingerprint', 'اثر انگشت'),
                      node.fingerprint,
                      ltr: true,
                    ),
                    _Info(
                      tr(context, 'Operator country', 'کشور اپراتور'),
                      node.operatorCountry,
                    ),
                    _Info(
                      tr(context, 'Network jurisdiction', 'حوزه قضایی شبکه'),
                      node.networkLocation,
                    ),
                    _Info(
                      tr(context, 'Operator', 'اپراتور'),
                      node.operatorName ?? '—',
                    ),
                  ],
                ),
                _Section(
                  title: tr(context, 'Connection', 'اتصال'),
                  children: [
                    _Info(
                      'TLS',
                      controller.selectedEndpoint?.scheme == 'https'
                          ? tr(context, 'Required', 'الزامی')
                          : '—',
                    ),
                    _Info(
                      tr(context, 'Protocol', 'پروتکل'),
                      live?.protocolVersion ?? node.protocols.join(', '),
                      ltr: true,
                    ),
                    _Info(
                      tr(context, 'Server version', 'نسخه سرور'),
                      live?.serverVersion ?? '—',
                      ltr: true,
                    ),
                    _Info(
                      tr(context, 'Federation mode', 'حالت Federation'),
                      live?.federationMode ??
                          (node.federation
                              ? tr(context, 'Enabled', 'فعال')
                              : tr(context, 'Disabled', 'غیرفعال')),
                    ),
                    _Info(
                      tr(context, 'Registration', 'ثبت‌نام'),
                      live?.registration ?? node.registration,
                    ),
                    _Info(tr(context, 'Capacity', 'ظرفیت'), capacity()),
                  ],
                ),
                _Section(
                  title: tr(context, 'Features', 'قابلیت‌ها'),
                  children: [
                    for (final capability
                        in (live?.capabilities ?? node.capabilities))
                      _Info(
                        capability,
                        tr(context, 'Supported', 'پشتیبانی می‌شود'),
                      ),
                  ],
                ),
                const SizedBox(height: LoomSpacing.md),
                Wrap(
                  spacing: LoomSpacing.xs,
                  runSpacing: LoomSpacing.xs,
                  children: [
                    FilledButton(
                      onPressed: controller.selectedNodeVerified
                          ? () => Navigator.pushNamed(context, '/identity')
                          : null,
                      child: Text(
                        tr(context, 'Register Here', 'ثبت‌نام در این Node'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _showNodeStatus(
                        context,
                        title: tr(context, 'Save Node', 'ذخیره Node'),
                        message: tr(
                          context,
                          'After registration or sign-in, this verified Node is saved as the Home Node in platform secure storage.',
                          'پس از ثبت‌نام یا ورود، این Node تأییدشده به‌عنوان Node خانگی در ذخیره‌سازی امن پلتفرم ذخیره می‌شود.',
                        ),
                      ),
                      icon: const Icon(LoomIcons.bookmark_border_rounded),
                      label: Text(tr(context, 'Save Node', 'ذخیره Node')),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: node.domain),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr(
                                context,
                                'Node address copied',
                                'نشانی Node کپی شد',
                              ),
                            ),
                          ),
                        );
                      },
                      icon: const Icon(LoomIcons.ios_share_rounded),
                      label: Text(tr(context, 'Share', 'اشتراک‌گذاری')),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: Text(
                            tr(context, 'Node fingerprint', 'اثر انگشت Node'),
                          ),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Directionality(
                                textDirection: TextDirection.ltr,
                                child: SelectableText(node.fingerprint),
                              ),
                              const SizedBox(height: LoomSpacing.sm),
                              Text(
                                tr(
                                  context,
                                  'Compare this value through an independent trusted channel before relying on it. Displaying it here is not an out-of-band verification by itself.',
                                  'پیش از اعتماد، این مقدار را از یک کانال مستقل و مورد اعتماد مقایسه کنید. نمایش آن در این صفحه به‌تنهایی تأیید خارج از باند محسوب نمی‌شود.',
                                ),
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: Text(
                                MaterialLocalizations.of(context).okButtonLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                      icon: const Icon(LoomIcons.fingerprint_rounded),
                      label: Text(
                        tr(context, 'Verify Fingerprint', 'تأیید اثرانگشت'),
                      ),
                    ),
                    if (controller.selectedEndpoint != null)
                      OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => LoomNodeShareScreen(
                              link: LoomNodeShareLink(
                                controller.selectedEndpoint!,
                                node.nodeId,
                                node.fingerprint,
                              ),
                            ),
                          ),
                        ),
                        icon: const Icon(LoomIcons.qr_code_rounded),
                        label: Text(tr(context, 'Share server', 'اشتراک سرور')),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => scanLoomNode(context, controller),
                      icon: const Icon(LoomIcons.qr_code_scanner_rounded),
                      label: Text(tr(context, 'Scan QR', 'اسکن QR')),
                    ),
                  ],
                ),
                const SizedBox(height: LoomSpacing.sm),
                Text(
                  tr(
                    context,
                    'File limit: ${((live?.maxMediaBytes ?? 32 * 1024 * 1024) / 1048576).toStringAsFixed(1)} MiB',
                    'سقف فایل: ${((live?.maxMediaBytes ?? 32 * 1024 * 1024) / 1048576).toStringAsFixed(1)} مگابایت',
                  ),
                ),
                if ((live?.maxMediaBytes ?? 0) > 128 * 1024 * 1024)
                  Text(
                    tr(
                      context,
                      'This client supports files up to 128 MiB.',
                      'این نسخهٔ کلاینت فایل تا ۱۲۸ مگابایت را پشتیبانی می‌کند.',
                    ),
                  ),
                Text(
                  tr(
                    context,
                    'Scan or share the server QR. Its fingerprint is checked against signed discovery before selection.',
                    'QR سرور را اسکن یا اشتراک‌گذاری کنید؛ اثرانگشت آن پیش از انتخاب با کشف امضاشده بررسی می‌شود.',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: p.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showNodeStatus(
  BuildContext context, {
  required String title,
  required String message,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: Text(MaterialLocalizations.of(context).okButtonLabel),
      ),
    ],
  ),
);

class _VerificationPill extends StatelessWidget {
  const _VerificationPill({required this.verified});
  final bool verified;
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final color = verified ? p.connectivity : p.warning;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LoomSpacing.xs,
        vertical: LoomSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withAlphaFraction(LoomOpacity.selectedSubtle),
        borderRadius: BorderRadius.circular(LoomRadii.pill),
      ),
      child: Text(
        verified
            ? tr(context, 'Identity matched', 'هویت تطبیق یافت')
            : tr(context, 'Unverified', 'تأییدنشده'),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: LoomSpacing.ml),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: LoomSpacing.xs),
        ...children,
      ],
    ),
  );
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value, {this.ltr = false});
  final String label;
  final String value;
  final bool ltr;
  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        const SizedBox(width: LoomSpacing.ml),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LoomSpacing.xs),
      child: ltr
          ? Directionality(textDirection: TextDirection.ltr, child: row)
          : row,
    );
  }
}
