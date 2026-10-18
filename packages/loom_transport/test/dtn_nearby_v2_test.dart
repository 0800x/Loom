import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test(
    'nearby sender transmits exact prepared bytes and maps hop ACK',
    () async {
      final link = _FakeNearbyLink();
      final connection = _connection(link);
      final transfer = _preparedTransfer('0001', now);
      final ackFrame = LoomDtnHopAckFrameV2(
        transmissionId: transfer.transmissionId,
        packetId: transfer.packetId,
        acceptedAt: now.add(const Duration(seconds: 1)),
        duplicate: false,
      );
      link.incoming.add(LoomDtnPeerFrameV2Codec.encode(ackFrame));

      final sender = LoomNearbyDtnTransferSender(
        connection: connection,
        clock: () => now,
      );
      final result = await sender.sendPrepared(transfer);

      expect(result, isA<LoomDtnSendAccepted>());
      final accepted = result as LoomDtnSendAccepted;
      expect(accepted.ack.transmissionId, transfer.transmissionId);
      expect(accepted.ack.packetId, transfer.packetId);
      expect(accepted.ack.recipientDeliveryConfirmed, isFalse);

      expect(link.sent, hasLength(1));
      final sentFrame = LoomDtnPeerFrameV2Codec.decode(
        Uint8List.fromList(link.sent.single),
      ) as LoomDtnPacketTransferFrameV2;
      expect(sentFrame.transmissionId, transfer.transmissionId);
      expect(sentFrame.outerEnvelopeBytes, transfer.wireBytes);
      expect(sentFrame.destinationNodeDomain, isNull);
    },
  );

  test('nearby sender carries the destination Node route sidecar', () async {
    final link = _FakeNearbyLink();
    final connection = _connection(link);
    final transfer = _preparedTransfer('route-0001', now);
    link.incoming.add(
      LoomDtnPeerFrameV2Codec.encode(
        LoomDtnHopAckFrameV2(
          transmissionId: transfer.transmissionId,
          packetId: transfer.packetId,
          acceptedAt: now.add(const Duration(seconds: 1)),
          duplicate: false,
        ),
      ),
    );

    final sender = LoomNearbyDtnTransferSender(
      connection: connection,
      destinationRoute: (packetId) {
        expect(packetId, transfer.packetId);
        return 'recipient.example';
      },
      clock: () => now,
    );

    final result = await sender.sendPrepared(transfer);
    expect(result, isA<LoomDtnSendAccepted>());
    final sentFrame = LoomDtnPeerFrameV2Codec.decode(
      Uint8List.fromList(link.sent.single),
    ) as LoomDtnPacketTransferFrameV2;
    expect(sentFrame.destinationNodeDomain, 'recipient.example');
  });

  test(
    'receiver sends ACK only after durable intake callback completes',
    () async {
      final link = _FakeNearbyLink();
      final connection = _connection(link);
      final transfer = _preparedTransfer('0002', now);
      final transferFrame = LoomDtnPacketTransferFrameV2(
        transmissionId: transfer.transmissionId,
        outerEnvelopeBytes: transfer.wireBytes,
      );
      link.incoming.add(LoomDtnPeerFrameV2Codec.encode(transferFrame));

      var durable = false;
      link.onSend = (_) {
        expect(
          durable,
          isTrue,
          reason: 'hop ACK escaped before durable custody',
        );
      };
      final receiver = LoomNearbyDtnTransferReceiver(
        connection: connection,
        durablyAccept: ({
          required transmissionId,
          required exactOuterEnvelopeBytes,
        }) async {
          expect(transmissionId, transfer.transmissionId);
          expect(exactOuterEnvelopeBytes, transfer.wireBytes);
          durable = true;
          return LoomDtnHopAck(
            transmissionId: transmissionId,
            packetId: transfer.packetId,
            acceptedAt: now.add(const Duration(seconds: 2)),
            duplicate: true,
          );
        },
      );

      final ack = await receiver.receiveAndAcknowledge();
      expect(ack.duplicate, isTrue);
      expect(link.sent, hasLength(1));
      final encodedAck = LoomDtnPeerFrameV2Codec.decode(
        Uint8List.fromList(link.sent.single),
      ) as LoomDtnHopAckFrameV2;
      expect(encodedAck.transmissionId, transfer.transmissionId);
      expect(encodedAck.packetId, transfer.packetId);
      expect(encodedAck.duplicate, isTrue);
    },
  );

  test('routed receiver persists route before returning the hop ACK', () async {
    final link = _FakeNearbyLink();
    final connection = _connection(link);
    final transfer = _preparedTransfer('route-0002', now);
    link.incoming.add(
      LoomDtnPeerFrameV2Codec.encode(
        LoomDtnPacketTransferFrameV2(
          transmissionId: transfer.transmissionId,
          outerEnvelopeBytes: transfer.wireBytes,
          destinationNodeDomain: 'recipient.example',
        ),
      ),
    );

    var routedDurable = false;
    link.onSend = (_) {
      expect(
        routedDurable,
        isTrue,
        reason: 'hop ACK escaped before packet and route durable custody',
      );
    };
    final receiver = LoomNearbyDtnTransferReceiver(
      connection: connection,
      durablyAccept: (
          {required transmissionId, required exactOuterEnvelopeBytes}) {
        fail('route-aware runtime must use the routed durable callback');
      },
      durablyAcceptRouted: ({
        required transmissionId,
        required exactOuterEnvelopeBytes,
        required destinationNodeDomain,
      }) async {
        expect(transmissionId, transfer.transmissionId);
        expect(exactOuterEnvelopeBytes, transfer.wireBytes);
        expect(destinationNodeDomain, 'recipient.example');
        routedDurable = true;
        return LoomDtnHopAck(
          transmissionId: transmissionId,
          packetId: transfer.packetId,
          acceptedAt: now.add(const Duration(seconds: 2)),
          duplicate: false,
        );
      },
    );

    final ack = await receiver.receiveAndAcknowledge();
    expect(ack.packetId, transfer.packetId);
    expect(link.sent, hasLength(1));
  });

  test('receiver does not send ACK when durable intake fails', () async {
    final link = _FakeNearbyLink();
    final connection = _connection(link);
    final transfer = _preparedTransfer('0003', now);
    link.incoming.add(
      LoomDtnPeerFrameV2Codec.encode(
        LoomDtnPacketTransferFrameV2(
          transmissionId: transfer.transmissionId,
          outerEnvelopeBytes: transfer.wireBytes,
        ),
      ),
    );
    final receiver = LoomNearbyDtnTransferReceiver(
      connection: connection,
      durablyAccept: (
          {required transmissionId, required exactOuterEnvelopeBytes}) {
        throw const LoomReplicaConflict('packet conflict');
      },
    );

    await expectLater(
      receiver.receiveAndAcknowledge(),
      throwsA(isA<LoomReplicaConflict>()),
    );
    expect(link.sent, isEmpty);
  });

  test('mismatched durable ACK transmission is rejected before send', () async {
    final link = _FakeNearbyLink();
    final connection = _connection(link);
    final transfer = _preparedTransfer('0004', now);
    link.incoming.add(
      LoomDtnPeerFrameV2Codec.encode(
        LoomDtnPacketTransferFrameV2(
          transmissionId: transfer.transmissionId,
          outerEnvelopeBytes: transfer.wireBytes,
        ),
      ),
    );
    final receiver = LoomNearbyDtnTransferReceiver(
      connection: connection,
      durablyAccept: (
              {required transmissionId, required exactOuterEnvelopeBytes}) =>
          LoomDtnHopAck(
        transmissionId: 'transmission-nearby-wrong',
        packetId: transfer.packetId,
        acceptedAt: now,
        duplicate: false,
      ),
    );

    await expectLater(receiver.receiveAndAcknowledge(), throwsFormatException);
    expect(link.sent, isEmpty);
  });

  test(
    'malformed nearby ACK is converted to structured send failure',
    () async {
      final link = _FakeNearbyLink();
      final connection = _connection(link);
      final transfer = _preparedTransfer('0005', now);
      link.incoming.add(<int>[1, 2, 3, 4]);
      final sender = LoomNearbyDtnTransferSender(
        connection: connection,
        clock: () => now,
      );

      final result = await sender.sendPrepared(transfer);
      expect(result, isA<LoomDtnSendFailed>());
      expect((result as LoomDtnSendFailed).errorCode, 'invalid_peer_frame');
    },
  );

  test('nearby receive timeout becomes bounded structured error', () async {
    final link = _FakeNearbyLink();
    final connection = _connection(link);
    final transfer = _preparedTransfer('0006', now);
    final sender = LoomNearbyDtnTransferSender(
      connection: connection,
      ackTimeout: const Duration(milliseconds: 1),
      clock: () => now,
    );

    final result = await sender.sendPrepared(transfer);
    expect(result, isA<LoomDtnSendFailed>());
    expect((result as LoomDtnSendFailed).errorCode, 'nearby_timeout');
  });
}

LoomNearbySecureConnection _connection(_FakeNearbyLink link) =>
    LoomNearbySecureConnection(
      link: link,
      seal: (bytes) async => List<int>.from(bytes),
      open: (bytes) async => List<int>.from(bytes),
    );

LoomStoredDtnTransfer _preparedTransfer(String suffix, DateTime now) {
  final packetId = 'packet-nearby-$suffix';
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 44)),
    ),
    expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: const LoomForwardingStateV2(
      hopsUsed: 1,
      copiesRemaining: 2,
    ),
    encryptedPayload: Uint8List.fromList(<int>[5, 6, 7, 8]),
  );
  return LoomStoredDtnTransfer(
    transmissionId: 'transmission-nearby-$suffix',
    packetId: packetId,
    opportunityId: 'peer-nearby-$suffix',
    reason: LoomDtnTransferReason.storeCarryPeer,
    wireBytes: LoomEnvelopeV2Codec.encodeOuter(outer),
    copiesBefore: 4,
    copiesGranted: 2,
    copiesRetainedAfterSuccess: 2,
    requiresSingleCopyCustodyHandoff: false,
    preparedAt: now,
    state: LoomDtnTransferState.prepared,
    completedAt: null,
    errorCode: null,
  );
}

final class _FakeNearbyLink implements LoomNearbyLink {
  final Queue<List<int>> incoming = Queue<List<int>>();
  final List<List<int>> sent = <List<int>>[];
  void Function(List<int>)? onSend;
  bool closed = false;

  @override
  LoomNearbyBearer get bearer => LoomNearbyBearer.localPeer;

  @override
  Future<List<int>> receive({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (incoming.isEmpty)
      throw TimeoutException('fake nearby timeout', timeout);
    return List<int>.from(incoming.removeFirst());
  }

  @override
  Future<void> send(List<int> bytes) async {
    onSend?.call(bytes);
    sent.add(List<int>.from(bytes));
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
