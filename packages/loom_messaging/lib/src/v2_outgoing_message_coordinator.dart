import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_sessions/loom_sessions.dart';

final class LoomV2TextIntent {
  const LoomV2TextIntent({
    required this.sessionId,
    required this.operationId,
    required this.messageId,
    required this.packetId,
    required this.conversationRef,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.recipientAccountId,
    required this.recipientDeviceId,
    required this.plaintext,
    required this.createdAt,
    this.replyToMessageId,
    this.receiptPolicy = LoomReceiptPolicyV2.delivered,
  });

  final String sessionId;
  final String operationId;
  final String messageId;
  final String packetId;
  final String conversationRef;
  final String senderAccountId;
  final String senderDeviceId;
  final String recipientAccountId;
  final String recipientDeviceId;
  final String plaintext;
  final DateTime createdAt;
  final String? replyToMessageId;
  final LoomReceiptPolicyV2 receiptPolicy;

  Uint8List encodeInnerEnvelope() {
    if (plaintext.trim().isEmpty) {
      throw const FormatException('Message text must not be empty');
    }
    final payload = Uint8List.fromList(utf8.encode(plaintext));
    if (payload.length > 32 * 1024) {
      throw const FormatException('Message text exceeds v2 text limit');
    }
    final envelope = LoomInnerEnvelopeV2(
      messageId: messageId,
      conversationRef: conversationRef,
      senderAccountId: senderAccountId,
      senderDeviceId: senderDeviceId,
      recipientAccountId: recipientAccountId,
      recipientDeviceId: recipientDeviceId,
      contentKind: LoomInnerContentKindV2.text,
      contentPayload: payload,
      createdAt: createdAt,
      replyToMessageId: replyToMessageId,
      receiptPolicy: receiptPolicy,
    );
    return LoomEnvelopeV2Codec.encodeInner(envelope);
  }
}

/// Coordinates new v2 sends without exposing in-flight ciphertext to routing.
///
/// `encryptAndCommitText` returns only after [transactionRunner] has committed.
/// A provider result that was not actually staged in the same transaction is
/// rejected, so a buggy provider cannot accidentally bypass the crypto outbox.
final class LoomV2OutgoingMessageCoordinator {
  const LoomV2OutgoingMessageCoordinator({
    required this.transactionRunner,
    required this.sessionProvider,
  });

  final LoomCryptoTransactionRunner transactionRunner;
  final LoomSessionCryptoProvider sessionProvider;

  Future<LoomCryptoOutboxRecord> encryptAndCommitText(
    LoomV2TextIntent intent,
  ) async {
    final innerEnvelope = intent.encodeInnerEnvelope();

    return transactionRunner.runDurably((transaction) async {
      final existing = await transaction.readOutbox(intent.operationId);
      if (existing != null) {
        _verifyIntentIdentity(existing, intent);
        return existing;
      }

      final staged = await sessionProvider.encryptAndStage(
        transaction: transaction,
        sessionId: intent.sessionId,
        operationId: intent.operationId,
        messageId: intent.messageId,
        packetId: intent.packetId,
        innerEnvelope: innerEnvelope,
        now: intent.createdAt,
      );
      staged.validate();
      _verifyIntentIdentity(staged, intent);
      if (staged.ciphertext.protocolVersion !=
          sessionProvider.protocolVersion) {
        throw LoomCryptoStateConflict(
          'Provider returned ${staged.ciphertext.protocolVersion} ciphertext '
          'while advertising ${sessionProvider.protocolVersion}',
        );
      }

      final persisted = await transaction.readOutbox(intent.operationId);
      if (persisted == null || !_sameOutbox(staged, persisted)) {
        throw const LoomCryptoStateConflict(
          'Session provider returned ciphertext without staging the exact outbox row',
        );
      }
      return persisted;
    });
  }

  static void _verifyIntentIdentity(
    LoomCryptoOutboxRecord record,
    LoomV2TextIntent intent,
  ) {
    if (record.operationId != intent.operationId ||
        record.sessionId != intent.sessionId ||
        record.messageId != intent.messageId ||
        record.packetId != intent.packetId) {
      throw const LoomCryptoStateConflict(
        'Recovered crypto outbox row does not match the immutable message intent',
      );
    }
  }

  static bool _sameOutbox(
    LoomCryptoOutboxRecord left,
    LoomCryptoOutboxRecord right,
  ) {
    if (left.operationId != right.operationId ||
        left.sessionId != right.sessionId ||
        left.sessionRevision != right.sessionRevision ||
        left.messageId != right.messageId ||
        left.packetId != right.packetId ||
        left.createdAt.toUtc() != right.createdAt.toUtc() ||
        left.ciphertext.protocolVersion != right.ciphertext.protocolVersion ||
        left.ciphertext.sessionLocator != right.ciphertext.sessionLocator ||
        left.ciphertext.bytes.length != right.ciphertext.bytes.length) {
      return false;
    }
    for (var i = 0; i < left.ciphertext.bytes.length; i++) {
      if (left.ciphertext.bytes[i] != right.ciphertext.bytes[i]) return false;
    }
    return true;
  }
}
