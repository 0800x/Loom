import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';

/// Binds decrypted InnerEnvelope sender identity to the authenticated session
/// context that produced the plaintext.
abstract interface class LoomInboundMessageTrustGate {
  bool isVerifiedRemoteSender({
    required String sessionContextId,
    required String senderAccountId,
    required String senderDeviceId,
  });
}

enum LoomInboundLogicalMessageDisposition { firstDelivery, duplicate }

final class LoomInboundLogicalMessageResult {
  const LoomInboundLogicalMessageResult({
    required this.disposition,
    required this.messageId,
  });

  final LoomInboundLogicalMessageDisposition disposition;
  final String messageId;

  bool get shouldDisplay =>
      disposition == LoomInboundLogicalMessageDisposition.firstDelivery;
}

/// Applies logical-message identity checks only after successful session decrypt.
///
/// PacketId duplicate suppression happens in DTN custody. This boundary is the
/// second level: two different PacketIds that decrypt to the same protected
/// MessageId are displayed only once. It stores no plaintext.
final class LoomV2InboundMessageDeduplicator {
  const LoomV2InboundMessageDeduplicator({
    required this.messageStateStore,
    required this.trustGate,
    required this.localAccountId,
    required this.localDeviceId,
  });

  final LoomV2MessageStateStore messageStateStore;
  final LoomInboundMessageTrustGate trustGate;
  final String localAccountId;
  final String localDeviceId;

  LoomInboundLogicalMessageResult recordDecrypted({
    required LoomInnerEnvelopeV2 envelope,
    required String sessionContextId,
    required DateTime observedAt,
    Duration retention = const Duration(days: 30),
  }) {
    envelope.validate();
    _validateId(sessionContextId, 'session context id', maxLength: 256);
    _validateId(localAccountId, 'local account id', maxLength: 256);
    _validateId(localDeviceId, 'local device id', maxLength: 256);

    if (envelope.recipientAccountId != localAccountId ||
        envelope.recipientDeviceId != localDeviceId) {
      throw const LoomSeenMessageConflict(
        'Decrypted inner envelope is addressed to another local endpoint',
      );
    }
    if (!trustGate.isVerifiedRemoteSender(
      sessionContextId: sessionContextId,
      senderAccountId: envelope.senderAccountId,
      senderDeviceId: envelope.senderDeviceId,
    )) {
      throw StateError(
        'Inner envelope sender is not verified by authenticated session context',
      );
    }

    final first = messageStateStore.markMessageSeen(
      messageId: envelope.messageId,
      senderAccountId: envelope.senderAccountId,
      senderDeviceId: envelope.senderDeviceId,
      now: observedAt,
      retention: retention,
    );
    return LoomInboundLogicalMessageResult(
      disposition: first
          ? LoomInboundLogicalMessageDisposition.firstDelivery
          : LoomInboundLogicalMessageDisposition.duplicate,
      messageId: envelope.messageId,
    );
  }

  static void _validateId(String value, String label, {int maxLength = 128}) {
    if (value.trim() != value ||
        value.length < 8 ||
        value.length > maxLength ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw FormatException('Invalid $label');
    }
  }
}
