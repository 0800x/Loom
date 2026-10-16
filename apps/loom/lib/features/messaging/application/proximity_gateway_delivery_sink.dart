import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';

/// Commits current-product (v1 sync event) traffic delivered through an
/// Internet-to-Nearby gateway directly into the same encrypted local message
/// store used by normal Home-Node sync.
///
/// This class intentionally requires no access token and no live Home-Node
/// connection. It is safe for a fully offline recipient because the server-side
/// event contains only the already-encrypted Loom message envelope.
final class LoomProximityGatewayDeliverySink {
  LoomProximityGatewayDeliverySink({required this.store});

  final LoomMessagingStore store;

  bool acceptLegacy(LoomLegacyGatewayDelivery delivery) {
    if (delivery.event.kind != 'message.created') return false;
    final payload = delivery.event.payload;
    final id = payload['id'];
    final clientId = payload['clientId'];
    final conversationId = payload['conversationId'];
    final senderAddress = payload['senderAddress'];
    final ciphertext = payload['ciphertext'];
    final protocolVersion = payload['protocolVersion'];
    final createdAtRaw = payload['createdAt'];
    final typeRaw = payload['type'];
    if (id is! String ||
        clientId is! String ||
        conversationId is! String ||
        senderAddress is! String ||
        ciphertext is! String ||
        protocolVersion is! String ||
        createdAtRaw is! String ||
        typeRaw is! String) {
      return false;
    }
    if (conversationId != delivery.conversation.id) return false;
    final createdAt = DateTime.tryParse(createdAtRaw)?.toUtc();
    if (createdAt == null) return false;
    LoomMessageType type;
    try {
      type = LoomMessageType.values.byName(typeRaw.toLowerCase());
    } catch (_) {
      return false;
    }

    // Idempotent replay semantics mirror normal sync. A duplicate event means
    // the exact logical delivery is already durable locally, so the Nearby
    // gateway may safely receive an acceptance ACK.
    if (!store.markEventSeen(delivery.event.eventId)) return true;
    try {
      store.upsertConversation(delivery.conversation);
      final metadata = payload['metadata'];
      store.putMessage(
        LoomMessageRecord(
          id: id,
          clientId: clientId,
          conversationId: conversationId,
          senderAddress: senderAddress,
          type: type,
          ciphertext: ciphertext,
          protocolVersion: protocolVersion,
          createdOrder: payload['serverOrder'] is int
              ? payload['serverOrder'] as int
              : delivery.event.order,
          createdAt: createdAt,
          deliveryState: LoomDeliveryState.delivered,
          replyToMessageId: payload['replyToMessageId'] as String?,
          metadata: <String, Object?>{
            if (metadata is Map<String, Object?>) ...metadata,
            'receivedVia': 'internet-nearby-gateway-v1',
          },
        ),
      );
      return true;
    } catch (_) {
      store.forgetSeenEvent(delivery.event.eventId);
      return false;
    }
  }
}
