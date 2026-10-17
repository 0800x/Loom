import 'package:loom_models/loom_models.dart';
import 'package:flutter/widgets.dart';

import '../data/node_directory_repository.dart';

enum LoomNodeDirectoryState { idle, loading, ready, error }

class LoomNodeDirectoryController extends ChangeNotifier {
  LoomNodeDirectoryController({LoomNodeDirectoryRepository? repository})
    : repository = repository ?? LoomNodeDirectoryRepository();

  final LoomNodeDirectoryRepository repository;
  LoomNodeDirectoryState state = LoomNodeDirectoryState.idle;
  List<LoomNodeDescriptor> nodes = const [];
  String? errorMessage;
  LoomNodeDescriptor? selectedNode;
  Uri? selectedEndpoint;
  LoomNodeLiveInfo? selectedLiveInfo;
  bool _selectedNodeFreshlyVerified = false;

  /// True only after this process has completed live signed discovery and
  /// matched live Node metadata. Restored cache metadata is pinned state, not
  /// fresh network verification.
  bool get selectedNodeVerified =>
      _selectedNodeFreshlyVerified &&
      selectedEndpoint != null &&
      selectedLiveInfo != null &&
      errorMessage == null;

  void restoreTrustedSelection({
    required LoomNodeDescriptor node,
    required Uri endpoint,
    required LoomNodeLiveInfo liveInfo,
  }) {
    if (node.nodeId != liveInfo.nodeId) {
      throw const FormatException('Stored Home Node identity is inconsistent');
    }
    selectedNode = node;
    selectedEndpoint = endpoint;
    selectedLiveInfo = liveInfo;
    _selectedNodeFreshlyVerified = false;
    errorMessage = null;
    state = LoomNodeDirectoryState.ready;
    notifyListeners();
  }

  Future<void> refreshMediaPolicy() async {
    final endpoint = selectedEndpoint, node = selectedNode;
    if (endpoint == null || node == null) {
      throw StateError('Choose a server first');
    }
    final live = await repository.liveInfo(endpoint);
    if (selectedEndpoint != endpoint ||
        selectedNode?.nodeId != node.nodeId ||
        live.nodeId != node.nodeId) {
      throw StateError('Server identity changed');
    }
    selectedLiveInfo = live;
    notifyListeners();
  }

  Future<void> refreshRegistry() async {
    state = LoomNodeDirectoryState.loading;
    errorMessage = null;
    notifyListeners();
    try {
      nodes = await repository.loadRegistry();
      state = LoomNodeDirectoryState.ready;
    } catch (error) {
      state = LoomNodeDirectoryState.error;
      errorMessage = error.toString();
    }
    notifyListeners();
  }

  Future<void> selectRegistryNode(LoomNodeDescriptor node) async {
    selectedNode = node;
    selectedEndpoint = null;
    selectedLiveInfo = null;
    _selectedNodeFreshlyVerified = false;
    errorMessage = null;
    notifyListeners();
    try {
      final discovered = await repository.discoverDomain(node.domain);
      if (discovered.nodeId != node.nodeId ||
          discovered.publicKey != node.publicKey) {
        throw StateError(
          'Well-known Node identity does not match the signed registry entry',
        );
      }
      if (node.fingerprint != discovered.fingerprint) {
        throw StateError(
          'Well-known Node fingerprint does not match the signed registry entry',
        );
      }
      final live = await repository.liveInfo(discovered.endpoint);
      if (live.nodeId != node.nodeId) {
        throw StateError('Live Node identity does not match registry Node ID');
      }
      selectedEndpoint = discovered.endpoint;
      selectedLiveInfo = live;
      _selectedNodeFreshlyVerified = true;
    } catch (error) {
      _selectedNodeFreshlyVerified = false;
      errorMessage = error.toString();
    }
    notifyListeners();
  }

  Future<void> discoverAndSelectDomain(
    String domain, {
    String? expectedNodeId,
    String? expectedFingerprint,
  }) async {
    state = LoomNodeDirectoryState.loading;
    _selectedNodeFreshlyVerified = false;
    errorMessage = null;
    notifyListeners();
    try {
      final discovered = await repository.discoverDomain(domain);
      if ((expectedNodeId != null && discovered.nodeId != expectedNodeId) ||
          (expectedFingerprint != null &&
              discovered.fingerprint.replaceAll(' ', '').toUpperCase() !=
                  expectedFingerprint.replaceAll(' ', '').toUpperCase())) {
        throw StateError('QR identity does not match the live server');
      }
      selectedEndpoint = discovered.endpoint;
      final live = await repository.liveInfo(discovered.endpoint);
      if (live.nodeId != discovered.nodeId) {
        throw StateError(
          'Live Node identity does not match well-known Node ID',
        );
      }
      selectedLiveInfo = live;
      selectedNode = LoomNodeDescriptor(
        nodeId: discovered.nodeId,
        name: discovered.endpoint.authority,
        domain: discovered.endpoint.authority.toLowerCase(),
        operatorCountry: '—',
        networkLocation: '—',
        registration: live.registration,
        federation: live.federationMode != 'disabled',
        protocols: [discovered.protocol],
        publicKey: discovered.publicKey,
        fingerprint: discovered.fingerprint,
        capabilities: live.capabilities,
      );
      _selectedNodeFreshlyVerified = true;
      state = LoomNodeDirectoryState.ready;
    } catch (error) {
      _selectedNodeFreshlyVerified = false;
      state = LoomNodeDirectoryState.error;
      errorMessage = error.toString();
    }
    notifyListeners();
  }
}

class LoomNodeDirectoryScope
    extends InheritedNotifier<LoomNodeDirectoryController> {
  const LoomNodeDirectoryScope({
    required LoomNodeDirectoryController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static LoomNodeDirectoryController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LoomNodeDirectoryScope>();
    assert(scope != null, 'LoomNodeDirectoryScope not found');
    return scope!.notifier!;
  }
}
