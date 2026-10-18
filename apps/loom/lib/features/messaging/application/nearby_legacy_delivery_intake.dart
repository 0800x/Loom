import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';

/// Durable intake boundary for Internet-to-Nearby legacy production messages.
///
/// The gateway receives only the existing opaque E2EE event. The recipient
/// acknowledges the Nearby hop only after the exact event is committed to the
/// same durable messaging database used by the normal sync path.
final class LoomNearbyLegacyDeliveryIntake {
  const LoomNearbyLegacyDeliveryIntake._();

  static Future<bool> acceptOnce({
    required String applicationSupportPath,
    required String ownAddress,
    required LoomLegacyGatewayDelivery delivery,
  }) async {
    final event = delivery.event;
    if (event.kind != 'message.created') return false;
    final store = LoomMessagingStore.openFile(
      '$applicationSupportPath/loom-messages-v1.sqlite3',
    );
    try {
      store.applyEventOnce(event.eventId, () {
        store.upsertConversation(delivery.conversation);
        store.putMessage(
          _messageFromPayload(
            event.payload,
            fallbackOrder: event.order,
            ownAddress: ownAddress,
          ),
        );
      });
      return true;
    } catch (_) {
      return false;
    } finally {
      store.close();
    }
  }

  static LoomMessageRecord _messageFromPayload(
    Map<String, Object?> payload, {
    required int fallbackOrder,
    required String ownAddress,
  }) {
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
      throw const FormatException('Malformed Nearby message event');
    }
    final createdAt = DateTime.tryParse(createdAtRaw)?.toUtc();
    if (createdAt == null) {
      throw const FormatException('Malformed Nearby message timestamp');
    }
    final order = payload['serverOrder'] is int
        ? payload['serverOrder'] as int
        : fallbackOrder;
    final metadata = payload['metadata'];
    return LoomMessageRecord(
      id: id,
      clientId: clientId,
      conversationId: conversationId,
      senderAddress: senderAddress,
      type: LoomMessageType.values.byName(typeRaw.toLowerCase()),
      ciphertext: ciphertext,
      protocolVersion: protocolVersion,
      createdOrder: order,
      createdAt: createdAt,
      deliveryState: senderAddress.toLowerCase() == ownAddress.toLowerCase()
          ? LoomDeliveryState.sent
          : LoomDeliveryState.delivered,
      transportPath: LoomMessageTransportPath.nearby,
      replyToMessageId: payload['replyToMessageId'] as String?,
      metadata: metadata is Map<String, Object?> ? metadata : const {},
    );
  }
}
