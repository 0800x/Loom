import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 7, 8);

  test('delivery route prefers verified destination node over Home Node', () {
    const policy = LoomRoutePolicy();
    final result = policy.selectForDelivery(
      [
        LoomRouteCandidate(
          id: 'home',
          kind: LoomRouteKind.homeNode,
          nodeId: 'node-home-0001',
          endpoint: Uri.parse('https://home.example'),
          identityVerified: true,
          latency: const Duration(milliseconds: 10),
        ),
        LoomRouteCandidate(
          id: 'destination',
          kind: LoomRouteKind.destinationNode,
          nodeId: 'node-destination-0002',
          endpoint: Uri.parse('https://destination.example'),
          identityVerified: true,
          latency: const Duration(milliseconds: 80),
        ),
      ],
      homeNodeId: 'node-home-0001',
      destinationNodeId: 'node-destination-0002',
    );

    expect(result.ordered.map((item) => item.id), ['destination', 'home']);
  });

  test(
    'delivery route falls back to Home Node when destination is unreachable',
    () {
      const policy = LoomRoutePolicy();
      final result = policy.selectForDelivery(
        [
          LoomRouteCandidate(
            id: 'destination',
            kind: LoomRouteKind.destinationNode,
            nodeId: 'node-destination-0002',
            endpoint: Uri.parse('https://destination.example'),
            identityVerified: true,
            reachable: false,
          ),
          LoomRouteCandidate(
            id: 'home',
            kind: LoomRouteKind.homeNode,
            nodeId: 'node-home-0001',
            endpoint: Uri.parse('https://home.example'),
            identityVerified: true,
          ),
        ],
        homeNodeId: 'node-home-0001',
        destinationNodeId: 'node-destination-0002',
      );

      expect(result.ordered.single.id, 'home');
    },
  );

  test('direct target preserves an advertised base path', () {
    final target = LoomDirectNodeTarget(
      nodeId: 'node-destination-0002',
      endpoint: Uri.parse('https://destination.example/loom'),
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 1)),
      identityVerified: true,
    );
    expect(target.directIngressUri.path, '/loom/api/v2/packets/direct');
  });

  test(
    'direct sender signs exact packet and maps destination custody ACK',
    () async {
      final store = LoomSqlitePacketStore.openInMemory();
      try {
        final mailbox = Uint8List.fromList(List<int>.filled(32, 44));
        final outer = LoomOuterEnvelopeV2(
          packetId: 'packet-direct-node-0001',
          routingHint: LoomRoutingHintV2(
            scope: LoomRoutingScopeV2.globalRelay,
            mailboxToken: mailbox,
          ),
          expiresAtBucket: now.add(const Duration(days: 1)),
          priority: LoomPriorityClassV2.normal,
          initialHopLimit: 4,
          forwardingState: const LoomForwardingStateV2(
            hopsUsed: 0,
            copiesRemaining: 2,
          ),
          encryptedPayload: Uint8List.fromList(<int>[5, 6, 7, 8]),
        );
        final exact = LoomEnvelopeV2Codec.encodeOuter(outer);
        final packet = store.putLocalOutbound(
          operationId: 'operation-direct-node-0001',
          messageId: 'message-direct-node-0001',
          packetId: outer.packetId,
          exactOuterEnvelopeBytes: exact,
          now: now,
        );
        final transfer = store.prepareTransfer(
          transmissionId: 'transmission-direct-node-0001',
          plan: LoomDtnTransferPlan(
            packetId: packet.packetId,
            opportunityId: 'destination-node-opportunity',
            reason: LoomDtnTransferReason.destinationNode,
            score: 900,
            copiesBefore: packet.copiesRemaining,
            copiesGranted: 1,
            copiesRetainedAfterSuccess: 1,
            requiresSingleCopyCustodyHandoff: false,
          ),
          now: now,
        );

        final signer = _FakeSigner();
        final poster = _FakePoster(now);
        final sender = LoomDirectNodeTransferSender(
          packetStore: store,
          target: LoomDirectNodeTarget(
            nodeId: 'node-destination-0002',
            endpoint: Uri.parse('https://destination.example'),
            mailboxToken: mailbox,
            identityVerified: true,
          ),
          signer: signer,
          poster: poster,
          clock: () => now,
          nonceFactory: () => Uint8List.fromList(List<int>.filled(24, 9)),
        );

        final result = await sender.sendPrepared(transfer);
        expect(result, isA<LoomDtnSendAccepted>());
        final ack = (result as LoomDtnSendAccepted).ack;
        expect(ack.packetId, packet.packetId);
        expect(ack.transmissionId, transfer.transmissionId);
        expect(ack.recipientDeliveryConfirmed, isFalse);

        expect(poster.uri.path, '/api/v2/packets/direct');
        expect(poster.body['packetId'], packet.packetId);
        expect(poster.body['priority'], 'normal');
        final proof = poster.body['transportProof'] as Map<String, Object?>;
        expect(proof['devicePublicKey'], isNotEmpty);
        expect(proof['signature'], isNotEmpty);

        final signedFields =
            jsonDecode(utf8.decode(signer.lastCanonical!)) as List<dynamic>;
        expect(signedFields[0], 'loom-direct-node-v1');
        expect(signedFields[4], packet.packetId);
        expect(signedFields[5], poster.body['mailboxToken']);
        expect(signedFields[6], poster.body['envelopeBase64']);
      } finally {
        store.close();
      }
    },
  );
}

final class _FakeSigner implements LoomDirectTransportSigner {
  Uint8List? lastCanonical;

  @override
  Future<Uint8List> ed25519PublicKey() async =>
      Uint8List.fromList(List<int>.generate(32, (index) => index + 1));

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async {
    lastCanonical = Uint8List.fromList(canonicalBytes);
    return Uint8List.fromList(List<int>.filled(64, 7));
  }
}

final class _FakePoster implements LoomDirectHttpPoster {
  _FakePoster(this.now);

  final DateTime now;
  late Uri uri;
  late Map<String, Object?> body;

  @override
  Future<LoomDirectHttpResponse> postJson(
    Uri uri,
    Map<String, Object?> body,
  ) async {
    this.uri = uri;
    this.body = Map<String, Object?>.from(body);
    return LoomDirectHttpResponse(
      statusCode: 202,
      body: <String, Object?>{
        'accepted': true,
        'packetId': body['packetId'],
        'acceptedAt': now
            .add(const Duration(milliseconds: 20))
            .toIso8601String(),
        'idempotent': false,
      },
    );
  }
}
