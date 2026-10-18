import 'dart:typed_data';

import 'protocol_versions.dart';

enum LoomInnerContentKindV2 {
  text,
  deliveryReceipt,
  sessionControl,
  attachmentReference,
}

enum LoomReceiptPolicyV2 { none, delivered, deliveredAndRead }

enum LoomRoutingScopeV2 { localDevice, domesticRelay, globalRelay }

enum LoomPriorityClassV2 { normal, urgent }

enum LoomDeliveryReceiptStatusV2 { delivered }

/// Protected message metadata and content carried inside session encryption.
///
/// This class is a protocol model, not a wire codec. Fields here must never be
/// copied into the routable outer envelope merely for convenience.
final class LoomInnerEnvelopeV2 {
  LoomInnerEnvelopeV2({
    required this.messageId,
    required this.conversationRef,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.recipientAccountId,
    required this.recipientDeviceId,
    required this.contentKind,
    required Uint8List contentPayload,
    required this.createdAt,
    this.replyToMessageId,
    this.receiptPolicy = LoomReceiptPolicyV2.delivered,
  }) : contentPayload = Uint8List.fromList(contentPayload);

  int get version => LoomProtocolVersions.innerEnvelopeV2;

  final String messageId;
  final String conversationRef;
  final String senderAccountId;
  final String senderDeviceId;
  final String recipientAccountId;
  final String recipientDeviceId;
  final LoomInnerContentKindV2 contentKind;
  final Uint8List contentPayload;
  final DateTime createdAt;
  final String? replyToMessageId;
  final LoomReceiptPolicyV2 receiptPolicy;

  void validate({int maxContentBytes = 1024 * 1024}) {
    _validateOpaqueId(messageId, 'message id');
    _validateOpaqueId(conversationRef, 'conversation ref', maxLength: 256);
    _validateOpaqueId(senderAccountId, 'sender account id', maxLength: 256);
    _validateOpaqueId(senderDeviceId, 'sender device id', maxLength: 256);
    _validateOpaqueId(
      recipientAccountId,
      'recipient account id',
      maxLength: 256,
    );
    _validateOpaqueId(recipientDeviceId, 'recipient device id', maxLength: 256);
    if (replyToMessageId != null) {
      _validateOpaqueId(replyToMessageId!, 'reply-to message id');
      if (replyToMessageId == messageId) {
        throw const FormatException('Message cannot reply to itself');
      }
    }
    if (contentPayload.isEmpty || contentPayload.length > maxContentBytes) {
      throw const FormatException('Invalid inner content payload size');
    }
    if (createdAt.year < 2020 || createdAt.year >= 2200) {
      throw const FormatException('Invalid inner envelope creation time');
    }
  }
}

/// Wire representation of a session provider's encrypted output.
///
/// This object is endpoint-only. Routers see it only as the opaque
/// `OuterEnvelopeV2.encryptedPayload` byte string. Provider-specific ratchet
/// headers may be contained inside [ciphertext].
final class LoomSessionCiphertextWireV2 {
  LoomSessionCiphertextWireV2({
    required this.protocolVersion,
    required this.sessionLocator,
    required Uint8List ciphertext,
  }) : ciphertext = Uint8List.fromList(ciphertext);

  int get version => LoomProtocolVersions.sessionCiphertextEnvelopeV2;

  final String protocolVersion;
  final String sessionLocator;
  final Uint8List ciphertext;

  void validate({int maxCiphertextBytes = 1024 * 1024}) {
    if (protocolVersion.trim() != protocolVersion ||
        protocolVersion.isEmpty ||
        protocolVersion.length > 128) {
      throw const FormatException('Invalid session protocol version');
    }
    if (sessionLocator.trim() != sessionLocator ||
        sessionLocator.isEmpty ||
        sessionLocator.length > 256) {
      throw const FormatException('Invalid session locator');
    }
    if (ciphertext.isEmpty || ciphertext.length > maxCiphertextBytes) {
      throw const FormatException('Invalid session ciphertext size');
    }
  }
}

/// End-to-end protected delivery receipt. It is serialized as an inner content
/// payload and must never be treated as a hop or gateway acknowledgement.
final class LoomDeliveryReceiptV2 {
  const LoomDeliveryReceiptV2({
    required this.forMessageId,
    required this.recipientDeviceId,
    this.status = LoomDeliveryReceiptStatusV2.delivered,
    this.receivedAt,
  });

  int get version => LoomProtocolVersions.deliveryReceiptV2;

  final String forMessageId;
  final String recipientDeviceId;
  final LoomDeliveryReceiptStatusV2 status;
  final DateTime? receivedAt;

  void validate() {
    _validateOpaqueId(forMessageId, 'receipt message id');
    _validateOpaqueId(recipientDeviceId, 'receipt device id', maxLength: 256);
    if (receivedAt != null &&
        (receivedAt!.year < 2020 || receivedAt!.year >= 2200)) {
      throw const FormatException('Invalid receipt time');
    }
  }
}

/// Minimal routable destination information visible to DTN peers and gateways.
/// The mailbox token is opaque, rotating material; it is not an account,
/// username, stable device id, conversation id, or public key.
final class LoomRoutingHintV2 {
  LoomRoutingHintV2({required this.scope, required Uint8List mailboxToken})
    : mailboxToken = Uint8List.fromList(mailboxToken);

  final LoomRoutingScopeV2 scope;
  final Uint8List mailboxToken;

  void validate() {
    if (mailboxToken.length < 16 || mailboxToken.length > 128) {
      throw const FormatException('Invalid opaque mailbox token size');
    }
  }
}

/// Mutable DTN forwarding budget. These values are untrusted input and every
/// receiver must clamp them to local absolute policy before forwarding.
final class LoomForwardingStateV2 {
  const LoomForwardingStateV2({
    required this.hopsUsed,
    required this.copiesRemaining,
  });

  final int hopsUsed;
  final int copiesRemaining;

  void validate({required int initialHopLimit}) {
    if (hopsUsed < 0 || hopsUsed > initialHopLimit) {
      throw const FormatException('Invalid DTN hop count');
    }
    if (copiesRemaining < 1 || copiesRemaining > 16) {
      throw const FormatException('Invalid DTN copy budget');
    }
  }
}

/// Routable opaque packet visible to transports, DTN peers, gateways, and the
/// minimally trusted delivery service.
///
/// Sender identity, recipient identity, conversation, content type, reply
/// metadata, and delivery receipt policy are intentionally absent. Packet size
/// and coarse routing/lifetime information remain observable.
final class LoomOuterEnvelopeV2 {
  LoomOuterEnvelopeV2({
    required this.packetId,
    required this.routingHint,
    required this.expiresAtBucket,
    required this.priority,
    required this.initialHopLimit,
    required this.forwardingState,
    required Uint8List encryptedPayload,
  }) : encryptedPayload = Uint8List.fromList(encryptedPayload);

  int get version => LoomProtocolVersions.outerEnvelopeV2;

  final String packetId;
  final LoomRoutingHintV2 routingHint;
  final DateTime expiresAtBucket;
  final LoomPriorityClassV2 priority;
  final int initialHopLimit;
  final LoomForwardingStateV2 forwardingState;
  final Uint8List encryptedPayload;

  void validate({int maxPayloadBytes = 1024 * 1024}) {
    _validateOpaqueId(packetId, 'packet id');
    routingHint.validate();
    if (initialHopLimit < 1 || initialHopLimit > 8) {
      throw const FormatException('Invalid initial hop limit');
    }
    forwardingState.validate(initialHopLimit: initialHopLimit);
    if (expiresAtBucket.year < 2020 || expiresAtBucket.year >= 2200) {
      throw const FormatException('Invalid packet expiry bucket');
    }
    if (encryptedPayload.isEmpty || encryptedPayload.length > maxPayloadBytes) {
      throw const FormatException('Invalid encrypted payload size');
    }
  }

  bool isExpiredAt(DateTime now) =>
      !expiresAtBucket.toUtc().isAfter(now.toUtc());
}

void _validateOpaqueId(
  String value,
  String label, {
  int minLength = 8,
  int maxLength = 128,
}) {
  if (value.trim() != value ||
      value.length < minLength ||
      value.length > maxLength) {
    throw FormatException('Invalid $label');
  }
}
