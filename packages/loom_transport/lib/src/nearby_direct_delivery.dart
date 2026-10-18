import 'dart:async';
import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';

import 'nearby_transport.dart';

const String loomNearbyDirectEnvelopeKind = 'direct.message.v1';
const String loomNearbyDirectAckKind = 'direct.ack.v1';

class LoomNearbyDirectEnvelope {
  const LoomNearbyDirectEnvelope({
    required this.deliveryId,
    required this.conversationId,
    required this.clientId,
    required this.senderAddress,
    required this.senderIdentityId,
    required this.senderDeviceId,
    required this.recipientIdentityId,
    required this.messageType,
    required this.ciphertext,
    required this.protocolVersion,
    required this.createdAt,
    this.replyToMessageId,
    this.metadata = const <String, Object?>{},
  });

  factory LoomNearbyDirectEnvelope.fromJson(Map<String, Object?> json) {
    String string(String key, {int max = 4096}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid nearby envelope $key');
      }
      return value;
    }

    if (json['kind'] != loomNearbyDirectEnvelopeKind) {
      throw const FormatException('Unsupported nearby envelope kind');
    }
    final createdAt = DateTime.tryParse(string('createdAt'))?.toUtc();
    if (createdAt == null)
      throw const FormatException('Invalid nearby envelope createdAt');
    final typeName = string('messageType', max: 64);
    final metadataRaw = json['metadata'];
    if (metadataRaw is! Map<String, Object?>)
      throw const FormatException('Invalid nearby envelope metadata');
    final encodedMetadata = utf8.encode(jsonEncode(metadataRaw));
    if (encodedMetadata.length > 16 * 1024)
      throw const FormatException('Nearby metadata exceeds limit');
    return LoomNearbyDirectEnvelope(
      deliveryId: string('deliveryId', max: 256),
      conversationId: string('conversationId', max: 512),
      clientId: string('clientId', max: 256),
      senderAddress: string('senderAddress', max: 512),
      senderIdentityId: string('senderIdentityId', max: 512),
      senderDeviceId: string('senderDeviceId', max: 256),
      recipientIdentityId: string('recipientIdentityId', max: 512),
      messageType: LoomMessageType.values.byName(typeName),
      ciphertext: string('ciphertext', max: 240 * 1024),
      protocolVersion: string('protocolVersion', max: 128),
      createdAt: createdAt,
      replyToMessageId: json['replyToMessageId'] is String
          ? json['replyToMessageId'] as String
          : null,
      metadata: Map<String, Object?>.unmodifiable(metadataRaw),
    );
  }

  final String deliveryId;
  final String conversationId;
  final String clientId;
  final String senderAddress;
  final String senderIdentityId;
  final String senderDeviceId;
  final String recipientIdentityId;
  final LoomMessageType messageType;
  final String ciphertext;
  final String protocolVersion;
  final DateTime createdAt;
  final String? replyToMessageId;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': loomNearbyDirectEnvelopeKind,
        'deliveryId': deliveryId,
        'conversationId': conversationId,
        'clientId': clientId,
        'senderAddress': senderAddress,
        'senderIdentityId': senderIdentityId,
        'senderDeviceId': senderDeviceId,
        'recipientIdentityId': recipientIdentityId,
        'messageType': messageType.name,
        'ciphertext': ciphertext,
        'protocolVersion': protocolVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
        'metadata': metadata,
      };
}

class LoomNearbyDirectAck {
  const LoomNearbyDirectAck({
    required this.deliveryId,
    required this.clientId,
    required this.accepted,
  });

  factory LoomNearbyDirectAck.fromJson(Map<String, Object?> json) {
    if (json['kind'] != loomNearbyDirectAckKind ||
        json['deliveryId'] is! String ||
        json['clientId'] is! String ||
        json['accepted'] is! bool) {
      throw const FormatException('Invalid nearby delivery acknowledgement');
    }
    return LoomNearbyDirectAck(
      deliveryId: json['deliveryId'] as String,
      clientId: json['clientId'] as String,
      accepted: json['accepted'] as bool,
    );
  }

  final String deliveryId;
  final String clientId;
  final bool accepted;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': loomNearbyDirectAckKind,
        'deliveryId': deliveryId,
        'clientId': clientId,
        'accepted': accepted,
      };
}

/// Direct recipient delivery only. It is deliberately not a relay and it does
/// not remove the normal durable Home-Node pending operation. A later Node sync
/// remains authoritative and reconciles by clientId.
class LoomNearbyDirectDelivery {
  LoomNearbyDirectDelivery({required this.store, LoomNearbyPacketCodec? codec})
      : codec = codec ?? const LoomNearbyPacketCodec();

  final LoomMessagingStore store;
  final LoomNearbyPacketCodec codec;

  LoomNearbyDirectEnvelope fromPendingOperation({
    required LoomPendingOperation operation,
    required String deliveryId,
    required String senderAddress,
    required String senderIdentityId,
    required String senderDeviceId,
    required String recipientIdentityId,
  }) {
    if (operation.kind != LoomPendingOperationKind.sendMessage) {
      throw const FormatException(
        'Nearby direct delivery supports sendMessage operations only',
      );
    }
    final ciphertext = operation.payload['ciphertext'];
    final protocolVersion = operation.payload['protocolVersion'];
    final typeRaw = operation.payload['type'];
    if (ciphertext is! String ||
        protocolVersion is! String ||
        typeRaw is! String) {
      throw const FormatException(
        'Pending message is missing opaque envelope fields',
      );
    }
    return LoomNearbyDirectEnvelope(
      deliveryId: deliveryId,
      conversationId: operation.conversationId,
      clientId: operation.clientId,
      senderAddress: senderAddress,
      senderIdentityId: senderIdentityId,
      senderDeviceId: senderDeviceId,
      recipientIdentityId: recipientIdentityId,
      messageType: LoomMessageType.values.byName(typeRaw.toLowerCase()),
      ciphertext: ciphertext,
      protocolVersion: protocolVersion,
      createdAt: operation.createdAt,
      replyToMessageId: operation.payload['replyToMessageId'] as String?,
    );
  }

  Future<LoomNearbyDirectAck> sendAndAwaitAck({
    required LoomNearbySecureConnection connection,
    required LoomNearbyDirectEnvelope envelope,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await connection.send(encodeEnvelope(envelope));
    final bytes = await connection.receive(timeout: timeout);
    final ack = LoomNearbyDirectAck.fromJson(codec.decode(bytes));
    if (ack.deliveryId != envelope.deliveryId ||
        ack.clientId != envelope.clientId) {
      throw const FormatException(
        'Nearby acknowledgement does not match delivery',
      );
    }
    markAcknowledged(ack);
    return ack;
  }

  Future<LoomNearbyDirectAck> receiveAndAcknowledge({
    required LoomNearbySecureConnection connection,
    required String localIdentityId,
    required String authenticatedRemoteIdentityId,
    required String authenticatedRemoteDeviceId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final bytes = await connection.receive(timeout: timeout);
    final ack = await receive(
      packetBytes: bytes,
      localIdentityId: localIdentityId,
      authenticatedRemoteIdentityId: authenticatedRemoteIdentityId,
      authenticatedRemoteDeviceId: authenticatedRemoteDeviceId,
    );
    await connection.send(encodeAck(ack));
    return ack;
  }

  Future<LoomNearbyDirectAck> receive({
    required List<int> packetBytes,
    required String localIdentityId,
    required String authenticatedRemoteIdentityId,
    required String authenticatedRemoteDeviceId,
  }) async {
    final envelope = LoomNearbyDirectEnvelope.fromJson(
      codec.decode(packetBytes),
    );
    if (envelope.recipientIdentityId != localIdentityId ||
        envelope.senderIdentityId != authenticatedRemoteIdentityId ||
        envelope.senderDeviceId != authenticatedRemoteDeviceId) {
      return LoomNearbyDirectAck(
        deliveryId: envelope.deliveryId,
        clientId: envelope.clientId,
        accepted: false,
      );
    }

    final now = DateTime.now().toUtc();
    final skewSeconds = now.difference(envelope.createdAt).inSeconds.abs();
    if (skewSeconds > const Duration(days: 7).inSeconds) {
      return LoomNearbyDirectAck(
        deliveryId: envelope.deliveryId,
        clientId: envelope.clientId,
        accepted: false,
      );
    }

    try {
      store.putMessage(
        LoomMessageRecord(
          id: 'nearby:${envelope.clientId}',
          clientId: envelope.clientId,
          conversationId: envelope.conversationId,
          senderAddress: envelope.senderAddress,
          type: envelope.messageType,
          ciphertext: envelope.ciphertext,
          protocolVersion: envelope.protocolVersion,
          createdOrder: envelope.createdAt.microsecondsSinceEpoch,
          createdAt: envelope.createdAt,
          deliveryState: LoomDeliveryState.delivered,
          replyToMessageId: envelope.replyToMessageId,
          metadata: <String, Object?>{
            ...envelope.metadata,
            'receivedVia': 'nearby-direct-v1',
            'senderDeviceId': envelope.senderDeviceId,
          },
        ),
      );
      return LoomNearbyDirectAck(
        deliveryId: envelope.deliveryId,
        clientId: envelope.clientId,
        accepted: true,
      );
    } catch (_) {
      // Unknown/deleted conversations or local storage failures are not silently
      // accepted. The sender retains its Home-Node pending operation.
      return LoomNearbyDirectAck(
        deliveryId: envelope.deliveryId,
        clientId: envelope.clientId,
        accepted: false,
      );
    }
  }

  List<int> encodeEnvelope(LoomNearbyDirectEnvelope envelope) =>
      codec.encode(envelope.toJson());
  List<int> encodeAck(LoomNearbyDirectAck ack) => codec.encode(ack.toJson());

  void markAcknowledged(LoomNearbyDirectAck ack) {
    if (ack.accepted) {
      store.updateDeliveryByClientId(ack.clientId, LoomDeliveryState.delivered);
    }
    // Intentionally do not complete the durable pending operation. Nearby
    // direct delivery accelerates recipient delivery; it does not replace the
    // account's eventual Home-Node synchronization path.
  }
}
