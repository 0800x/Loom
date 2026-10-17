import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('inner envelope protobuf round trip preserves protected metadata', () {
    final source = LoomInnerEnvelopeV2(
      messageId: 'message-00000001',
      conversationRef: 'conversation-00000001',
      senderAccountId: 'account-sender-00000001',
      senderDeviceId: 'device-sender-00000001',
      recipientAccountId: 'account-recipient-00000001',
      recipientDeviceId: 'device-recipient-00000001',
      contentKind: LoomInnerContentKindV2.text,
      contentPayload: Uint8List.fromList(<int>[1, 2, 3, 4]),
      createdAt: DateTime.utc(2026, 9, 5, 12, 30),
      replyToMessageId: 'message-previous-0001',
      receiptPolicy: LoomReceiptPolicyV2.deliveredAndRead,
    );

    final bytes = LoomEnvelopeV2Codec.encodeInner(source);
    expect(bytes.take(2), <int>[0x08, 0x02]);

    final decoded = LoomEnvelopeV2Codec.decodeInner(bytes);
    expect(decoded.version, LoomProtocolVersions.innerEnvelopeV2);
    expect(decoded.messageId, source.messageId);
    expect(decoded.conversationRef, source.conversationRef);
    expect(decoded.senderAccountId, source.senderAccountId);
    expect(decoded.senderDeviceId, source.senderDeviceId);
    expect(decoded.recipientAccountId, source.recipientAccountId);
    expect(decoded.recipientDeviceId, source.recipientDeviceId);
    expect(decoded.contentKind, source.contentKind);
    expect(decoded.contentPayload, source.contentPayload);
    expect(decoded.createdAt, source.createdAt);
    expect(decoded.replyToMessageId, source.replyToMessageId);
    expect(decoded.receiptPolicy, source.receiptPolicy);
  });

  test('session ciphertext protobuf round trip preserves provider metadata',
      () {
    final source = LoomSessionCiphertextWireV2(
      protocolVersion: 'Loom-Session-v2',
      sessionLocator: 'opaque-session-locator',
      ciphertext: Uint8List.fromList(<int>[9, 10, 11, 12]),
    );

    final encoded = LoomEnvelopeV2Codec.encodeSessionCiphertext(source);
    final decoded = LoomEnvelopeV2Codec.decodeSessionCiphertext(encoded);

    expect(
      decoded.version,
      LoomProtocolVersions.sessionCiphertextEnvelopeV2,
    );
    expect(decoded.protocolVersion, source.protocolVersion);
    expect(decoded.sessionLocator, source.sessionLocator);
    expect(decoded.ciphertext, source.ciphertext);
  });

  test('outer envelope protobuf round trip preserves only routable metadata',
      () {
    final source = LoomOuterEnvelopeV2(
      packetId: 'packet-000000000001',
      routingHint: LoomRoutingHintV2(
        scope: LoomRoutingScopeV2.globalRelay,
        mailboxToken: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      ),
      expiresAtBucket: DateTime.utc(2026, 9, 12, 12),
      priority: LoomPriorityClassV2.urgent,
      initialHopLimit: 6,
      forwardingState: const LoomForwardingStateV2(
        hopsUsed: 2,
        copiesRemaining: 4,
      ),
      encryptedPayload: Uint8List.fromList(<int>[9, 8, 7, 6, 5]),
    );

    final bytes = LoomEnvelopeV2Codec.encodeOuter(source);
    expect(bytes.take(2), <int>[0x08, 0x02]);

    final decoded = LoomEnvelopeV2Codec.decodeOuter(bytes);
    expect(decoded.packetId, source.packetId);
    expect(decoded.routingHint.scope, source.routingHint.scope);
    expect(decoded.routingHint.mailboxToken, source.routingHint.mailboxToken);
    expect(decoded.expiresAtBucket, source.expiresAtBucket);
    expect(decoded.priority, source.priority);
    expect(decoded.initialHopLimit, source.initialHopLimit);
    expect(decoded.forwardingState.hopsUsed, 2);
    expect(decoded.forwardingState.copiesRemaining, 4);
    expect(decoded.encryptedPayload, source.encryptedPayload);
  });

  test('delivery receipt has a pinned protobuf golden vector', () {
    const source = LoomDeliveryReceiptV2(
      forMessageId: 'message-00000001',
      recipientDeviceId: 'device-recipient-00000001',
    );

    final encoded = LoomEnvelopeV2Codec.encodeDeliveryReceipt(source);
    expect(encoded, <int>[
      0x08,
      0x02,
      0x12,
      0x10,
      ...'message-00000001'.codeUnits,
      0x1a,
      0x19,
      ...'device-recipient-00000001'.codeUnits,
      0x20,
      0x01,
    ]);

    final decoded = LoomEnvelopeV2Codec.decodeDeliveryReceipt(encoded);
    expect(decoded.version, LoomProtocolVersions.deliveryReceiptV2);
    expect(decoded.forMessageId, source.forMessageId);
    expect(decoded.recipientDeviceId, source.recipientDeviceId);
    expect(decoded.status, LoomDeliveryReceiptStatusV2.delivered);
    expect(decoded.receivedAt, isNull);
  });

  test('delivery receipt protobuf round trip preserves optional timestamp', () {
    final source = LoomDeliveryReceiptV2(
      forMessageId: 'message-00000001',
      recipientDeviceId: 'device-recipient-00000001',
      receivedAt: DateTime.utc(2026, 9, 5, 12, 31),
    );

    final encoded = LoomEnvelopeV2Codec.encodeDeliveryReceipt(source);
    final decoded = LoomEnvelopeV2Codec.decodeDeliveryReceipt(encoded);

    expect(decoded.receivedAt, source.receivedAt);
  });

  test('unknown protobuf fields fail closed for Envelope v2', () {
    final source = LoomOuterEnvelopeV2(
      packetId: 'packet-000000000001',
      routingHint: LoomRoutingHintV2(
        scope: LoomRoutingScopeV2.domesticRelay,
        mailboxToken: Uint8List.fromList(List<int>.filled(32, 3)),
      ),
      expiresAtBucket: DateTime.utc(2026, 9, 12, 12),
      priority: LoomPriorityClassV2.normal,
      initialHopLimit: 4,
      forwardingState: const LoomForwardingStateV2(
        hopsUsed: 0,
        copiesRemaining: 4,
      ),
      encryptedPayload: Uint8List.fromList(<int>[1, 2, 3]),
    );
    final encoded = LoomEnvelopeV2Codec.encodeOuter(source);
    final withUnknown = Uint8List.fromList(<int>[
      ...encoded,
      0x98,
      0x06, // field 99, varint
      0x01,
    ]);

    expect(
      () => LoomEnvelopeV2Codec.decodeOuter(withUnknown),
      throwsFormatException,
    );
  });

  test('duplicate singular protobuf fields fail closed', () {
    const source = LoomDeliveryReceiptV2(
      forMessageId: 'message-00000001',
      recipientDeviceId: 'device-recipient-00000001',
    );
    final encoded = LoomEnvelopeV2Codec.encodeDeliveryReceipt(source);
    final duplicateVersion = Uint8List.fromList(<int>[
      ...encoded,
      0x08,
      0x02,
    ]);

    expect(
      () => LoomEnvelopeV2Codec.decodeDeliveryReceipt(duplicateVersion),
      throwsFormatException,
    );
  });

  test('truncated length-delimited protobuf field fails closed', () {
    final malformed = Uint8List.fromList(<int>[
      0x08,
      0x02,
      0x12,
      0x05,
      0x61,
      0x62,
    ]);

    expect(
      () => LoomEnvelopeV2Codec.decodeDeliveryReceipt(malformed),
      throwsFormatException,
    );
  });

  test('protobuf enum zero is never accepted as an application default', () {
    final malformedReceipt = Uint8List.fromList(<int>[
      0x08,
      0x02,
      0x12,
      0x10,
      ...'message-00000001'.codeUnits,
      0x1a,
      0x19,
      ...'device-recipient-00000001'.codeUnits,
      0x20,
      0x00,
    ]);

    expect(
      () => LoomEnvelopeV2Codec.decodeDeliveryReceipt(malformedReceipt),
      throwsFormatException,
    );
  });

  test('non-minimal protobuf varints fail closed', () {
    final malformedVersion = Uint8List.fromList(<int>[
      0x08,
      0x82,
      0x00,
    ]);

    expect(
      () => LoomEnvelopeV2Codec.decodeDeliveryReceipt(malformedVersion),
      throwsFormatException,
    );
  });
}
