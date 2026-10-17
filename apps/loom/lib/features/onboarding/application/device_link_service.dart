import 'dart:io';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';

import 'onboarding_controller.dart';

class LoomPendingDeviceLinkSession {
  const LoomPendingDeviceLinkSession({
    required this.endpoint,
    required this.username,
    required this.login,
  });

  final Uri endpoint;
  final String username;
  final LoomLoginResult login;
}

class LoomCreatedDeviceLink {
  const LoomCreatedDeviceLink({
    required this.qrPayload,
    required this.expiresAt,
    required this.linkId,
  });

  final String qrPayload;
  final DateTime expiresAt;
  final String linkId;
}

class LoomPasswordLoginBootstrap {
  LoomPasswordLoginBootstrap({
    LoomIdentityCore? identityCore,
    LoomNodeClient? nodeClient,
    LoomPinnedNodeVerifier? nodeVerifier,
  }) : _identityCore = identityCore ?? LoomIdentityCoreV1(),
       _nodeClient = nodeClient ?? LoomNodeClient(),
       _nodeVerifier = nodeVerifier ?? LoomPinnedNodeVerifier();

  final LoomIdentityCore _identityCore;
  final LoomNodeClient _nodeClient;
  final LoomPinnedNodeVerifier _nodeVerifier;

  Future<bool> hasLocalIdentity() async =>
      await _identityCore.readIdentity() != null;

  /// Password-authenticates an account even when this device does not yet have
  /// the user's long-term Loom identity. The returned bearer session stays in
  /// memory until QR linking finishes; it is not persisted as automatic login.
  Future<LoomPendingDeviceLinkSession> authenticateNewDevice({
    required LoomOnboardingController onboarding,
    required String nodeDomain,
    required String username,
    required String password,
  }) async {
    await onboarding.nodes.discoverAndSelectDomain(nodeDomain);
    final node = onboarding.nodes.selectedNode;
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (!onboarding.nodes.selectedNodeVerified ||
        node == null ||
        endpoint == null) {
      throw LoomProtocolException(
        onboarding.nodes.errorMessage ?? 'The Home Node could not be verified',
      );
    }
    await _nodeVerifier.verify(
      baseUri: endpoint,
      expectedNodeId: node.nodeId,
      expectedPublicKey: node.publicKey,
    );
    final normalized = username.trim().toLowerCase();
    final login = await _nodeClient.login(
      baseUri: endpoint,
      username: normalized,
      password: password,
    );
    return LoomPendingDeviceLinkSession(
      endpoint: endpoint,
      username: normalized,
      login: login,
    );
  }
}

class LoomDeviceLinkService {
  LoomDeviceLinkService({
    LoomIdentityCore? identityCore,
    LoomDeviceSecurityCore? deviceSecurityCore,
    LoomCredentialVault? credentialVault,
    LoomSessionVault? sessionVault,
    LoomSecurityClient? securityClient,
    LoomDeviceLinkClient? linkClient,
    LoomDeviceLinkCodec? codec,
  }) : _identityCore = identityCore ?? LoomIdentityCoreV1(),
       _deviceSecurityCore = deviceSecurityCore ?? LoomDeviceSecurityCoreV1(),
       _credentialVault = credentialVault ?? LoomSecureCredentialVault(),
       _sessionVault = sessionVault ?? LoomSecureSessionVault(),
       _securityClient = securityClient ?? LoomSecurityClient(),
       _linkClient = linkClient ?? LoomDeviceLinkClient(),
       _codec = codec ?? LoomDeviceLinkCodec();

  final LoomIdentityCore _identityCore;
  final LoomDeviceSecurityCore _deviceSecurityCore;
  final LoomCredentialVault _credentialVault;
  final LoomSessionVault _sessionVault;
  final LoomSecurityClient _securityClient;
  final LoomDeviceLinkClient _linkClient;
  final LoomDeviceLinkCodec _codec;

  Future<LoomCreatedDeviceLink> createInvitation(
    LoomOnboardingController onboarding,
  ) async {
    if (onboarding.status != LoomOnboardingStatus.complete) {
      throw const LoomProtocolException(
        'A signed-in trusted device is required to create a QR link',
      );
    }
    final expiresAt = onboarding.accessTokenExpiresAt;
    if (onboarding.accessToken == null ||
        onboarding.accessToken!.isEmpty ||
        (expiresAt != null &&
            expiresAt.isBefore(
              DateTime.now().toUtc().add(const Duration(seconds: 30)),
            ))) {
      if (!await onboarding.refreshAccessToken()) {
        throw const LoomProtocolException(
          'The trusted device session must be refreshed before linking',
        );
      }
    }

    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    final accessToken = onboarding.accessToken;
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (identity == null ||
        receipt == null ||
        accessToken == null ||
        accessToken.isEmpty ||
        endpoint == null) {
      throw const LoomProtocolException(
        'A signed-in trusted device is required to create a QR link',
      );
    }

    final recoveryEntropy = await _identityCore.exportRecoveryEntropy();
    final agreementSecret = await _deviceSecurityCore.exportAgreementSecret(
      identityId: identity.identityId,
      deviceId: receipt.deviceId,
    );
    try {
      final linkId = _codec.createLinkId();
      final token = _codec.createToken();
      final encryptionSecret = _codec.createEncryptionSecret();
      final payload = await _codec.seal(
        linkId: linkId,
        encryptionSecret: encryptionSecret,
        identityId: identity.identityId,
        sourceDeviceId: receipt.deviceId,
        recoveryEntropy: recoveryEntropy,
        sourceAgreementSecret: agreementSecret,
      );
      final proof = await onboarding.deviceRequestProofProvider();
      final created = await _linkClient.createInvitation(
        baseUri: endpoint,
        accessToken: accessToken,
        linkId: linkId,
        tokenHash: await _codec.tokenHash(token),
        payload: payload,
        deviceProofProvider: proof,
      );
      return LoomCreatedDeviceLink(
        qrPayload: _codec.qrPayload(
          homeNode: receipt.homeNode,
          linkId: linkId,
          token: token,
          encryptionSecret: encryptionSecret,
        ),
        expiresAt: created.expiresAt,
        linkId: linkId,
      );
    } finally {
      for (var index = 0; index < recoveryEntropy.length; index++) {
        recoveryEntropy[index] = 0;
      }
      for (var index = 0; index < agreementSecret.length; index++) {
        agreementSecret[index] = 0;
      }
    }
  }

  Future<void> redeemAndActivate({
    required LoomOnboardingController onboarding,
    required LoomPendingDeviceLinkSession pending,
    required String qrPayload,
  }) async {
    final qr = _codec.parseQrPayload(qrPayload);
    final expectedNode = pending.login.receipt.homeNode.toLowerCase();
    if (qr.homeNode.toLowerCase() != expectedNode ||
        pending.endpoint.authority.toLowerCase() != expectedNode) {
      throw const LoomProtocolException(
        'This QR belongs to a different Home Node',
      );
    }

    final redemption = await _linkClient.redeem(
      baseUri: pending.endpoint,
      accessToken: pending.login.accessToken,
      linkId: qr.linkId,
      token: qr.token,
    );
    if (redemption.identityId != pending.login.identityId) {
      throw const LoomProtocolException(
        'Device-link identity does not match the password-authenticated account',
      );
    }

    final package = await _codec.open(
      envelope: redemption.payload,
      linkId: qr.linkId,
      encryptionSecret: qr.encryptionSecret,
      expectedIdentityId: pending.login.identityId,
      sourceDeviceId: redemption.sourceDeviceId,
    );
    try {
      final identity = await _identityCore.importRecoveryEntropy(
        package.recoveryEntropy,
      );
      if (identity.identityId != pending.login.identityId) {
        throw const LoomProtocolException(
          'Transferred identity does not match the signed-in account',
        );
      }
      await _deviceSecurityCore.importHistoricalAgreementSecret(
        identityId: identity.identityId,
        sourceDeviceId: package.sourceDeviceId,
        secret: package.sourceAgreementSecret,
      );

      final bundle = await _deviceSecurityCore.createOrLoadDevice(
        identity: identity,
        deviceId: pending.login.receipt.deviceId,
        deviceName: 'Loom ${Platform.operatingSystem}',
        identitySigner: _identityCore,
      );
      await _securityClient.publishDeviceBundle(
        baseUri: pending.endpoint,
        accessToken: pending.login.accessToken,
        bundle: bundle,
      );

      final proof = LoomDeviceRequestProofProvider(
        deviceId: pending.login.receipt.deviceId,
        signer: (payload) => _deviceSecurityCore.signDevicePayload(
          identityId: identity.identityId,
          deviceId: pending.login.receipt.deviceId,
          payload: payload,
        ),
      );

      await _credentialVault.writeRefreshToken(
        homeNode: pending.login.receipt.homeNode,
        deviceId: pending.login.receipt.deviceId,
        refreshToken: pending.login.refreshToken,
      );

      final selectedNode = onboarding.nodes.selectedNode;
      final selectedLiveInfo = onboarding.nodes.selectedLiveInfo;
      final selectedEndpoint = onboarding.nodes.selectedEndpoint;
      if (!onboarding.nodes.selectedNodeVerified ||
          selectedNode == null ||
          selectedLiveInfo == null ||
          selectedEndpoint == null ||
          selectedEndpoint.authority.toLowerCase() != expectedNode) {
        throw const LoomProtocolException(
          'Verified Home Node context changed during device linking',
        );
      }
      final storedSession = LoomStoredSession(
        endpoint: selectedEndpoint,
        node: selectedNode,
        liveInfo: selectedLiveInfo,
        receipt: pending.login.receipt,
      );
      await _sessionVault.write(storedSession);
      onboarding.completeLinkedSession(
        identity: identity,
        login: pending.login,
        storedSession: storedSession,
        username: pending.username,
      );

      try {
        await _linkClient.complete(
          baseUri: pending.endpoint,
          accessToken: pending.login.accessToken,
          linkId: qr.linkId,
          deviceProofProvider: proof,
        );
      } catch (_) {
        // Activation is already complete. The invitation is target-bound and
        // expires shortly even if this best-effort cleanup cannot be delivered.
      }
    } finally {
      package.recoveryEntropy.fillRange(0, package.recoveryEntropy.length, 0);
      package.sourceAgreementSecret.fillRange(
        0,
        package.sourceAgreementSecret.length,
        0,
      );
    }
  }
}
