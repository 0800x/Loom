import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
      'inner envelope keeps identity and message metadata inside protected model',
      () {
    final source = Uint8List.fromList(<int>[1, 2, 3]);
    final envelope = LoomInnerEnvelopeV2(
      messageId: 'message-0001',
      conversationRef: 'conversation-0001',
      senderAccountId: 'account-sender-0001',
      senderDeviceId: 'device-sender-0001',
      recipientAccountId: 'account-recipient-0001',
      recipientDeviceId: 'device-recipient-0001',
      contentKind: LoomInnerContentKindV2.text,
      contentPayload: source,
      createdAt: DateTime.utc(2026, 9, 5, 12),
      receiptPolicy: LoomReceiptPolicyV2.delivered,
    );

    source[0] = 99;
    expect(envelope.version, LoomProtocolVersions.innerEnvelopeV2);
    expect(envelope.contentPayload, <int>[1, 2, 3]);
    expect(envelope.validate, returnsNormally);
  });

  test('outer envelope contains only opaque routing material and ciphertext',
      () {
    final mailboxToken = Uint8List.fromList(List<int>.filled(32, 7));
    final ciphertext = Uint8List.fromList(<int>[8, 9, 10]);
    final outer = LoomOuterEnvelopeV2(
      packetId: 'packet-00000001',
      routingHint: LoomRoutingHintV2(
        scope: LoomRoutingScopeV2.domesticRelay,
        mailboxToken: mailboxToken,
      ),
      expiresAtBucket: DateTime.utc(2026, 9, 12, 12),
      priority: LoomPriorityClassV2.normal,
      initialHopLimit: 4,
      forwardingState: const LoomForwardingStateV2(
        hopsUsed: 1,
        copiesRemaining: 2,
      ),
      encryptedPayload: ciphertext,
    );

    mailboxToken[0] = 99;
    ciphertext[0] = 99;
    expect(outer.version, LoomProtocolVersions.outerEnvelopeV2);
    expect(outer.routingHint.mailboxToken.first, 7);
    expect(outer.encryptedPayload, <int>[8, 9, 10]);
    expect(outer.validate, returnsNormally);
    expect(outer.isExpiredAt(DateTime.utc(2026, 9, 13)), isTrue);
  });

  test('routing hints reject short linkable tokens', () {
    final hint = LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(<int>[1, 2, 3]),
    );

    expect(hint.validate, throwsFormatException);
  });

  test('forwarding state cannot exceed packet hop budget', () {
    const state = LoomForwardingStateV2(
      hopsUsed: 5,
      copiesRemaining: 1,
    );

    expect(
      () => state.validate(initialHopLimit: 4),
      throwsFormatException,
    );
  });

  test('delivery receipt is an end-to-end inner content model', () {
    final receipt = LoomDeliveryReceiptV2(
      forMessageId: 'message-0001',
      recipientDeviceId: 'device-recipient-0001',
      receivedAt: DateTime.utc(2026, 9, 5, 12, 1),
    );

    expect(receipt.version, LoomProtocolVersions.deliveryReceiptV2);
    expect(receipt.status, LoomDeliveryReceiptStatusV2.delivered);
    expect(receipt.validate, returnsNormally);
  });

  test('self-referential reply metadata fails closed', () {
    final inner = LoomInnerEnvelopeV2(
      messageId: 'message-0001',
      conversationRef: 'conversation-0001',
      senderAccountId: 'account-sender-0001',
      senderDeviceId: 'device-sender-0001',
      recipientAccountId: 'account-recipient-0001',
      recipientDeviceId: 'device-recipient-0001',
      contentKind: LoomInnerContentKindV2.text,
      contentPayload: Uint8List.fromList(<int>[1]),
      createdAt: DateTime.utc(2026, 9, 5, 12),
      replyToMessageId: 'message-0001',
    );

    expect(inner.validate, throwsFormatException);
  });
}
