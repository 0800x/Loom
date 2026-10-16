import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';

import 'legacy_dtn_custody.dart';
import 'offline_device_directory_cache.dart';

/// Receipts use the normal durable, encrypted store/carry path in reverse.
/// They never enter the chat timeline and never generate another receipt.
abstract final class LoomNearbyMessageReceipts {
  static Future<LoomResolvedUserSecurity?> _peer(
    String path,
    String address,
  ) async {
    final security = LoomSecurityStore.openFile(
      '$path/loom_security.sqlite3',
    );
    final pins = LoomPeerIdentityStore.openFile(
      '$path/loom_security.sqlite3',
    );
    try {
      return await LoomOfflineDeviceDirectoryCache(
        securityStore: security,
        peerIdentityStore: pins,
      ).loadPeer(address: address, now: DateTime.now().toUtc());
    } finally {
      pins.close();
      security.close();
    }
  }

  static Future<void> flush({
    required String applicationSupportPath,
    required String ownAddress,
    required String identityId,
    required String deviceId,
    required LoomDeviceSecurityCore deviceSecurity,
    String? onlyClientId,
  }) async {
    final store = LoomMessagingStore.openFile(
      '$applicationSupportPath/loom-messages-v1.sqlite3',
    );
    try {
      final pending =
          onlyClientId == null
              ? store.pendingNearbyReceipts()
              : <String>[onlyClientId];
      for (final id in pending) {
        try {
          final message = store.messageByClientId(id);
          if (message == null ||
              message.senderAddress.toLowerCase() == ownAddress.toLowerCase()) {
            store.completeNearbyReceipt(id);
            continue;
          }
          final peer = await _peer(
            applicationSupportPath,
            message.senderAddress,
          );
          if (peer == null || peer.devices.isEmpty) continue;
          final receipt = await LoomNearbyMessageReceipt.create(
            clientId: id,
            sender: message.senderAddress,
            recipient: ownAddress,
            deviceId: deviceId,
            ciphertext: message.ciphertext,
            sign:
                (bytes) => deviceSecurity.signDevicePayload(
                  identityId: identityId,
                  deviceId: deviceId,
                  payload: Uint8List.fromList(bytes),
                ),
          );
          // Fixed-size id avoids client-id truncation and makes replays idempotent.
          final receiptId =
              'nr_${await LoomNearbyMessageReceipt.ciphertextDigest(receipt.encode())}';
          await const LoomLegacyDtnCustodyWriter().persist(
            applicationSupportPath: applicationSupportPath,
            destinationNodeDomain:
                LoomAddress.parseCanonical(peer.address).homeNode,
            senderAddress: ownAddress,
            conversationId: message.conversationId,
            clientId: receiptId,
            type: LoomMessageType.system,
            ciphertext: receipt.encode(),
            protocolVersion: LoomNearbyMessageReceipt.protocol,
            recipientDevices: peer.devices,
          );
          // Remove only after reverse packets are committed. A crash before this
          // line safely reuses the deterministic packets on the next sweep.
          store.completeNearbyReceipt(id);
        } catch (_) {
          /* Retain pending work for the next encounter/restart. */
        }
      }
    } finally {
      store.close();
    }
  }

  static Future<bool> accept({
    required String applicationSupportPath,
    required String ownAddress,
    required LoomLegacyDtnMessageCapsule capsule,
  }) async {
    if (capsule.type != LoomMessageType.system) return false;
    final receipt = LoomNearbyMessageReceipt.decode(capsule.ciphertext);
    if (receipt.sender.toLowerCase() != ownAddress.toLowerCase() ||
        receipt.recipient.toLowerCase() !=
            capsule.senderAddress.toLowerCase()) {
      return false;
    }
    final store = LoomMessagingStore.openFile(
      '$applicationSupportPath/loom-messages-v1.sqlite3',
    );
    try {
      final message = store.messageByClientId(receipt.clientId);
      if (message == null ||
          message.senderAddress.toLowerCase() != ownAddress.toLowerCase()) {
        return false;
      }
      final conversation = store.conversationById(message.conversationId);
      final peerAddress = conversation?.peerAddress;
      if (conversation?.kind != LoomConversationKind.direct ||
          peerAddress == null ||
          peerAddress.toLowerCase() != receipt.recipient.toLowerCase()) {
        return false;
      }
      final peer = await _peer(applicationSupportPath, peerAddress);
      if (peer == null) return false;
      for (final device in peer.devices) {
        if (device.deviceId != receipt.deviceId) continue;
        if (!await receipt.verify(
          expectedClientId: message.clientId,
          expectedSender: ownAddress,
          expectedRecipient: peerAddress,
          expectedDeviceId: device.deviceId,
          ciphertext: message.ciphertext,
          trustedSigningPublicKey: device.signingPublicKey,
        )) {
          return false;
        }
        store.transaction(() {
          store.updateDeliveryByClientId(
            message.clientId,
            LoomDeliveryState.delivered,
          );
          store.recordTransportPath(
            message.clientId,
            LoomMessageTransportPath.nearby,
            mergeRoutes: true,
          );
        });
        return true;
      }
      return false;
    } finally {
      store.close();
    }
  }
}
