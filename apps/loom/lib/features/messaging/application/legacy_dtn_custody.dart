import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';

/// Release-safe process-local counters for DTN custody persistence.
///
/// These diagnostics intentionally retain no message text/ciphertext, client or
/// device identifiers, addresses, keys, tokens, endpoints, SSIDs, or IPs.
abstract final class LoomLegacyDtnCustodyDiagnostics {
  static int persistCalls = 0;
  static int successfulCalls = 0;
  static int failedCalls = 0;
  static int newPackets = 0;
  static int reusedPackets = 0;
  static int lastPacketCount = 0;
  static String lastResult = 'none';
  static String? lastExceptionType;
  static DateTime? lastUpdatedAt;

  static void success({
    required int packetCount,
    required int created,
    required int reused,
  }) {
    successfulCalls++;
    newPackets += created;
    reusedPackets += reused;
    lastPacketCount = packetCount;
    lastResult = 'persisted';
    lastExceptionType = null;
    lastUpdatedAt = DateTime.now().toUtc();
  }

  static void failure(Object error) {
    failedCalls++;
    lastPacketCount = 0;
    lastResult = 'failed';
    lastExceptionType = error.runtimeType.toString();
    lastUpdatedAt = DateTime.now().toUtc();
  }
}

/// Persists already-production-E2EE direct messages into Architecture-v2 DTN
/// custody without enabling the experimental v2 session provider.
final class LoomLegacyDtnCustodyWriter {
  const LoomLegacyDtnCustodyWriter({this.codecFactory = _defaultCodec});

  static const Duration _packetGenerationSpan = Duration(days: 5);

  final LoomLegacyDtnCompatibilityCodec Function() codecFactory;

  static LoomLegacyDtnCompatibilityCodec _defaultCodec() =>
      LoomLegacyDtnCompatibilityCodec();

  Future<List<LoomStoredDtnPacket>> persist({
    required String applicationSupportPath,
    required String destinationNodeDomain,
    required String senderAddress,
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    required List<LoomDeviceKeyBundle> recipientDevices,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
    DateTime? now,
    DateTime? createdAt,
  }) async {
    LoomLegacyDtnCustodyDiagnostics.persistCalls++;
    try {
      if (recipientDevices.isEmpty) {
        throw StateError('No recipient device is available for DTN custody');
      }
      final current = (now ?? DateTime.now()).toUtc();
      final domain = LoomAddress.normalizeHomeNode(destinationNodeDomain);
      final expiry = _expiryBucket(current);
      final generation = _packetGeneration(current);
      final dtnPath = '$applicationSupportPath/loom-dtn-v2.sqlite3';
      final packetStore = LoomSqlitePacketStore.openFile(dtnPath);
      final routeStore = LoomSqlitePacketRouteStore.openExistingFile(dtnPath);
      final codec = codecFactory();
      final stored = <LoomStoredDtnPacket>[];
      var createdCount = 0;
      var reusedCount = 0;
      try {
        for (final recipient in recipientDevices) {
          final packetId = await codec.deterministicPacketId(
            clientId: clientId,
            recipientDeviceId: recipient.deviceId,
            packetGeneration: generation,
          );
          var existing = packetStore.read(packetId);

          // Five-day id generations overlap the six-day packet lifetime. Around
          // a generation boundary, keep reusing the previous exact packet while
          // it is still live. Once it really expires/cancels, the current
          // generation creates a fresh sealed packet and the pending message can
          // continue through arbitrarily long network disruption.
          if (existing == null && generation > 0) {
            final previousId = await codec.deterministicPacketId(
              clientId: clientId,
              recipientDeviceId: recipient.deviceId,
              packetGeneration: generation - 1,
            );
            final previous = packetStore.read(previousId);
            if (previous != null &&
                previous.expiresAt.isAfter(current) &&
                previous.state != LoomDtnPacketState.expired &&
                previous.state != LoomDtnPacketState.cancelledLocal) {
              existing = previous;
            }
          }

          if (existing != null) {
            routeStore.rememberDestinationRoute(
              packetId: existing.packetId,
              destinationNodeDomain: domain,
              now: current,
            );
            stored.add(existing);
            reusedCount++;
            continue;
          }

          final capsule = LoomLegacyDtnMessageCapsule(
            conversationId: conversationId,
            clientId: clientId,
            senderAddress: senderAddress,
            type: type,
            ciphertext: ciphertext,
            protocolVersion: protocolVersion,
            createdAt: (createdAt ?? current).toUtc(),
            replyToMessageId: replyToMessageId,
            metadata: metadata,
          );
          final sealed = await codec.seal(
            capsule: capsule,
            recipientDeviceId: recipient.deviceId,
            recipientAgreementPublicKey: recipient.agreementPublicKey,
            now: current,
            packetGeneration: generation,
          );
          if (sealed.packetId != packetId) {
            throw StateError('Legacy DTN packet id derivation is not stable');
          }
          final outer = LoomOuterEnvelopeV2(
            packetId: sealed.packetId,
            routingHint: LoomRoutingHintV2(
              scope: LoomRoutingScopeV2.globalRelay,
              mailboxToken: sealed.mailboxToken,
            ),
            expiresAtBucket: expiry,
            priority: LoomPriorityClassV2.normal,
            initialHopLimit: 6,
            forwardingState: const LoomForwardingStateV2(
              hopsUsed: 0,
              copiesRemaining: 4,
            ),
            encryptedPayload: sealed.encryptedPayload,
          );
          final wire = LoomEnvelopeV2Codec.encodeOuter(outer);
          final packet = packetStore.putLocalOutbound(
            operationId:
                'legacy-dtn:$clientId:${recipient.deviceId}:g$generation',
            messageId: clientId,
            packetId: sealed.packetId,
            exactOuterEnvelopeBytes: Uint8List.fromList(wire),
            now: current,
          );
          routeStore.rememberDestinationRoute(
            packetId: packet.packetId,
            destinationNodeDomain: domain,
            now: packet.storedAt,
          );
          stored.add(packet);
          createdCount++;
        }
        final result = List<LoomStoredDtnPacket>.unmodifiable(stored);
        LoomLegacyDtnCustodyDiagnostics.success(
          packetCount: result.length,
          created: createdCount,
          reused: reusedCount,
        );
        return result;
      } finally {
        routeStore.close();
        packetStore.close();
      }
    } catch (error) {
      LoomLegacyDtnCustodyDiagnostics.failure(error);
      rethrow;
    }
  }

  static int _packetGeneration(DateTime now) =>
      now.toUtc().millisecondsSinceEpoch ~/
      _packetGenerationSpan.inMilliseconds;

  static DateTime _expiryBucket(DateTime now) {
    final target = now.toUtc().add(const Duration(days: 6));
    final floor = DateTime.utc(
      target.year,
      target.month,
      target.day,
      target.hour,
    );
    return target == floor ? floor : floor.add(const Duration(hours: 1));
  }
}
