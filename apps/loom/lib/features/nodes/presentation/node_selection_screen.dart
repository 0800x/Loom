import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/node_directory_controller.dart';
import 'node_qr_screen.dart';

class NodeSelectionScreen extends StatefulWidget {
  const NodeSelectionScreen({super.key});
  @override
  State<NodeSelectionScreen> createState() => _NodeSelectionScreenState();
}

class _NodeSelectionScreenState extends State<NodeSelectionScreen> {
  int selectedFilter = 0;
  final search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = LoomNodeDirectoryScope.of(context);
      if (controller.state == LoomNodeDirectoryState.idle) {
        controller.refreshRegistry();
      }
    });
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<LoomNodeDescriptor> _filter(List<LoomNodeDescriptor> nodes) {
    final q = search.text.trim().toLowerCase();
    return nodes
        .where((node) {
          final queryMatch =
              q.isEmpty ||
              node.name.toLowerCase().contains(q) ||
              node.domain.contains(q) ||
              (node.region?.toLowerCase().contains(q) ?? false);
          if (!queryMatch) return false;
          return switch (selectedFilter) {
            1 =>
              false, // Nearby discovery requires explicit permission/capability work in Phase 8.
            2 => node.operatorCountry == 'IR' || node.networkLocation == 'IR',
            3 => node.operatorCountry != 'IR' && node.networkLocation != 'IR',
            4 =>
              false, // Saved-node persistence arrives with the local store in Phase 3.
            _ => true,
          };
        })
        .toList(growable: false);
  }

  Future<void> _manualDomain(BuildContext context) async {
    final input = TextEditingController();
    final domain = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          tr(context, 'Enter Node domain', 'دامنه Node را وارد کنید'),
        ),
        content: TextField(
          controller: input,
          autofocus: true,
          textDirection: TextDirection.ltr,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            hintText: 'chat.example.org or 192.168.1.10:7483',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: Text(tr(context, 'Discover', 'کشف')),
          ),
        ],
      ),
    );
    input.dispose();
    if (!context.mounted || domain == null || domain.isEmpty) return;
    final controller = LoomNodeDirectoryScope.of(context);
    await controller.discoverAndSelectDomain(domain);
    if (!context.mounted) return;
    if (controller.selectedNodeVerified) {
      Navigator.pushNamed(context, '/node-detail');
    }
  }

  Future<void> _showUnavailable(
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

  String _flag(String code) {
    if (code.length != 2 || code == '—') return '◉';
    final upper = code.toUpperCase();
    return String.fromCharCodes(upper.codeUnits.map((c) => 0x1F1E6 + c - 65));
  }

  @override
  Widget build(BuildContext context) {
    final s = LoomStrings.of(context);
    final p = context.loom;
    final controller = LoomNodeDirectoryScope.of(context);
    final filters = [s.recommended, s.nearby, s.iran, s.international, s.saved];
    final visible = _filter(controller.nodes);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: LoomSizing.contentMax),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: LoomSpacing.md),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: LoomSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: Navigator.of(context).pop,
                          icon: const Icon(LoomIcons.arrow_back_rounded),
                        ),
                        const SizedBox(width: LoomSpacing.xs),
                        Expanded(
                          child: Text(
                            s.chooseNode,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (controller.state == LoomNodeDirectoryState.loading)
                          const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          IconButton(
                            onPressed: controller.refreshRegistry,
                            tooltip: tr(
                              context,
                              'Refresh directory',
                              'به‌روزرسانی فهرست',
                            ),
                            icon: const Icon(LoomIcons.refresh_rounded),
                          ),
                      ],
                    ),
                  ),
                  TextField(
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(LoomIcons.search_rounded),
                      hintText: s.search,
                    ),
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  SizedBox(
                    height: LoomSizing.profileTabsHeight,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: filters.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(width: LoomSpacing.xxs),
                      itemBuilder: (context, index) => _NodeFilterTab(
                        label: filters[index],
                        selected: selectedFilter == index,
                        onTap: () => setState(() => selectedFilter = index),
                      ),
                    ),
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  if (controller.repository.lastRegistryLoadUsedCache)
                    Padding(
                      padding: const EdgeInsets.only(bottom: LoomSpacing.xs),
                      child: Row(
                        children: [
                          Icon(
                            LoomIcons.offline_bolt_outlined,
                            size: LoomIconSize.compact,
                            color: p.warning,
                          ),
                          const SizedBox(width: LoomSpacing.xs),
                          Expanded(
                            child: Text(
                              tr(
                                context,
                                'Using the last locally cached signed directory.',
                                'آخرین فهرست امضاشده ذخیره‌شده روی دستگاه استفاده می‌شود.',
                              ),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: p.warning),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        if (!controller.repository.config.registryConfigured &&
                            controller.nodes.isEmpty) {
                          return _EmptyDirectory(
                            title: tr(
                              context,
                              'Public directory is not configured',
                              'فهرست عمومی پیکربندی نشده است',
                            ),
                            body: tr(
                              context,
                              'Loom still works with direct Node discovery. Enter a domain to verify its identity and live capabilities.',
                              'لوم همچنان با کشف مستقیم Node کار می‌کند. دامنه‌ای وارد کنید تا هویت و قابلیت‌های زنده آن تأیید شود.',
                            ),
                            action: () => _manualDomain(context),
                          );
                        }
                        if (controller.state == LoomNodeDirectoryState.error &&
                            controller.nodes.isEmpty) {
                          return _EmptyDirectory(
                            title: tr(
                              context,
                              'Directory unavailable',
                              'فهرست در دسترس نیست',
                            ),
                            body: tr(
                              context,
                              'The signed directory could not be loaded. You can still connect to a Node directly.',
                              'فهرست امضاشده بارگیری نشد. همچنان می‌توانید مستقیماً به یک Node متصل شوید.',
                            ),
                            action: () => _manualDomain(context),
                          );
                        }
                        if (visible.isEmpty) {
                          return Center(
                            child: Text(
                              selectedFilter == 1
                                  ? tr(
                                      context,
                                      'Nearby Node discovery arrives in the LAN resilience phase.',
                                      'کشف Node نزدیک در فاز تاب‌آوری LAN اضافه می‌شود.',
                                    )
                                  : selectedFilter == 4
                                  ? tr(
                                      context,
                                      'Saved Nodes require the Phase 3 local store.',
                                      'Nodeهای ذخیره‌شده به ذخیره‌ساز محلی فاز ۳ نیاز دارند.',
                                    )
                                  : tr(
                                      context,
                                      'No matching Nodes',
                                      'Node مطابقی پیدا نشد',
                                    ),
                            ),
                          );
                        }
                        return ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final node = visible[index];
                            final location = [
                              node.networkLocation,
                              if (node.region?.isNotEmpty ?? false)
                                node.region!,
                            ].join(' · ');
                            return LoomNodeCard(
                              flag: _flag(node.networkLocation),
                              name: node.name,
                              location: location,
                              latency: '—',
                              registration: node.registration,
                              federation: node.federation
                                  ? tr(context, 'Federation', 'فدراسیون')
                                  : tr(
                                      context,
                                      'No federation',
                                      'بدون فدراسیون',
                                    ),
                              onView: () async {
                                await controller.selectRegistryNode(node);
                                if (context.mounted) {
                                  Navigator.pushNamed(context, '/node-detail');
                                }
                              },
                              onRegister: () async {
                                await controller.selectRegistryNode(node);
                                if (!context.mounted) return;
                                if (controller.selectedNodeVerified) {
                                  Navigator.pushNamed(context, '/identity');
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        controller.errorMessage ??
                                            tr(
                                              context,
                                              'Node verification failed',
                                              'تأیید Node ناموفق بود',
                                            ),
                                      ),
                                    ),
                                  );
                                }
                              },
                              viewLabel: tr(context, 'View', 'نمایش'),
                              registerLabel: tr(context, 'Register', 'ثبت‌نام'),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  if (controller.errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: LoomSpacing.xs),
                      child: Text(
                        controller.errorMessage!,
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: p.critical),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: LoomSpacing.xs,
                    ),
                    child: LoomGlassSurface(
                      strength: LoomGlassStrength.strong,
                      radius: LoomRadii.navigation,
                      padding: const EdgeInsets.symmetric(
                        horizontal: LoomSpacing.xs,
                        vertical: LoomSpacing.xxs,
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: LoomSpacing.xxs,
                        children: [
                          TextButton.icon(
                            onPressed: () => _manualDomain(context),
                            icon: const Icon(LoomIcons.language_rounded),
                            label: Text(s.enterManually),
                          ),
                          TextButton.icon(
                            onPressed: () => scanLoomNode(context, controller),
                            icon: const Icon(LoomIcons.qr_code_scanner_rounded),
                            label: Text(s.scanQr),
                          ),
                          TextButton.icon(
                            onPressed: () => Navigator.pushNamed(
                              context,
                              '/settings/nearby',
                            ),
                            icon: const Icon(LoomIcons.lan_outlined),
                            label: Text(s.discoverLocal),
                          ),
                          TextButton.icon(
                            onPressed: () => _showUnavailable(
                              context,
                              title: tr(context, 'Host a Node', 'میزبانی Node'),
                              message: tr(
                                context,
                                'The client does not install a server silently. Use the verified Loom Node deployment scripts; the offline-ready installer is being handled in the server packaging phase.',
                                'کلاینت بدون اطلاع سرور نصب نمی‌کند. از اسکریپت‌های معتبر استقرار لوم Node استفاده کنید؛ نصب‌کننده آماده آفلاین در مرحله بسته‌بندی سرور انجام می‌شود.',
                              ),
                            ),
                            icon: const Icon(LoomIcons.dns_outlined),
                            label: Text(s.hostNode),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyDirectory extends StatelessWidget {
  const _EmptyDirectory({
    required this.title,
    required this.body,
    required this.action,
  });
  final String title;
  final String body;
  final VoidCallback action;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(LoomSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LoomRouteMark(size: 48),
                  const SizedBox(height: LoomSpacing.md),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  Text(body, textAlign: TextAlign.center),
                  const SizedBox(height: LoomSpacing.md),
                  FilledButton(
                    onPressed: action,
                    child: Text(
                      tr(context, 'Enter Node domain', 'ورود دامنه Node'),
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

class _NodeFilterTab extends StatelessWidget {
  const _NodeFilterTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LoomRadii.compact),
      child: AnimatedContainer(
        duration: LoomAccessibility.fromContext(context).reduceMotion
            ? Duration.zero
            : LoomMotion.micro,
        padding: const EdgeInsets.symmetric(
          horizontal: LoomSpacing.sm,
          vertical: LoomSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: selected
              ? p.primary.withAlphaFraction(LoomOpacity.selectedSubtle)
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: selected ? p.primary : Colors.transparent,
              width: LoomBorders.emphasis,
            ),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected ? p.primary : p.textSecondary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
