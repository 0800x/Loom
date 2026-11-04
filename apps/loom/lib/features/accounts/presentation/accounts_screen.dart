import 'package:flutter/material.dart';
import 'package:loom_design/loom_design.dart';

import '../application/account_registry.dart';

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
    final state = _state;
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _adding || _workingId != null ? null : _add,
        icon: const Icon(LoomIcons.add),
        label: const Text('Add account'),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load accounts: $_error'),
              ),
            )
          : state == null
          ? const Center(child: CircularProgressIndicator())
          : state.accounts.isEmpty
          ? const Center(child: Text('Your current account will appear here.'))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: state.accounts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final entry = state.accounts[index];
                final active = entry.id == state.activeId;
                final working = _workingId == entry.id;
                return Card(
                  child: ListTile(
                    leading: Icon(
                      active
                          ? LoomIcons.person_outline_rounded
                          : LoomIcons.person_outline_rounded,
                    ),
                    title: Text(entry.label),
                    subtitle: Text(
                      entry.address ??
                          (active ? 'Current account' : 'On this device'),
                    ),
                    trailing: active
                        ? const Icon(LoomIcons.check_circle_rounded)
                        : working
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : TextButton(
                            onPressed: _workingId != null || _adding
                                ? null
                                : () => _switch(entry.id),
                            child: const Text('Switch'),
                          ),
                  ),
                );
              },
            ),
    );
  }
}
