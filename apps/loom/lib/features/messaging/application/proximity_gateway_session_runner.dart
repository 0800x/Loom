import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:path_provider/path_provider.dart';

import 'authorized_device_direct_transport_signer.dart';
import 'proximity_gateway_delivery_sink.dart';

const _nearbyPacketKind = 'proximity.gateway.packet.v1';
const _nearbyPacketAckKind = 'proximity.gateway.packet-ack.v1';
const _nearbyLegacyKind = 'proximity.gateway.legacy-event.v1';
const _nearbyLegacyAckKind = 'proximity.gateway.legacy-event-ack.v1';

String _base64UrlNoPadding(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

final class LoomProximityGatewayRunResult {
  const LoomProximityGatewayRunResult({
    required this.offered,
    required this.delivered,
    required this.custodyAcknowledged,
  });

  final int offered;
  final int delivered;
  final int custodyAcknowledged;
}

final class LoomProximityGatewaySessionRunner {
  LoomProximityGatewaySessionRunner({
    this.bootstrap = const LoomProximityGatewayBootstrap(),
    this.exchange = const LoomNearbyProximityGatewayExchange(),
  });

  final LoomProximityGatewayBootstrap bootstrap;
  final LoomNearbyProximityGatewayExchange exchange;

  Future<LoomProximityGatewayRunResult> runGateway({
    required LoomNearbyLink link,
    required LoomAuthorizedDeviceDirectTransportSigner gatewaySigner,
  }) async {
    LoomGatewayEstablishedSession? session;
    try {
      session = await bootstrap.establishAsGateway(
        link: link,
        gatewaySigner: gatewaySigner,
      );
      final claim = await session.client.claim(lease: session.lease);
      final acceptedIds = <String>[];

      // Current product traffic is represented as encrypted v1 sync events.
      // Deliver these first so existing production messaging receives the
      // lowest-latency path even when v2 custody packets are also pending.
      for (final delivery in claim.legacyDeliveries) {
        final accepted = await exchange.sendLegacyAndAwaitRecipientAck(
          session.connection,
          delivery,
        );
        if (accepted) acceptedIds.add(delivery.deliveryId);
      }

      // Architecture-v2 packets used to be claimed from the destination Node
      // and then silently ignored here. Advance exactly one DTN hop before the
      // Nearby transfer and require the offline recipient to durably commit the
      // packet before returning the hop-local ACK.
      for (final packet in claim.packets) {
        final forwarded = _advanceForNearbyHop(packet);
        final accepted = await exchange.sendPacketAndAwaitRecipientAck(
          session.connection,
          forwarded,
        );
        if (accepted) acceptedIds.add(packet.packetId);
      }

      if (acceptedIds.isNotEmpty) {
        await session.client.acknowledgeCustody(
          lease: session.lease,
          deliveryIds: acceptedIds,
        );
      }
      return LoomProximityGatewayRunResult(
        offered: claim.legacyDeliveries.length + claim.packets.length,
        delivered: acceptedIds.length,
        custodyAcknowledged: acceptedIds.length,
      );
    } finally {
      await session?.connection.close();
      if (session == null) {
        try {
          await link.close();
        } catch (_) {}
      }
    }
  }

  Future<int> runRecipient({
    required LoomNearbyLink link,
    required LoomAuthorizedDeviceDirectTransportSigner recipientSigner,
    required String recipientIdentityId,
    required String recipientDeviceId,
    required String recipientNodeId,
    required String recipientNodeDomain,
    required LoomProximityGatewayBearer bearer,
    Duration idleTimeout = const Duration(seconds: 20),
  }) async {
    LoomRecipientGatewaySession? session;
    final support = await getApplicationSupportDirectory();
    final messageStore = LoomMessagingStore.openFile(
      '${support.path}/loom-messages-v1.sqlite3',
    );
    final dtnPath = '${support.path}/loom-dtn-v2.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(dtnPath);
    final replicaIntake = LoomSqliteReplicaIntakeStore.openExistingFile(
      dtnPath,
    );
    final sink = LoomProximityGatewayDeliverySink(store: messageStore);
    var delivered = 0;
    try {
      session = await bootstrap.establishAsRecipient(
        link: link,
        recipientSigner: recipientSigner,
        recipientIdentityId: recipientIdentityId,
        recipientDeviceId: recipientDeviceId,
        recipientNodeId: recipientNodeId,
        recipientNodeDomain: recipientNodeDomain,
        bearer: bearer,
      );
      for (var index = 0; index < session.lease.maxPackets; index++) {
        try {
          final accepted = await _receiveOneAndAcknowledge(
            session.connection,
            sink: sink,
            replicaIntake: replicaIntake,
            timeout: idleTimeout,
          );
          if (accepted) delivered++;
        } on TimeoutException {
          break;
        } on FormatException {
          break;
        } catch (_) {
          // The gateway closes the bounded lease link after its final delivery.
          // Original server custody remains authoritative, so link shutdown is
          // a normal session terminator rather than evidence of message loss.
          break;
        }
      }
      return delivered;
    } finally {
      replicaIntake.close();
      packetStore.close();
      messageStore.close();
      await session?.connection.close();
      if (session == null) {
        try {
          await link.close();
        } catch (_) {}
      }
    }
  }

  LoomGatewayClaimPacket _advanceForNearbyHop(LoomGatewayClaimPacket packet) {
    final exact = Uint8List.fromList(
      base64Url.decode(base64Url.normalize(packet.envelopeBase64)),
    );
    final outer = LoomEnvelopeV2Codec.decodeOuter(exact);
    outer.validate();
    if (outer.packetId != packet.packetId) {
      throw const FormatException('Gateway packet id does not match envelope');
    }
    if (_base64UrlNoPadding(outer.routingHint.mailboxToken) !=
        packet.mailboxToken) {
      throw const FormatException(
        'Gateway packet mailbox does not match envelope',
      );
    }
    if (outer.forwardingState.hopsUsed >= outer.initialHopLimit) {
      throw const FormatException('Gateway packet exhausted its DTN hop limit');
    }

    final forwarded = LoomOuterEnvelopeV2(
      packetId: outer.packetId,
      routingHint: outer.routingHint,
      expiresAtBucket: outer.expiresAtBucket,
      priority: outer.priority,
      initialHopLimit: outer.initialHopLimit,
      forwardingState: LoomForwardingStateV2(
        hopsUsed: outer.forwardingState.hopsUsed + 1,
        copiesRemaining: outer.forwardingState.copiesRemaining,
      ),
      encryptedPayload: outer.encryptedPayload,
    );
    final wire = LoomEnvelopeV2Codec.encodeOuter(forwarded);
    return LoomGatewayClaimPacket(
      packetId: packet.packetId,
      mailboxToken: packet.mailboxToken,
      envelopeBase64: _base64UrlNoPadding(wire),
      expiresAt: packet.expiresAt,
      priority: packet.priority,
      acceptedAt: packet.acceptedAt,
    );
  }

  Future<bool> _receiveOneAndAcknowledge(
    LoomNearbySecureConnection connection, {
    required LoomProximityGatewayDeliverySink sink,
    required LoomSqliteReplicaIntakeStore replicaIntake,
    required Duration timeout,
  }) async {
    final body = exchange.codec.decode(
      await connection.receive(timeout: timeout),
    );
    final kind = body['kind'];

    if (kind == _nearbyLegacyKind) {
      final raw = body['delivery'];
      if (raw is! Map) {
        throw const FormatException('Invalid Nearby legacy gateway frame');
      }
      final delivery = LoomLegacyGatewayDelivery.fromJson(
        raw.map((key, value) => MapEntry(key.toString(), value as Object?)),
      );
      final accepted = sink.acceptLegacy(delivery);
      await connection.send(
        exchange.codec.encode(<String, Object?>{
          'kind': _nearbyLegacyAckKind,
          'deliveryId': delivery.deliveryId,
          'accepted': accepted,
        }),
      );
      return accepted;
    }

    if (kind == _nearbyPacketKind) {
      final raw = body['packet'];
      if (raw is! Map) {
        throw const FormatException('Invalid Nearby gateway packet frame');
      }
      final packet = LoomGatewayClaimPacket.fromJson(
        raw.map((key, value) => MapEntry(key.toString(), value as Object?)),
      );
      var accepted = false;
      try {
        final exact = Uint8List.fromList(
          base64Url.decode(base64Url.normalize(packet.envelopeBase64)),
        );
        final result = replicaIntake.acceptReplica(
          exactOuterEnvelopeBytes: exact,
          now: DateTime.now().toUtc(),
        );
        accepted =
            result.packetId == packet.packetId &&
            result.shouldAcknowledgeTransfer;
      } catch (_) {
        accepted = false;
      }
      await connection.send(
        exchange.codec.encode(<String, Object?>{
          'kind': _nearbyPacketAckKind,
          'packetId': packet.packetId,
          'accepted': accepted,
        }),
      );
      return accepted;
    }

    throw const FormatException('Unknown proximity gateway Nearby frame');
  }
}
