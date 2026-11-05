import 'package:flutter/material.dart';
import 'package:loom_design/loom_design.dart';

import '../../../app/loom_strings.dart';
import '../application/account_registry.dart';

/// Account switcher: a flat grouped list of the slots stored on this device
/// with the active one marked, plus an add-account action.
class LoomAccountsScreen extends StatefulWidget {
  const LoomAccountsScreen({
    super.key,
    required this.onSwitch,
    required this.onAddAccount,
  });

  final Future<void> Function(String id) onSwitch;
  final Future<void> Function() onAddAccount;

  @override
  State<LoomAccountsScreen> createState() => _LoomAccountsScreenState();
}

class _LoomAccountsScreenState extends State<LoomAccountsScreen> {
  LoomAccountRegistryState? _state;
  Object? _error;
  String? _workingId;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = await LoomAccountRegistry.load();
      if (mounted) {
        setState(() {
          _state = state;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _switch(String id) async {
    if (_workingId != null || _adding) return;
    setState(() => _workingId = id);
    try {
      await widget.onSwitch(id);
      // The switch rebuilds the startup gate and removes this route; only
      // refresh while still mounted (an error path keeps the screen up).
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  Future<void> _add() async {
    if (_workingId != null || _adding) return;
    setState(() => _adding = true);
    try {
      await widget.onAddAccount();
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final state = _state;
    return Scaffold(
      backgroundColor: p.background,
      appBar: LoomGlassAppBar(
        title: Text(tr(context, 'Accounts', 'حساب‌ها')),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: LoomSizing.detailsMax),
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    tr(
                      context,
                      'Could not load the accounts on this device.',
                      'بارگذاری حساب‌های این دستگاه ممکن نشد.',
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.critical),
                  ),
                )
              : state == null
              ? const Center(child: CircularProgressIndicator())
              : state.accounts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr(
                        context,
                        'Your accounts appear here once a second one is added.',
                        'حساب‌ها پس از افزودن حساب دوم اینجا نمایش داده می‌شوند.',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.textSecondary),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    _Section(
                      title: tr(
                        context,
                        'On this device',
                        'روی این دستگاه',
                      ),
                      children: [
                        for (var i = 0; i < state.accounts.length; i++)
                          _AccountTile(
                            key: ValueKey('account-${state.accounts[i].id}'),
                            entry: state.accounts[i],
                            active: state.accounts[i].id == state.activeId,
                            working: _workingId == state.accounts[i].id,
                            enabled:
                                _workingId == null &&
                                !_adding &&
                                state.accounts[i].id != state.activeId,
                            showDivider: i < state.accounts.length - 1,
                            onTap: () => _switch(state.accounts[i].id),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Material(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(LoomRadii.surface),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(LoomRadii.surface),
                        onTap: _workingId != null || _adding ? null : _add,
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 60),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              if (_adding)
                                const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                SizedBox.square(
                                  dimension: 34,
                                  child: Icon(
                                    LoomIcons.add_rounded,
                                    size: 20,
                                    color: p.primary,
                                  ),
                                ),
                              const SizedBox(width: 12),
                              Text(
                                tr(
                                  context,
                                  'Add account',
                                  'افزودن حساب',
                                ),
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: p.primary,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 6, bottom: 8),
        child: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: context.loom.textSecondary),
        ),
      ),
      Material(
        color: context.loom.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(LoomRadii.surface),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ],
  );
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.entry,
    required this.active,
    required this.working,
    required this.enabled,
    required this.showDivider,
    required this.onTap,
    super.key,
  });

  final LoomAccountEntry entry;
  final bool active, working, enabled, showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Column(
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                LoomAvatar(label: entry.label, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        entry.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.address ??
                            (active
                                ? tr(context, 'Current account', 'حساب فعلی')
                                : tr(context, 'On this device', 'روی این دستگاه')),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: entry.address == null
                            ? null
                            : TextDirection.ltr,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: p.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (working)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (active)
                  Icon(LoomIcons.check_circle_rounded, color: p.primary)
                else
                  Text(
                    tr(context, 'Switch', 'تغییر'),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: p.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          if (showDivider)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 68),
              child: Divider(height: 1, color: p.border),
            ),
        ],
      ),
    );
  }
}
