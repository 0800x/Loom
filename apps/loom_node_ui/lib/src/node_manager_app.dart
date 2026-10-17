import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import 'node_api.dart';

class LoomNodeManagerApp extends StatelessWidget {
  const LoomNodeManagerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Loom Node',
        theme: LoomTheme.light(),
        darkTheme: LoomTheme.dark(),
        themeMode: ThemeMode.system,
        home: const NodeManagerScreen(),
      );
}

class NodeManagerScreen extends StatefulWidget {
  const NodeManagerScreen({super.key});
  @override
  State<NodeManagerScreen> createState() => _NodeManagerScreenState();
}

class _NodeManagerScreenState extends State<NodeManagerScreen> {
  final _api = NodeAdminApi();
  final _endpoint = TextEditingController(text: 'http://127.0.0.1:7483');
  final _token = TextEditingController();
  NodeStatus? _status;
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _connect() async {
    final uri = Uri.tryParse(_endpoint.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => _error = 'Enter a valid Node URL.');
      return;
    }
    if (_token.text.trim().isEmpty) {
      setState(
        () =>
            _error = 'Enter the admin token stored in the Node configuration.',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await _api.status(
        baseUri: uri,
        adminToken: _token.text.trim(),
      );
      if (!mounted) return;
      setState(() => _status = status);
    } on NodeApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Could not reach this Node.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.loom;
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Row(
          children: [
            _Rail(connected: _status != null),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Padding(
                    padding: const EdgeInsets.all(LoomSpacing.xl),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _Header(),
                        const SizedBox(height: LoomSpacing.lg),
                        _ConnectionBar(
                          endpoint: _endpoint,
                          token: _token,
                          loading: _loading,
                          onConnect: _connect,
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: LoomSpacing.sm,
                            ),
                            child: Text(
                              _error!,
                              style: TextStyle(color: colors.critical),
                            ),
                          ),
                        const SizedBox(height: LoomSpacing.xl),
                        Expanded(
                          child: _status == null
                              ? const _DisconnectedState()
                              : _StatusWorkspace(status: _status!),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();
  @override
  Widget build(BuildContext context) => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LoomBrandMark(size: 42, glow: false),
          SizedBox(height: 12),
          Text(
            'Loom Node Manager',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 4),
          Text(
            'Private operator console. Credentials stay in this process and are not saved by the Phase 7 UI.',
          ),
        ],
      );
}

class _Rail extends StatelessWidget {
  const _Rail({required this.connected});
  final bool connected;
  @override
  Widget build(BuildContext context) => Container(
        width: 76,
        decoration: BoxDecoration(
          border:
              Border(right: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 20),
            const LoomBrandMark(size: 28, glow: false),
            const SizedBox(height: 28),
            const _RailItem(
              icon: Icons.dashboard_outlined,
              label: 'Status',
              selected: true,
            ),
            const _RailItem(icon: Icons.people_outline, label: 'People'),
            const _RailItem(icon: Icons.sync_alt, label: 'Federation'),
            const _RailItem(icon: Icons.storage_outlined, label: 'Storage'),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(
                connected ? Icons.circle : Icons.circle_outlined,
                size: 12,
              ),
            ),
          ],
        ),
      );
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final bool selected;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: SizedBox(
          height: 52,
          width: 60,
          child: Icon(
            icon,
            size: 22,
            color: selected ? Theme.of(context).colorScheme.primary : null,
            semanticLabel: label,
          ),
        ),
      );
}

class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({
    required this.endpoint,
    required this.token,
    required this.loading,
    required this.onConnect,
  });
  final TextEditingController endpoint, token;
  final bool loading;
  final VoidCallback onConnect;
  @override
  Widget build(BuildContext context) => LoomGlassSurface(
        strength: LoomGlassStrength.weak,
        radius: LoomRadii.surface,
        child: Padding(
          padding: const EdgeInsets.all(LoomSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: endpoint,
                  decoration: const InputDecoration(
                    labelText: 'Node URL',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: LoomSpacing.md),
              Expanded(
                child: TextField(
                  controller: token,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Admin token',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: LoomSpacing.md),
              FilledButton(
                onPressed: loading ? null : onConnect,
                child: Text(loading ? 'Connecting…' : 'Connect'),
              ),
            ],
          ),
        ),
      );
}

class _DisconnectedState extends StatelessWidget {
  const _DisconnectedState();
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 48),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.dns_outlined, size: 36),
                SizedBox(height: 16),
                Text(
                  'Connect to your Node',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 8),
                Text(
                  'The manager reads operator status from /admin/v1/status. It does not invent uptime, capacity, federation health, or registration data while disconnected.',
                ),
              ],
            ),
          ),
        ),
      );
}

class _StatusWorkspace extends StatelessWidget {
  const _StatusWorkspace({required this.status});
  final NodeStatus status;
  @override
  Widget build(BuildContext context) {
    final node = status.node;
    final stats = status.stats;
    return ListView(
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Metric(label: 'Mode', value: status.mode),
            _Metric(
              label: 'Uptime',
              value: '${status.uptimeSeconds ~/ 60} min',
            ),
            _Metric(label: 'Accounts', value: '${stats['accounts'] ?? 0}'),
            _Metric(label: 'Messages', value: '${stats['messages'] ?? 0}'),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          'Node identity',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        _Fact(label: 'Domain', value: '${node['domain'] ?? '—'}'),
        _Fact(label: 'Node ID', value: '${node['nodeId'] ?? '—'}', ltr: true),
        _Fact(
          label: 'Fingerprint',
          value: '${node['fingerprint'] ?? '—'}',
          ltr: true,
        ),
        _Fact(label: 'Registration', value: '${node['registration'] ?? '—'}'),
        _Fact(label: 'Federation', value: '${node['federationMode'] ?? '—'}'),
        _Fact(
          label: 'Network jurisdiction',
          value: '${node['networkJurisdiction'] ?? '—'}',
        ),
        const SizedBox(height: 24),
        const Text(
          'Phase 7 scope',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'This manager intentionally exposes read-only runtime status first. Account moderation, federation policy editing, backups, upgrades, and certificate automation require explicit reviewed write contracts rather than decorative controls.',
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 190,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(
                value,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.ltr = false});
  final String label, value;
  final bool ltr;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 180, child: Text(label)),
            Expanded(
              child: Directionality(
                textDirection:
                    ltr ? TextDirection.ltr : Directionality.of(context),
                child: SelectableText(value),
              ),
            ),
          ],
        ),
      );
}
