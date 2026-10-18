import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 12, 6);

  test(
    'uploads eligible packet only after destination Node verification',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'loom-destination-uplink-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final path = '${root.path}${Platform.pathSeparator}dtn.sqlite3';
      final packets = LoomSqlitePacketStore.openFile(path);
      final routes = LoomSqlitePacketRouteStore.openExistingFile(path);
      addTearDown(routes.close);
      addTearDown(packets.close);

      const packetId = 'packet-destination-uplink-0001';
      packets.putLocalOutbound(
        operationId: 'operation-destination-uplink-0001',
        messageId: 'message-destination-uplink-0001',
        packetId: packetId,
        exactOuterEnvelopeBytes: _wire(packetId, now, copies: 4),
        now: now,
      );
      routes.rememberDestinationRoute(
        packetId: packetId,
        destinationNodeDomain: 'recipient.example',
        now: now,
      );

      final poster = _RecordingPoster(now: now);
      final discovered = <String>[];
      final uplink = LoomDestinationNodeUplink(
        packetStore: packets,
        routeStore: routes,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: packets,
          transferStore: packets,
          clock: () => now.add(const Duration(seconds: 1)),
        ),
        signer: const _Signer(),
        poster: poster,
        discoverNode: (domain) async {
          discovered.add(domain);
          return _node('node:destination-verified-0001', domain);
        },
        clock: () => now.add(const Duration(seconds: 1)),
      );

      final result = await uplink.drain(maxPackets: 1);

      expect(discovered, <String>['recipient.example']);
      expect(result.attempted, 1);
      expect(result.accepted, 1);
      expect(result.failed, 0);
      expect(result.deferred, 0);
      expect(result.resumed, 0);
      expect(poster.calls, 1);
      expect(packets.read(packetId)!.state, LoomDtnPacketState.gatewayAccepted);
      expect(packets.listPreparedTransfers(), isEmpty);
    },
  );

  test(
    'verification failure defers without preparing or spending copies',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'loom-destination-verify-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final path = '${root.path}${Platform.pathSeparator}dtn.sqlite3';
      final packets = LoomSqlitePacketStore.openFile(path);
      final routes = LoomSqlitePacketRouteStore.openExistingFile(path);
      addTearDown(routes.close);
      addTearDown(packets.close);

      const packetId = 'packet-destination-verify-0001';
      packets.putLocalOutbound(
        operationId: 'operation-destination-verify-0001',
        messageId: 'message-destination-verify-0001',
        packetId: packetId,
        exactOuterEnvelopeBytes: _wire(packetId, now, copies: 4),
        now: now,
      );
      routes.rememberDestinationRoute(
        packetId: packetId,
        destinationNodeDomain: 'recipient.example',
        now: now,
      );

      final poster = _RecordingPoster(now: now);
      final uplink = LoomDestinationNodeUplink(
        packetStore: packets,
        routeStore: routes,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: packets,
          transferStore: packets,
          clock: () => now,
        ),
        signer: const _Signer(),
        poster: poster,
        discoverNode: (_) async => throw StateError('offline discovery'),
        clock: () => now,
      );

      final result = await uplink.drain(
        maxPackets: 1,
        retryDelay: const Duration(minutes: 3),
      );
      final packet = packets.read(packetId)!;

      expect(result.attempted, 0);
      expect(result.accepted, 0);
      expect(result.deferred, 1);
      expect(poster.calls, 0);
      expect(packet.copiesRemaining, 4);
      expect(packet.attemptCount, 1);
      expect(packet.lastErrorCode, 'destination-node-unverified');
      expect(packet.nextAttemptAt, now.add(const Duration(minutes: 3)));
      expect(packets.listPreparedTransfers(), isEmpty);
      expect(packets.listEligible(now), isEmpty);
      expect(
        packets.listNearbyCandidates(now).single.packetId,
        packetId,
        reason: 'Internet discovery backoff must not suspend the local bearer',
      );
    },
  );

  test(
    'resumes the exact prepared destination transfer after restart',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'loom-destination-resume-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final path = '${root.path}${Platform.pathSeparator}dtn.sqlite3';
      const packetId = 'packet-destination-resume-0001';
      const transmissionId = 'transmission-destination-resume-0001';
      const nodeId = 'node:destination-resume-0001';

      var packets = LoomSqlitePacketStore.openFile(path);
      var routes = LoomSqlitePacketRouteStore.openExistingFile(path);
      packets.putLocalOutbound(
        operationId: 'operation-destination-resume-0001',
        messageId: 'message-destination-resume-0001',
        packetId: packetId,
        exactOuterEnvelopeBytes: _wire(packetId, now, copies: 1),
        now: now,
      );
      routes.rememberDestinationRoute(
        packetId: packetId,
        destinationNodeDomain: 'recipient.example',
        now: now,
      );
      final prepared = LoomDtnTransferExecutor(
        packetStore: packets,
        transferStore: packets,
        clock: () => now,
      ).prepareNext(
        packetId: packetId,
        opportunities: <LoomDtnOpportunity>[_destination(nodeId)],
        transmissionId: transmissionId,
        now: now,
      );
      expect(prepared, isNotNull);
      routes.close();
      packets.close();

      packets = LoomSqlitePacketStore.openFile(path);
      routes = LoomSqlitePacketRouteStore.openExistingFile(path);
      addTearDown(routes.close);
      addTearDown(packets.close);
      final poster = _RecordingPoster(now: now);
      final uplink = LoomDestinationNodeUplink(
        packetStore: packets,
        routeStore: routes,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: packets,
          transferStore: packets,
          clock: () => now.add(const Duration(seconds: 2)),
        ),
        signer: const _Signer(),
        poster: poster,
        discoverNode: (domain) async => _node(nodeId, domain),
        clock: () => now.add(const Duration(seconds: 2)),
      );

      final result = await uplink.drain(maxPackets: 1);
      final transfer = packets.readTransfer(transmissionId)!;

      expect(result.resumed, 1);
      expect(result.attempted, 1);
      expect(result.accepted, 1);
      expect(poster.calls, 1);
      expect(transfer.state, LoomDtnTransferState.accepted);
      expect(packets.read(packetId)!.state, LoomDtnPacketState.gatewayAccepted);
      expect(packets.listPreparedTransfers(), isEmpty);
    },
  );

  test(
    'prepared transfer fails closed when verified Node identity changes',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'loom-destination-rotate-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final path = '${root.path}${Platform.pathSeparator}dtn.sqlite3';
      final packets = LoomSqlitePacketStore.openFile(path);
      final routes = LoomSqlitePacketRouteStore.openExistingFile(path);
      addTearDown(routes.close);
      addTearDown(packets.close);

      const packetId = 'packet-destination-rotate-0001';
      const transmissionId = 'transmission-destination-rotate-0001';
      packets.putLocalOutbound(
        operationId: 'operation-destination-rotate-0001',
        messageId: 'message-destination-rotate-0001',
        packetId: packetId,
        exactOuterEnvelopeBytes: _wire(packetId, now, copies: 2),
        now: now,
      );
      routes.rememberDestinationRoute(
        packetId: packetId,
        destinationNodeDomain: 'recipient.example',
        now: now,
      );
      LoomDtnTransferExecutor(
        packetStore: packets,
        transferStore: packets,
        clock: () => now,
      ).prepareNext(
        packetId: packetId,
        opportunities: <LoomDtnOpportunity>[
          _destination('node:destination-old-0001'),
        ],
        transmissionId: transmissionId,
        now: now,
      );

      final poster = _RecordingPoster(now: now);
      final uplink = LoomDestinationNodeUplink(
        packetStore: packets,
        routeStore: routes,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: packets,
          transferStore: packets,
          clock: () => now.add(const Duration(seconds: 1)),
        ),
        signer: const _Signer(),
        poster: poster,
        discoverNode: (domain) async =>
            _node('node:destination-new-0001', domain),
        clock: () => now.add(const Duration(seconds: 1)),
      );

      final result = await uplink.drain(maxPackets: 1);
      final packet = packets.read(packetId)!;
      final transfer = packets.readTransfer(transmissionId)!;

      expect(result.resumed, 1);
      expect(result.failed, 1);
      expect(poster.calls, 0);
      expect(packet.copiesRemaining, 2);
      expect(packet.lastErrorCode, 'destination-node-identity-changed');
      expect(transfer.state, LoomDtnTransferState.failed);
      expect(transfer.errorCode, 'destination-node-identity-changed');
    },
  );
}

LoomWellKnownNode _node(String nodeId, String domain) => LoomWellKnownNode(
      protocol: 'loom-federation-v1',
      endpoint: Uri.parse('https://$domain'),
      nodeId: nodeId,
      publicKey: 'public-key',
      signature: 'signature',
      fingerprint: 'fingerprint',
    );

LoomDtnOpportunity _destination(String nodeId) => LoomDtnOpportunity(
      opportunityId: 'destination-node:$nodeId',
      authenticated: true,
      destinationNode: true,
      directRecipient: false,
      gatewayClaim: LoomGatewayClaimState.none,
      supportedRelayScopes: const <LoomRoutingScopeV2>{},
      canStoreCarry: false,
      linkQualityPercent: 100,
      congestionPercent: 0,
      batteryConstrained: false,
      recentSuccessfulTransfers: 0,
      recentFailedTransfers: 0,
    );

Uint8List _wire(String packetId, DateTime now, {required int copies}) =>
    LoomEnvelopeV2Codec.encodeOuter(
      LoomOuterEnvelopeV2(
        packetId: packetId,
        routingHint: LoomRoutingHintV2(
          scope: LoomRoutingScopeV2.globalRelay,
          mailboxToken: Uint8List.fromList(List<int>.filled(32, 23)),
        ),
        expiresAtBucket: now.add(const Duration(days: 1)),
        priority: LoomPriorityClassV2.normal,
        initialHopLimit: 4,
        forwardingState: LoomForwardingStateV2(
          hopsUsed: 0,
          copiesRemaining: copies,
        ),
        encryptedPayload: Uint8List.fromList(<int>[7, 8, 9]),
      ),
    );

final class _Signer implements LoomDirectTransportSigner {
  const _Signer();

  @override
  Future<Uint8List> ed25519PublicKey() async =>
      Uint8List.fromList(List<int>.filled(32, 41));

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async =>
      Uint8List.fromList(List<int>.filled(64, 42));
}

final class _RecordingPoster implements LoomDirectHttpPoster {
  _RecordingPoster({required this.now});

  final DateTime now;
  int calls = 0;

  @override
  Future<LoomDirectHttpResponse> postJson(
    Uri uri,
    Map<String, Object?> body,
  ) async {
    calls += 1;
    return LoomDirectHttpResponse(
      statusCode: 202,
      body: <String, Object?>{
        'accepted': true,
        'packetId': body['packetId'],
        'acceptedAt': now.add(const Duration(seconds: 1)).toIso8601String(),
        'idempotent': false,
      },
    );
  }
}
