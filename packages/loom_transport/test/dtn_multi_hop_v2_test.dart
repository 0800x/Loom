import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test('A -> B, disconnect, B -> C preserves durable DTN custody', () async {
    final root = Directory.systemTemp.createTempSync('loom-dtn-multihop-');
    addTearDown(() => root.deleteSync(recursive: true));

    final aPath = '${root.path}${Platform.pathSeparator}a.sqlite3';
    final bPath = '${root.path}${Platform.pathSeparator}b.sqlite3';
    final cPath = '${root.path}${Platform.pathSeparator}c.sqlite3';

    final a = LoomSqlitePacketStore.openFile(aPath);
    final b = LoomSqlitePacketStore.openFile(bPath);
    final c = LoomSqlitePacketStore.openFile(cPath);
    final bIntake = LoomSqliteReplicaIntakeStore.openExistingFile(bPath);
    final cIntake = LoomSqliteReplicaIntakeStore.openExistingFile(cPath);
    addTearDown(a.close);
    addTearDown(b.close);
    addTearDown(c.close);
    addTearDown(bIntake.close);
    addTearDown(cIntake.close);

    const packetId = 'packet-multihop-000001';
    final sourceWire = _sourcePacket(packetId);
    a.putLocalOutbound(
      operationId: 'operation-multihop-0001',
      messageId: 'message-multihop-0001',
      packetId: packetId,
      exactOuterEnvelopeBytes: sourceWire,
      now: now,
    );

    final aExecutor = LoomDtnTransferExecutor(
      packetStore: a,
      transferStore: a,
      clock: () => now.add(const Duration(seconds: 2)),
    );
    final aToB = aExecutor.prepareNext(
      packetId: packetId,
      opportunities: <LoomDtnOpportunity>[_carrier('peer-b')],
      transmissionId: 'transmission-a-b-0001',
      now: now,
    );
    expect(aToB, isNotNull);
    expect(aToB!.copiesBefore, 4);
    expect(aToB.copiesGranted, 2);

    final firstPair = _DuplexNearbyPair();
    final aConnection = _connection(firstPair.left);
    final bConnection = _connection(firstPair.right);
    final bReceiver = LoomNearbyDtnTransferReceiver(
      connection: bConnection,
      durablyAccept:
          ({required transmissionId, required exactOuterEnvelopeBytes}) {
            final acceptedAt = now.add(const Duration(seconds: 1));
            final result = bIntake.acceptReplica(
              exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
              now: acceptedAt,
            );
            return LoomDtnHopAck(
              transmissionId: transmissionId,
              packetId: result.packetId,
              acceptedAt: acceptedAt,
              duplicate:
                  result.disposition == LoomReplicaIntakeDisposition.duplicate,
            );
          },
    );

    final receiveOnB = bReceiver.receiveAndAcknowledge();
    final firstResult = await aExecutor.executePrepared(
      transmissionId: aToB.transmissionId,
      sender: LoomNearbyDtnTransferSender(
        connection: aConnection,
        clock: () => now.add(const Duration(seconds: 2)),
      ),
    );
    final firstAck = await receiveOnB;

    expect(firstResult.status, LoomDtnExecutionStatus.accepted);
    expect(firstAck.packetId, packetId);
    expect(firstAck.recipientDeliveryConfirmed, isFalse);
    expect(a.read(packetId)!.copiesRemaining, 2);

    final carriedByB = b.read(packetId);
    expect(carriedByB, isNotNull);
    expect(carriedByB!.origin, LoomDtnPacketOrigin.carriedReplica);
    expect(carriedByB.hopsUsed, 1);
    expect(carriedByB.copiesRemaining, 2);
    expect(carriedByB.recipientConfirmedAt, isNull);

    // Simulate a real disconnected interval. The A<->B links disappear and B's
    // durable SQLite custody is closed/reopened before any path to C exists.
    await aConnection.close();
    await bConnection.close();
    bIntake.close();
    b.close();

    final reopenedB = LoomSqlitePacketStore.openFile(bPath);
    final reopenedBIntake = LoomSqliteReplicaIntakeStore.openExistingFile(
      bPath,
    );
    addTearDown(reopenedB.close);
    addTearDown(reopenedBIntake.close);
    final recovered = reopenedB.read(packetId);
    expect(recovered, isNotNull);
    expect(recovered!.hopsUsed, 1);
    expect(recovered.copiesRemaining, 2);

    final bExecutor = LoomDtnTransferExecutor(
      packetStore: reopenedB,
      transferStore: reopenedB,
      clock: () => now.add(const Duration(hours: 2, seconds: 2)),
    );
    final bToC = bExecutor.prepareNext(
      packetId: packetId,
      opportunities: <LoomDtnOpportunity>[_carrier('peer-c')],
      transmissionId: 'transmission-b-c-0001',
      now: now.add(const Duration(hours: 2)),
    );
    expect(bToC, isNotNull);
    expect(bToC!.copiesBefore, 2);
    expect(bToC.copiesGranted, 1);
    expect(bToC.copiesRetainedAfterSuccess, 1);

    final secondPair = _DuplexNearbyPair();
    final bToCConnection = _connection(secondPair.left);
    final cConnection = _connection(secondPair.right);
    final cReceiver = LoomNearbyDtnTransferReceiver(
      connection: cConnection,
      durablyAccept:
          ({required transmissionId, required exactOuterEnvelopeBytes}) {
            final acceptedAt = now.add(const Duration(hours: 2, seconds: 1));
            final result = cIntake.acceptReplica(
              exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
              now: acceptedAt,
            );
            return LoomDtnHopAck(
              transmissionId: transmissionId,
              packetId: result.packetId,
              acceptedAt: acceptedAt,
              duplicate:
                  result.disposition == LoomReplicaIntakeDisposition.duplicate,
            );
          },
    );

    final receiveOnC = cReceiver.receiveAndAcknowledge();
    final secondResult = await bExecutor.executePrepared(
      transmissionId: bToC.transmissionId,
      sender: LoomNearbyDtnTransferSender(
        connection: bToCConnection,
        clock: () => now.add(const Duration(hours: 2, seconds: 2)),
      ),
    );
    final secondAck = await receiveOnC;

    expect(secondResult.status, LoomDtnExecutionStatus.accepted);
    expect(secondAck.packetId, packetId);
    expect(secondAck.recipientDeliveryConfirmed, isFalse);
    expect(reopenedB.read(packetId)!.copiesRemaining, 1);

    final carriedByC = c.read(packetId);
    expect(carriedByC, isNotNull);
    expect(carriedByC!.origin, LoomDtnPacketOrigin.carriedReplica);
    expect(carriedByC.hopsUsed, 2);
    expect(carriedByC.copiesRemaining, 1);
    expect(carriedByC.recipientConfirmedAt, isNull);

    final cOuter = LoomEnvelopeV2Codec.decodeOuter(carriedByC.wireBytes);
    final sourceOuter = LoomEnvelopeV2Codec.decodeOuter(sourceWire);
    expect(cOuter.packetId, sourceOuter.packetId);
    expect(cOuter.encryptedPayload, sourceOuter.encryptedPayload);
    expect(
      cOuter.routingHint.mailboxToken,
      sourceOuter.routingHint.mailboxToken,
    );
  });
}

Uint8List _sourcePacket(String packetId) => LoomEnvelopeV2Codec.encodeOuter(
  LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 55)),
    ),
    expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: const LoomForwardingStateV2(
      hopsUsed: 0,
      copiesRemaining: 4,
    ),
    encryptedPayload: Uint8List.fromList(<int>[90, 91, 92, 93]),
  ),
);

LoomDtnOpportunity _carrier(String id) => LoomDtnOpportunity(
  opportunityId: id,
  authenticated: true,
  directRecipient: false,
  gatewayClaim: LoomGatewayClaimState.none,
  supportedRelayScopes: const <LoomRoutingScopeV2>{},
  canStoreCarry: true,
  linkQualityPercent: 85,
  congestionPercent: 5,
  batteryConstrained: false,
  recentSuccessfulTransfers: 1,
  recentFailedTransfers: 0,
);

LoomNearbySecureConnection _connection(LoomNearbyLink link) =>
    LoomNearbySecureConnection(
      link: link,
      seal: (bytes) async => List<int>.from(bytes),
      open: (bytes) async => List<int>.from(bytes),
    );

final class _DuplexNearbyPair {
  _DuplexNearbyPair() {
    left = _DuplexNearbyLink(_rightIncoming);
    right = _DuplexNearbyLink(_leftIncoming);
    left._incoming = _leftIncoming;
    right._incoming = _rightIncoming;
  }

  final Queue<List<int>> _leftIncoming = Queue<List<int>>();
  final Queue<List<int>> _rightIncoming = Queue<List<int>>();
  late final _DuplexNearbyLink left;
  late final _DuplexNearbyLink right;
}

final class _DuplexNearbyLink implements LoomNearbyLink {
  _DuplexNearbyLink(this._remoteIncoming);

  Queue<List<int>> _incoming = Queue<List<int>>();
  final Queue<List<int>> _remoteIncoming;
  bool _closed = false;

  @override
  LoomNearbyBearer get bearer => LoomNearbyBearer.localPeer;

  @override
  Future<List<int>> receive({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!_closed && _incoming.isEmpty) {
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException('duplex nearby timeout', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (_closed) throw StateError('duplex nearby link is closed');
    return List<int>.from(_incoming.removeFirst());
  }

  @override
  Future<void> send(List<int> bytes) async {
    if (_closed) throw StateError('duplex nearby link is closed');
    _remoteIncoming.add(List<int>.from(bytes));
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
