import 'dart:async';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/nodes/data/node_directory_repository.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

class _IdentityCore implements LoomIdentityCore {
  _IdentityCore(this.identity);
  final LoomIdentityPublic identity;

  @override
  Future<LoomIdentityPublic?> readIdentity() async => identity;

  @override
  Future<LoomPendingIdentity> createIdentity() => throw UnimplementedError();

  @override
  Future<void> commitPendingIdentity(LoomPendingIdentity pending) =>
      throw UnimplementedError();

  @override
  Future<LoomPendingIdentity> restoreIdentityFromWords(List<String> words) =>
      throw UnimplementedError();

  @override
  Future<List<int>> exportRecoveryEntropy() async => List<int>.filled(32, 0);

  @override
  Future<LoomIdentityPublic> importRecoveryEntropy(List<int> entropy) async {
    if (entropy.length != 32) {
      throw const FormatException('Invalid recovery entropy');
    }
    return identity;
  }

  @override
  Future<void> clearIdentity() async {}

  @override
  void discardPendingIdentity() {}

  @override
  Future<List<int>> signIdentityBinding(List<int> payload) async => const [];
}

class _CredentialVault implements LoomCredentialVault {
  String token = 'stored-refresh-token';

  @override
  Future<void> deleteRefreshToken({
    required String homeNode,
    required String deviceId,
  }) async {}

  @override
  Future<String?> readRefreshToken({
    required String homeNode,
    required String deviceId,
  }) async => token;

  @override
  Future<void> writeRefreshToken({
    required String homeNode,
    required String deviceId,
    required String refreshToken,
  }) async {
    token = refreshToken;
  }
}

class _SessionVault implements LoomSessionVault {
  _SessionVault(this.session);
  LoomStoredSession? session;
  Object? nextReadError;
  Completer<void>? readGate;
  int reads = 0;
  int clears = 0;

  @override
  Future<void> clear() async {
    clears++;
    session = null;
  }

  @override
  Future<LoomStoredSession?> read() async {
    reads++;
    await readGate?.future;
    final error = nextReadError;
    nextReadError = null;
    if (error != null) {
      throw error;
    }
    return session;
  }

  @override
  Future<void> write(LoomStoredSession value) async {
    session = value;
  }
}

class _NodeClient extends LoomNodeClient {
  _NodeClient({
    required this.endpoint,
    required this.node,
    required this.liveInfo,
  });

  final Uri endpoint;
  final LoomNodeDescriptor node;
  final LoomNodeLiveInfo liveInfo;

  @override
  Future<LoomWellKnownNode> discoverDomain(String domain) async =>
      LoomWellKnownNode(
        protocol: 'loom-federation-v1',
        endpoint: endpoint,
        nodeId: node.nodeId,
        publicKey: node.publicKey,
        signature: 'test-signature',
        fingerprint: node.fingerprint,
      );

  @override
  Future<LoomNodeLiveInfo> fetchLiveInfo(Uri baseUri) async => liveInfo;
}

class _PinnedNodeVerifier extends LoomPinnedNodeVerifier {
  @override
  Future<void> verify({
    required Uri baseUri,
    required String expectedNodeId,
    required String expectedPublicKey,
  }) async {}
}

class _DeviceBoundSessionClient extends LoomDeviceBoundSessionClient {
  _DeviceBoundSessionClient(this.result);

  final LoomRegistrationResult result;
  int calls = 0;
  Completer<void>? gate;
  Completer<void>? started;

  @override
  Future<LoomRegistrationResult> refreshSession({
    required Uri baseUri,
    required String refreshToken,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    calls++;
    if (started?.isCompleted == false) {
      started!.complete();
    }
    await gate?.future;
    return result;
  }
}

class _DeviceSecurityCore implements LoomDeviceSecurityCore {
  _DeviceSecurityCore(this.bundle);

  final LoomDeviceKeyBundle bundle;

  @override
  Future<LoomDeviceKeyBundle> createOrLoadDevice({
    required LoomIdentityPublic identity,
    required String deviceId,
    required String deviceName,
    required LoomIdentitySigner identitySigner,
  }) async => bundle;

  @override
  Future<LoomDeviceKeyBundle?> readDevice({
    required String identityId,
    required String deviceId,
  }) async => bundle;

  @override
  Future<List<int>> signDevicePayload({
    required String identityId,
    required String deviceId,
    required List<int> payload,
  }) async => List<int>.filled(64, 0);

  @override
  Future<List<int>> exportAgreementSecret({
    required String identityId,
    required String deviceId,
  }) async => List<int>.filled(32, 0);

  @override
  Future<void> importHistoricalAgreementSecret({
    required String identityId,
    required String sourceDeviceId,
    required List<int> secret,
  }) async {
    if (secret.length != 32) {
      throw const FormatException('Invalid historical agreement secret');
    }
  }

  @override
  Future<List<String>> historicalAgreementDeviceIds({
    required String identityId,
  }) async => const <String>[];

  @override
  Future<Uint8List> openSealedPayload({
    required String identityId,
    required String deviceId,
    required LoomRelaySealedPayload payload,
    required List<int> associatedData,
  }) async => Uint8List(0);

  @override
  Future<String> deriveNearbyRendezvousId({
    required String identityId,
    required String deviceId,
    required String remoteAgreementPublicKey,
    required int timeSlot,
  }) async => 'test-rendezvous';

  @override
  Future<List<int>> createNearbyPairAuthTag({
    required String identityId,
    required String deviceId,
    required String remoteAgreementPublicKey,
    required List<int> context,
  }) async => List<int>.filled(32, 0);

  @override
  Future<void> revokeLocalDeviceSecrets({
    required String identityId,
    required String deviceId,
  }) async {}
}

void main() {
  test(
    'saved session retries storage failure and concurrent restore after unlock',
    () async {
      final identity = LoomIdentityPublic(
        identityId: 'chn:identity',
        publicKey: 'public-key',
        fingerprint: 'AA BB CC',
        createdAt: DateTime.utc(2026, 9, 2),
      );
      const receipt = LoomRegistrationReceipt(
        accountId: 'account-1',
        deviceId: 'device-1',
        address: '@alice:192.168.1.4:7483',
        homeNode: '192.168.1.4:7483',
      );
      const node = LoomNodeDescriptor(
        nodeId: 'node:home',
        name: 'Home Node',
        domain: '192.168.1.4:7483',
        operatorCountry: '—',
        networkLocation: 'LAN',
        registration: 'open',
        federation: false,
        protocols: ['loom-federation-v1'],
        publicKey: 'node-public-key',
        fingerprint: 'NODE FP',
        capabilities: ['opaque-messaging'],
      );
      const liveInfo = LoomNodeLiveInfo(
        nodeId: 'node:home',
        serverVersion: '0.8.0',
        protocolVersion: 'loom-node-v1',
        registration: 'open',
        federationMode: 'disabled',
        capabilities: ['opaque-messaging'],
      );
      final endpoint = Uri.parse('http://192.168.1.4:7483');
      final stored = LoomStoredSession(
        endpoint: endpoint,
        node: node,
        liveInfo: liveInfo,
        receipt: receipt,
      );
      const refreshed = LoomRegistrationResult(
        receipt: receipt,
        accessToken: 'new-access-token',
        refreshToken: 'new-refresh-token',
        accessTokenExpiresInSeconds: 900,
      );
      final deviceBundle = LoomDeviceKeyBundle(
        bundleVersion: 1,
        identityId: identity.identityId,
        deviceId: receipt.deviceId,
        deviceName: 'Test device',
        signingPublicKey: 'test-signing-key',
        agreementPublicKey: 'test-agreement-key',
        createdAt: DateTime.utc(2026, 9, 2),
        capabilities: const ['signing-ed25519', 'agreement-x25519'],
        fingerprint: 'TEST DEVICE FP',
        deviceSignature: 'test-device-signature',
        identitySignature: 'test-identity-signature',
      );
      final discoveryClient = _NodeClient(
        endpoint: endpoint,
        node: node,
        liveInfo: liveInfo,
      );
      final nodes = LoomNodeDirectoryController(
        repository: LoomNodeDirectoryRepository(nodeClient: discoveryClient),
      );
      final credentials = _CredentialVault();
      final sessions = _DeviceBoundSessionClient(refreshed);
      final vault = _SessionVault(stored);
      final controller = LoomOnboardingController(
        nodes: nodes,
        identityCore: _IdentityCore(identity),
        deviceSecurityCore: _DeviceSecurityCore(deviceBundle),
        credentialVault: credentials,
        sessionVault: vault,
        nodeVerifier: _PinnedNodeVerifier(),
        deviceBoundSessionClient: sessions,
      );
      addTearDown(controller.dispose);
      addTearDown(nodes.dispose);

      // A protected-store failure must reach the startup error UI, not return
      // false (which means a fresh install and shows Create account).
      vault.nextReadError = PlatformException(code: 'vault_locked');
      await expectLater(
        controller.restorePersistedSession(),
        throwsA(isA<PlatformException>()),
      );
      expect(vault.session, same(stored));
      expect(vault.clears, 0);

      // Recreating startup during unlock must join the in-flight restore,
      // rather than observing idle and incorrectly selecting onboarding.
      vault.readGate = Completer<void>();
      sessions.gate = Completer<void>();
      sessions.started = Completer<void>();
      final restoreA = controller.restorePersistedSession();
      final restoreB = controller.restorePersistedSession();
      vault.readGate!.complete();
      expect(await Future.wait([restoreA, restoreB]), [true, true]);
      expect(vault.reads, 2, reason: 'failed read plus one shared retry');
      expect(vault.clears, 0);
      expect(controller.status, LoomOnboardingStatus.complete);
      expect(controller.committedIdentity?.identityId, identity.identityId);
      expect(controller.receipt?.address, receipt.address);
      expect(controller.username, 'alice');
      await sessions.started!.future;
      expect(
        controller.accessToken,
        isNull,
        reason: 'local restore completes while network refresh is blocked',
      );
      final startupRefresh = controller.refreshAccessToken();
      sessions.gate!.complete();
      expect(await startupRefresh, isTrue);
      expect(controller.accessToken, 'new-access-token');
      expect(credentials.token, 'new-refresh-token');
      expect(nodes.selectedEndpoint, stored.endpoint);
      expect(nodes.selectedNodeVerified, isTrue);
      sessions.gate = Completer<void>();
      sessions.started = Completer<void>();
      final first = controller.refreshAccessToken();
      final second = controller.refreshRejectedToken(controller.accessToken!);
      await sessions.started!.future;
      expect(sessions.calls, 2, reason: 'startup plus one coalesced refresh');
      controller.clearTransientSecrets();
      final oldRefreshGate = sessions.gate!;
      sessions.gate = Completer<void>();
      sessions.started = Completer<void>();
      expect(await controller.restorePersistedSession(), isTrue);
      await sessions.started!.future;
      final afterUnlock = controller.refreshAccessToken();
      oldRefreshGate.complete();
      expect(await Future.wait([first, second]), [false, false]);
      expect(
        controller.accessToken,
        isNull,
        reason: 'late response must not repopulate a locked session',
      );
      expect(
        identical(afterUnlock, controller.refreshAccessToken()),
        isTrue,
        reason: 'old completion must not clear the new unlock attempt',
      );
      sessions.gate!.complete();
      expect(await afterUnlock, isTrue);
      expect(controller.receipt?.deviceId, receipt.deviceId);
      expect(vault.clears, 0);
    },
  );
}
