import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:path_provider/path_provider.dart';

class LoomNodeDirectoryConfig {
  const LoomNodeDirectoryConfig({
    required this.registryManifest,
    required this.registrySignature,
    required this.registryPublicKey,
  });

  final Uri? registryManifest;
  final Uri? registrySignature;
  final List<int>? registryPublicKey;

  factory LoomNodeDirectoryConfig.fromEnvironment() {
    const manifestRaw = String.fromEnvironment('LOOM_REGISTRY_URL');
    const signatureRaw = String.fromEnvironment('LOOM_REGISTRY_SIG_URL');
    const keyRaw = String.fromEnvironment('LOOM_REGISTRY_PUBLIC_KEY_B64');
    Uri? safeUri(String value) {
      if (value.isEmpty) return null;
      final uri = Uri.tryParse(value);
      return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
          ? uri
          : null;
    }

    List<int>? key;
    if (keyRaw.isNotEmpty) {
      try {
        final decoded = base64Decode(keyRaw);
        if (decoded.length == 32) key = decoded;
      } catch (_) {}
    }
    return LoomNodeDirectoryConfig(
      registryManifest: safeUri(manifestRaw),
      registrySignature: safeUri(signatureRaw),
      registryPublicKey: key,
    );
  }

  bool get registryConfigured =>
      registryManifest != null &&
      registrySignature != null &&
      registryPublicKey != null;
}

class LoomNodeDirectoryRepository {
  LoomNodeDirectoryRepository({
    LoomNodeDirectoryConfig? config,
    LoomNodeClient? nodeClient,
    LoomRegistryClient? registryClient,
  })  : config = config ?? LoomNodeDirectoryConfig.fromEnvironment(),
        _nodeClient = nodeClient ?? LoomNodeClient(),
        _registryClient = registryClient ?? LoomRegistryClient();

  final LoomNodeDirectoryConfig config;
  final LoomNodeClient _nodeClient;
  final LoomRegistryClient _registryClient;
  bool lastRegistryLoadUsedCache = false;

  Future<List<LoomNodeDescriptor>> loadRegistry() async {
    if (!config.registryConfigured) return const [];
    final verifier = LoomRegistryVerifier(
      signingPublicKey: config.registryPublicKey!,
    );
    try {
      final artifact = await _registryClient.fetchAndVerifyArtifact(
        manifestUri: config.registryManifest!,
        signatureUri: config.registrySignature!,
        verifier: verifier,
      );
      await _writeCache(artifact);
      lastRegistryLoadUsedCache = false;
      return artifact.manifest.nodes;
    } catch (networkOrVerificationError) {
      final cached = await _readCache(verifier);
      if (cached != null) {
        lastRegistryLoadUsedCache = true;
        return cached.nodes;
      }
      rethrow;
    }
  }

  Future<LoomRegistryManifest?> _readCache(
    LoomRegistryVerifier verifier,
  ) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final manifestFile = File(
        '${dir.path}${Platform.pathSeparator}registry-v1.json',
      );
      final signatureFile = File(
        '${dir.path}${Platform.pathSeparator}registry-v1.sig',
      );
      if (!await manifestFile.exists() || !await signatureFile.exists()) {
        return null;
      }
      final bytes = await manifestFile.readAsBytes();
      if (bytes.length > 2 * 1024 * 1024) return null;
      final signature = await signatureFile.readAsString();
      if (signature.length > 4096) return null;
      return await verifier.verify(
        manifestBytes: bytes,
        detachedSignatureBase64: signature.trim(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(LoomVerifiedRegistryArtifact artifact) async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      final manifestFile = File(
        '${dir.path}${Platform.pathSeparator}registry-v1.json',
      );
      final signatureFile = File(
        '${dir.path}${Platform.pathSeparator}registry-v1.sig',
      );
      final tempManifest = File('${manifestFile.path}.tmp');
      final tempSignature = File('${signatureFile.path}.tmp');
      await tempManifest.writeAsBytes(artifact.manifestBytes, flush: true);
      await tempSignature.writeAsString(
        artifact.detachedSignatureBase64,
        flush: true,
      );
      if (await manifestFile.exists()) await manifestFile.delete();
      if (await signatureFile.exists()) await signatureFile.delete();
      await tempManifest.rename(manifestFile.path);
      await tempSignature.rename(signatureFile.path);
    } catch (_) {
      // Registry cache is a resilience optimization. A cache write failure must
      // not invalidate an already verified network response.
    }
  }

  Future<LoomWellKnownNode> discoverDomain(String domain) =>
      _nodeClient.discoverDomain(domain);

  Future<LoomNodeLiveInfo> liveInfo(Uri endpoint) =>
      _nodeClient.fetchLiveInfo(endpoint);
}
