import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';

import 'v2_messaging_runtime.dart';

/// Product-facing Architecture-v2 messaging seam.
///
/// This facade is intentionally fail-closed. Merely opening v2 databases is not
/// enough: a provider, state protector, current Directory-v2 authorization and
/// verified prekey/session-identity evidence are required at the relevant step.
final class LoomV2ProductMessaging {
  const LoomV2ProductMessaging({required this.runtime});

  final LoomV2MessagingRuntime runtime;

  Future<String> establishOutgoingFromClaimedPrekey({
    required LoomRemoteDeviceRef remoteDevice,
    required Uint8List claimedAuthorizedPrekeyWire,
    required DateTime now,
  }) async {
    final provider = await _requireSendReady();
    final authorizedDevice = runtime.deviceDirectoryStore.resolveDevice(
      accountId: remoteDevice.accountId,
      deviceId: remoteDevice.deviceId,
      deviceKeyVersion: remoteDevice.deviceKeyVersion,
      now: now,
    );
    if (authorizedDevice == null) {
      throw const LoomCryptoStateConflict(
        'Remote device is not currently authorized by Directory v2',
      );
    }

    final authorization = LoomAuthorizedPrekeyWireV1.decode(
      claimedAuthorizedPrekeyWire,
    );
    final verified = await LoomPrekeyAuthorizationVerifierV1(
      deviceSignatureVerifier: LoomDevicePrekeySignatureVerifier(
        keyResolver: runtime.deviceDirectoryStore,
      ),
    ).verify(
      authorization: authorization,
      now: now,
      expectedProviderProtocolVersion: provider.protocolVersion,
    );

    return runtime.cryptoStateStore.runDurably(
      (transaction) => establishLoomOutgoingFromVerifiedPrekey(
        provider: provider,
        transaction: transaction,
        remoteDevice: remoteDevice,
        verifiedPrekey: verified,
      ),
    );
  }

  /// Crypto commit -> exact committed ciphertext -> durable DTN custody ->
  /// durable receipt correlation. No transport operation occurs here.
  Future<LoomStoredDtnPacket> sendText({
    required LoomV2TextIntent intent,
    required int recipientDeviceKeyVersion,
    required LoomV2PacketAssemblyPlan packetPlan,
  }) async {
    await _requireSendReady();
    if (recipientDeviceKeyVersion < 1) {
      throw const FormatException('Invalid recipient device key version');
    }
    final authorizedDevice = runtime.deviceDirectoryStore.resolveDevice(
      accountId: intent.recipientAccountId,
      deviceId: intent.recipientDeviceId,
      deviceKeyVersion: recipientDeviceKeyVersion,
      now: intent.createdAt,
    );
    if (authorizedDevice == null) {
      throw const LoomCryptoStateConflict(
        'Recipient device authorization changed before send',
      );
    }

    final coordinator = runtime.outgoingCoordinator;
    if (coordinator == null) {
      throw StateError('V2 outgoing coordinator is unavailable');
    }
    final committed = await coordinator.encryptAndCommitText(intent);
    final existingPacket = runtime.packetStore.read(committed.packetId);
    if (existingPacket != null) {
      if (existingPacket.messageId != committed.messageId ||
          existingPacket.operationId != committed.operationId) {
        throw const LoomDtnPacketConflict(
          'Existing DTN custody conflicts with crypto outbox correlation',
        );
      }
      runtime.messageStateStore.registerOutboundPacket(
        messageId: committed.messageId,
        packetId: committed.packetId,
        recipientDeviceId: intent.recipientDeviceId,
        createdAt: existingPacket.storedAt,
        expiresAt: existingPacket.expiresAt,
      );
      return existingPacket;
    }

    final storedCrypto = LoomStoredCryptoOutboxRecord(
      record: committed,
      state: LoomCryptoOutboxState.pending,
      attemptCount: 0,
      nextAttemptAt: committed.createdAt,
      acknowledgedAt: null,
    );
    return runtime.packetCustodyService.persistPendingForRecipient(
      stored: storedCrypto,
      plan: packetPlan,
      messageStateStore: runtime.messageStateStore,
      recipientDeviceId: intent.recipientDeviceId,
      now: intent.createdAt,
    );
  }

  /// First inbound asynchronous/prekey message. The remote provider identity
  /// must already be verified/cached by the contact/device trust layer; an
  /// untrusted first packet cannot self-assert its own session identity.
  Future<LoomInboundSessionBootstrapResult> receiveInitialPrekey({
    required LoomRemoteDeviceRef remoteDevice,
    required Uint8List verifiedRemoteSessionIdentity,
    required LoomSessionCiphertext ciphertext,
    required String bootstrapReplayKey,
    required DateTime now,
  }) async {
    final provider = _requireReceiveProvider();
    if (runtime.deviceDirectoryStore.resolveDevice(
          accountId: remoteDevice.accountId,
          deviceId: remoteDevice.deviceId,
          deviceKeyVersion: remoteDevice.deviceKeyVersion,
          now: now,
        ) ==
        null) {
      throw const LoomCryptoStateConflict(
        'Inbound sender device is not currently authorized',
      );
    }
    if (provider is! LoomInboundSessionBootstrapProvider) {
      throw StateError('Configured provider cannot bootstrap inbound sessions');
    }
    final bootstrapProvider = provider as LoomInboundSessionBootstrapProvider;
    return runtime.cryptoStateStore.runDurably(
      (transaction) => bootstrapProvider.establishIncomingAndDecrypt(
        transaction: transaction,
        remoteDevice: remoteDevice,
        verifiedRemoteSessionIdentity: verifiedRemoteSessionIdentity,
        ciphertext: ciphertext,
        bootstrapReplayKey: bootstrapReplayKey,
        now: now,
      ),
    );
  }

  Future<Uint8List> receiveEstablished({
    required LoomSessionCiphertext ciphertext,
    required DateTime now,
  }) {
    final provider = _requireReceiveProvider();
    return runtime.cryptoStateStore.runDurably(
      (transaction) => provider.decryptAndAdvance(
        transaction: transaction,
        ciphertext: ciphertext,
        now: now,
      ),
    );
  }

  Future<LoomSessionCryptoProvider> _requireSendReady() async {
    if (!runtime.productionSendEnabled ||
        !await runtime.stateProtectionAvailable()) {
      throw StateError('Architecture-v2 production send gate is closed');
    }
    final provider = runtime.sessionProvider;
    if (provider == null) {
      throw StateError('Architecture-v2 session provider is unavailable');
    }
    return provider;
  }

  LoomSessionCryptoProvider _requireReceiveProvider() {
    final provider = runtime.sessionProvider;
    if (provider == null || runtime.stateProtector == null) {
      throw StateError('Architecture-v2 receive provider gate is closed');
    }
    return provider;
  }
}
