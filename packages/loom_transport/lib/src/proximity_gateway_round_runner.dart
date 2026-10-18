import 'dart:async';
import 'dart:math';

import 'direct_node_delivery.dart';
import 'nearby_transport.dart';
import 'proximity_delivery_receipt.dart';
import 'proximity_gateway.dart';
import 'proximity_gateway_bootstrap.dart';

const _proximityRendezvousPrefix = 'pg1-';
const _proximityBatchKind = 'proximity.gateway.batch.v1';

final class LoomProximityGatewayRoundResult {
  const LoomProximityGatewayRoundResult({
    required this.discoveredCandidates,
    required this.connectedCandidates,
    required this.legacyDeliveriesOffered,
    required this.legacyDeliveriesAccepted,
    required this.inboundSessions,
    required this.failedEncounters,
    this.v2PacketsOffered = 0,
    this.v2PacketsAccepted = 0,
  });

  final int discoveredCandidates;
  final int connectedCandidates;
  final int legacyDeliveriesOffered;
  final int legacyDeliveriesAccepted;
  final int v2PacketsOffered;
  final int v2PacketsAccepted;
  final int inboundSessions;
  final int failedEncounters;
}

typedef LoomProximityLegacyDeliveryAcceptor = Future<bool> Function(
  LoomLegacyGatewayDelivery delivery,
);
typedef LoomProximityV2PacketAcceptor = Future<bool> Function(
  LoomGatewayClaimPacket packet,
);

/// Runs one bounded recipient-authorized Internet-to-Nearby last-mile round.
///
/// Every device advertises only an ephemeral rendezvous id. A device that
/// connects to that advertisement acts as an untrusted Internet gateway. The
/// advertising recipient signs a short-lived lease binding its device, Home
/// Node, the gateway device key and both ephemeral X25519 keys. The gateway
/// independently verifies the Node before registering that lease and claiming
/// pending opaque traffic.
///
/// Legacy production messages are custody-acknowledged to the Node only after
/// the recipient callback has durably accepted the exact message event and the
/// recipient device has signed a delivery receipt bound to the lease. Generic
/// v2 packets are also carried over the encrypted Nearby session and gateway
/// custody is recorded only after the recipient callback durably accepts them.
final class LoomProximityGatewayRoundRunner {
  LoomProximityGatewayRoundRunner({
    LoomProximityGatewayBootstrap? bootstrap,
    LoomProximityDeliveryReceiptExchange? receiptExchange,
    LoomNearbyProximityGatewayExchange? packetExchange,
    DateTime Function()? clock,
    String Function()? rendezvousIdFactory,
  })  : bootstrap = bootstrap ?? const LoomProximityGatewayBootstrap(),
        receiptExchange =
            receiptExchange ?? const LoomProximityDeliveryReceiptExchange(),
        packetExchange =
            packetExchange ?? const LoomNearbyProximityGatewayExchange(),
        _clock = clock ?? DateTime.now,
        _rendezvousIdFactory = rendezvousIdFactory ?? _randomRendezvousId;

  final LoomProximityGatewayBootstrap bootstrap;
  final LoomProximityDeliveryReceiptExchange receiptExchange;
  final LoomNearbyProximityGatewayExchange packetExchange;
  final DateTime Function() _clock;
  final String Function() _rendezvousIdFactory;
  final LoomNearbyPacketCodec _codec = const LoomNearbyPacketCodec();

  Future<LoomProximityGatewayRoundResult> run({
    required LoomNearbyRadioAdapter radio,
    required LoomNearbyBearer bearer,
    required LoomDirectTransportSigner signer,
    required String recipientIdentityId,
    required String recipientDeviceId,
    required String recipientNodeId,
    required String recipientNodeDomain,
    required LoomProximityLegacyDeliveryAcceptor acceptLegacyDelivery,
    LoomProximityV2PacketAcceptor? acceptV2Packet,
    Duration scanTimeout = const Duration(seconds: 5),
    Duration advertisementLifetime = const Duration(seconds: 12),
    int maxCandidates = 4,
    int claimLimit = 20,
  }) async {
    if (!radio.supportedBearers.contains(bearer)) {
      throw StateError('Nearby radio does not support ${bearer.name}');
    }
    if (scanTimeout <= Duration.zero ||
        advertisementLifetime <= Duration.zero) {
      throw ArgumentError('Proximity gateway round durations must be positive');
    }
    if (maxCandidates < 1 || maxCandidates > 16) {
      throw ArgumentError.value(maxCandidates, 'maxCandidates');
    }
    if (claimLimit < 1 || claimLimit > 50) {
      throw ArgumentError.value(claimLimit, 'claimLimit');
    }

    final gatewayBearer = _gatewayBearer(bearer);
    final now = _clock().toUtc();
    final advertisement = LoomNearbyAdvertisement(
      protocolVersion: 1,
      rendezvousId: '$_proximityRendezvousPrefix${_rendezvousIdFactory()}',
      bearers: <LoomNearbyBearer>[bearer],
      expiresAt: now.add(advertisementLifetime),
    );
    final advertising = await radio.advertise(advertisement);
    final inboundTasks = <Future<int>>[];
    var failed = 0;
    final incomingSubscription = advertising.incomingLinks.listen((link) {
      final task = _serveRecipient(
        link: link,
        signer: signer,
        recipientIdentityId: recipientIdentityId,
        recipientDeviceId: recipientDeviceId,
        recipientNodeId: recipientNodeId,
        recipientNodeDomain: recipientNodeDomain,
        bearer: gatewayBearer,
        acceptLegacyDelivery: acceptLegacyDelivery,
        acceptV2Packet: acceptV2Packet,
      ).catchError((Object _) {
        failed++;
        return 0;
      });
      inboundTasks.add(task);
    });

    var discovered = 0;
    var connected = 0;
    var legacyOffered = 0;
    var legacyAccepted = 0;
    var packetsOffered = 0;
    var packetsAccepted = 0;
    final seenHandles = <String>{};
    try {
      await for (final candidate in radio.scan(timeout: scanTimeout)) {
        if (discovered >= maxCandidates) break;
        if (candidate.bearer != bearer ||
            candidate.advertisement.protocolVersion != 1 ||
            !candidate.advertisement.rendezvousId.startsWith(
              _proximityRendezvousPrefix,
            ) ||
            !candidate.advertisement.expiresAt.isAfter(_clock().toUtc()) ||
            !seenHandles.add(candidate.nativeHandle)) {
          continue;
        }
        discovered++;
        try {
          final link = await radio.connect(candidate);
          connected++;
          final result = await _actAsGateway(
            link: link,
            signer: signer,
            claimLimit: claimLimit,
          );
          packetsOffered += result.$1;
          packetsAccepted += result.$2;
          legacyOffered += result.$3;
          legacyAccepted += result.$4;
        } catch (_) {
          failed++;
        }
      }
    } finally {
      await advertising.close();
      await incomingSubscription.cancel();
    }

    var inboundSessions = 0;
    for (final task in List<Future<int>>.from(inboundTasks)) {
      try {
        inboundSessions += await task;
      } catch (_) {
        failed++;
      }
    }

    return LoomProximityGatewayRoundResult(
      discoveredCandidates: discovered,
      connectedCandidates: connected,
      legacyDeliveriesOffered: legacyOffered,
      legacyDeliveriesAccepted: legacyAccepted,
      v2PacketsOffered: packetsOffered,
      v2PacketsAccepted: packetsAccepted,
      inboundSessions: inboundSessions,
      failedEncounters: failed,
    );
  }

  Future<(int, int, int, int)> _actAsGateway({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    required int claimLimit,
  }) async {
    LoomGatewayEstablishedSession? session;
    try {
      session = await bootstrap.establishAsGateway(
        link: link,
        gatewaySigner: signer,
      );
      final claim = await session.client.claim(
        lease: session.lease,
        limit: claimLimit,
      );
      final packets = claim.packets;
      final legacy = claim.legacyDeliveries;
      await session.connection.send(
        _codec.encode(<String, Object?>{
          'kind': _proximityBatchKind,
          'packetCount': packets.length,
          'legacyCount': legacy.length,
        }),
      );

      final acceptedPacketIds = <String>[];
      for (final packet in packets) {
        if (await packetExchange.sendPacketAndAwaitRecipientAck(
          session.connection,
          packet,
        )) {
          acceptedPacketIds.add(packet.packetId);
        }
      }
      if (acceptedPacketIds.isNotEmpty) {
        await session.client.acknowledgeCustody(
          lease: session.lease,
          deliveryIds: acceptedPacketIds,
        );
      }

      final receipts = <LoomRecipientDeliveryReceipt>[];
      for (final delivery in legacy) {
        final receipt = await receiptExchange.sendLegacyAndAwaitReceipt(
          session.connection,
          delivery,
        );
        if (receipt != null) receipts.add(receipt);
      }
      if (receipts.isNotEmpty) {
        await session.client.acknowledgeRecipientReceipts(
          lease: session.lease,
          receipts: receipts,
        );
      }
      return (
        packets.length,
        acceptedPacketIds.length,
        legacy.length,
        receipts.length,
      );
    } finally {
      if (session != null) {
        await session.connection.close();
      } else {
        await link.close();
      }
    }
  }

  Future<int> _serveRecipient({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    required String recipientIdentityId,
    required String recipientDeviceId,
    required String recipientNodeId,
    required String recipientNodeDomain,
    required LoomProximityGatewayBearer bearer,
    required LoomProximityLegacyDeliveryAcceptor acceptLegacyDelivery,
    required LoomProximityV2PacketAcceptor? acceptV2Packet,
  }) async {
    LoomRecipientGatewaySession? session;
    try {
      session = await bootstrap.establishAsRecipient(
        link: link,
        recipientSigner: signer,
        recipientIdentityId: recipientIdentityId,
        recipientDeviceId: recipientDeviceId,
        recipientNodeId: recipientNodeId,
        recipientNodeDomain: recipientNodeDomain,
        bearer: bearer,
      );
      final manifest = _codec.decode(
        await session.connection.receive(timeout: const Duration(seconds: 20)),
      );
      final packetCount = manifest['packetCount'] ?? 0;
      final legacyCount = manifest['legacyCount'];
      if (manifest['kind'] != _proximityBatchKind ||
          packetCount is! int ||
          packetCount < 0 ||
          packetCount > 50 ||
          legacyCount is! int ||
          legacyCount < 0 ||
          legacyCount > 50 ||
          packetCount + legacyCount > 50) {
        throw const FormatException('Invalid proximity gateway batch manifest');
      }
      for (var index = 0; index < packetCount; index++) {
        await packetExchange.receivePacketAndAcknowledge(
          session.connection,
          accept: acceptV2Packet ?? (_) async => false,
        );
      }
      for (var index = 0; index < legacyCount; index++) {
        await receiptExchange.receiveLegacyAndSignReceipt(
          session.connection,
          lease: session.lease,
          recipientSigner: signer,
          accept: acceptLegacyDelivery,
        );
      }
      return 1;
    } finally {
      if (session != null) {
        await session.connection.close();
      } else {
        await link.close();
      }
    }
  }

  static LoomProximityGatewayBearer _gatewayBearer(LoomNearbyBearer bearer) =>
      switch (bearer) {
        LoomNearbyBearer.bluetoothLowEnergy => LoomProximityGatewayBearer.ble,
        LoomNearbyBearer.wifiDirect => LoomProximityGatewayBearer.wifiDirect,
        LoomNearbyBearer.wifiAware => LoomProximityGatewayBearer.wifiAware,
        _ => throw StateError(
            'Bearer ${bearer.name} is not supported by proximity gateway',
          ),
      };

  static String _randomRendezvousId() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final random = Random.secure();
    return List<String>.generate(
      28,
      (_) => alphabet[random.nextInt(alphabet.length)],
      growable: false,
    ).join();
  }
}
