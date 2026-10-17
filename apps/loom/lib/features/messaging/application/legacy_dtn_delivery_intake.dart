import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';

import 'nearby_message_receipts.dart';

/// Recipient-side bridge from generic Architecture-v2 packets back into the
/// ordinary production messaging database.
///
/// Acceptance returns true only after the recipient-only outer seal opens and
/// the existing production E2EE envelope has been durably committed. Message
/// plaintext is still decrypted later by the normal chat refresh path.
final class LoomLegacyDtnDeliveryIntake {
  const LoomLegacyDtnDeliveryIntake._();

  static Future<bool> acceptGatewayPacket({
    required String applicationSupportPath,
    required String ownAddress,
    required String identityId,
    required String deviceId,
    required LoomDeviceSecurityCore deviceSecurity,
    required LoomGatewayClaimPacket packet,
  }) async {
    Uint8List envelope;
    Uint8List mailbox;
    try {
      envelope = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(packet.envelopeBase64)),
      );
      mailbox = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(packet.mailboxToken)),
      );
    } catch (_) {
      return false;
    }
    return acceptEnvelope(
      applicationSupportPath: applicationSupportPath,
      ownAddress: ownAddress,
      identityId: identityId,
      deviceId: deviceId,
      deviceSecurity: deviceSecurity,
      expectedPacketId: packet.packetId,
      expectedMailboxToken: mailbox,
      exactOuterEnvelopeBytes: envelope,
      fallbackCreatedAt: packet.acceptedAt,
    );
  }

  static Future<bool> acceptMailboxPacket({
    required String applicationSupportPath,
    required String ownAddress,
    required String identityId,
    required String deviceId,
    required LoomDeviceSecurityCore deviceSecurity,
    required LoomV2MailboxPacket packet,
  }) => acceptEnvelope(
    applicationSupportPath: applicationSupportPath,
    ownAddress: ownAddress,
    identityId: identityId,
    deviceId: deviceId,
    deviceSecurity: deviceSecurity,
    expectedPacketId: packet.packetId,
    expectedMailboxToken: packet.mailboxToken,
    exactOuterEnvelopeBytes: packet.envelopeBytes,
    fallbackCreatedAt: packet.acceptedAt,
  );

  static Future<bool> acceptEnvelope({
    required String applicationSupportPath,
    required String ownAddress,
    required String identityId,
    required String deviceId,
    required LoomDeviceSecurityCore deviceSecurity,
    required String expectedPacketId,
    required Uint8List expectedMailboxToken,
    required Uint8List exactOuterEnvelopeBytes,
    required DateTime fallbackCreatedAt,
  }) async {
    try {
      final outer = LoomEnvelopeV2Codec.decodeOuter(exactOuterEnvelopeBytes);
      if (outer.packetId != expectedPacketId ||
          !_constantListEquals(
            outer.routingHint.mailboxToken,
            expectedMailboxToken,
          )) {
        return false;
      }
      final codec = LoomLegacyDtnCompatibilityCodec();
      final sealed = codec.decodeSealedPayload(outer.encryptedPayload);
      final clear = await deviceSecurity.openSealedPayload(
        identityId: identityId,
        deviceId: deviceId,
        payload: sealed,
        associatedData: codec.associatedData(
          packetId: outer.packetId,
          mailboxToken: outer.routingHint.mailboxToken,
          recipientDeviceId: deviceId,
        ),
      );
      final capsule = codec.decodeClearCapsule(clear);
      if (capsule.protocolVersion == LoomNearbyMessageReceipt.protocol) {
        return await LoomNearbyMessageReceipts.accept(
          applicationSupportPath: applicationSupportPath,
          ownAddress: ownAddress,
          capsule: capsule,
        );
      }
      final store = LoomMessagingStore.openFile(
        '$applicationSupportPath/loom-messages-v1.sqlite3',
      );
      try {
        store.transaction(() {
          final alreadyStored = store.hasMessageClientId(capsule.clientId);
          var conversation = _resolveConversation(
            store,
            ownAddress: ownAddress,
            capsule: capsule,
          );
          final incoming =
              capsule.senderAddress.toLowerCase() != ownAddress.toLowerCase();
          if (incoming && !alreadyStored) {
            conversation = LoomConversation(
              id: conversation.id,
              kind: conversation.kind,
              title: conversation.title,
              peerAddress: conversation.peerAddress,
              updatedOrder: conversation.updatedOrder,
              unreadCount: conversation.unreadCount + 1,
              isMuted: conversation.isMuted,
              isPinned: conversation.isPinned,
            );
          }
          store.upsertConversation(conversation);
          final createdAt =
              capsule.createdAt.year >= 2020
                  ? capsule.createdAt
                  : fallbackCreatedAt.toUtc();
          final localOrder = createdAt.microsecondsSinceEpoch;
          store.putMessage(
            LoomMessageRecord(
              id: 'dtn_${outer.packetId}',
              clientId: capsule.clientId,
              conversationId: conversation.id,
              senderAddress: capsule.senderAddress,
              type: capsule.type,
              ciphertext: capsule.ciphertext,
              protocolVersion: capsule.protocolVersion,
              createdOrder: localOrder,
              createdAt: createdAt,
              deliveryState:
                  incoming
                      ? LoomDeliveryState.delivered
                      : LoomDeliveryState.sent,
              transportPath: LoomMessageTransportPath.nearby,
              replyToMessageId: capsule.replyToMessageId,
              metadata: capsule.metadata,
            ),
          );
          if (incoming) store.queueNearbyReceipt(capsule.clientId);
        });
      } finally {
        store.close();
      }
      // Inbox + pending receipt were committed together; receipt transport may
      // fail independently without hiding the already-delivered message.
      try {
        await LoomNearbyMessageReceipts.flush(
          onlyClientId: capsule.clientId,
          applicationSupportPath: applicationSupportPath,
          ownAddress: ownAddress,
          identityId: identityId,
          deviceId: deviceId,
          deviceSecurity: deviceSecurity,
        );
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  static LoomConversation _resolveConversation(
    LoomMessagingStore store, {
    required String ownAddress,
    required LoomLegacyDtnMessageCapsule capsule,
  }) {
    final normalizedSender = capsule.senderAddress.toLowerCase();
    final own = ownAddress.toLowerCase();
    final conversations = store.listConversations(limit: 500);
    if (normalizedSender == own) {
      for (final conversation in conversations) {
        if (conversation.kind == LoomConversationKind.self) {
          return conversation;
        }
      }
      return LoomConversation(
        id: capsule.conversationId,
        kind: LoomConversationKind.self,
        title: null,
        peerAddress: ownAddress,
        updatedOrder: capsule.createdAt.microsecondsSinceEpoch,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      );
    }
    for (final conversation in conversations) {
      if (conversation.kind == LoomConversationKind.direct &&
          conversation.peerAddress?.toLowerCase() == normalizedSender) {
        return conversation;
      }
    }
    // Unread accounting is applied exactly once by acceptEnvelope after it has
    // checked client-id dedup, so a new direct conversation starts at zero here.
    return LoomConversation(
      id: capsule.conversationId,
      kind: LoomConversationKind.direct,
      title: null,
      peerAddress: capsule.senderAddress,
      updatedOrder: capsule.createdAt.microsecondsSinceEpoch,
      unreadCount: 0,
      isMuted: false,
      isPinned: false,
    );
  }

  static bool _constantListEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
