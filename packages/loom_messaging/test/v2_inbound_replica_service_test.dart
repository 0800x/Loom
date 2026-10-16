import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test('returns hop ACK only after trusted peer packet is durably visible', () {
    final directory = Directory.systemTemp.createTempSync('loom-inbound-msg-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    final service = LoomV2InboundReplicaService(
      intakeStore: intake,
      peerTrust: const _TestPeerTrust(<String>{'peer-session-0001'}),
    );
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    final wire = _wire('packet-inbound-msg-0001');
    final ack = service.acceptFromPeer(
      peerSessionId: 'peer-session-0001',
      transmissionId: 'transmission-inbound-0001',
      exactOuterEnvelopeBytes: wire,
      now: now,
    );

    expect(ack.packetId, 'packet-inbound-msg-0001');
    expect(ack.transmissionId, 'transmission-inbound-0001');
    expect(ack.duplicate, isFalse);
    expect(ack.recipientDeliveryConfirmed, isFalse);

    final persisted = packetStore.read(ack.packetId);
    expect(persisted, isNotNull);
    expect(persisted!.wireBytes, wire);
    expect(persisted.origin, LoomDtnPacketOrigin.carriedReplica);
  });

  test(
    'durable duplicate is ACKable but does not become delivery confirmation',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'loom-inbound-dup-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
      final packetStore = LoomSqlitePacketStore.openFile(path);
      final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
      final service = LoomV2InboundReplicaService(
        intakeStore: intake,
        peerTrust: const _TestPeerTrust(<String>{'peer-session-0002'}),
      );
      addTearDown(packetStore.close);
      addTearDown(intake.close);

      final wire = _wire('packet-inbound-msg-0002');
      service.acceptFromPeer(
        peerSessionId: 'peer-session-0002',
        transmissionId: 'transmission-inbound-0002a',
        exactOuterEnvelopeBytes: wire,
        now: now,
      );
      final duplicate = service.acceptFromPeer(
        peerSessionId: 'peer-session-0002',
        transmissionId: 'transmission-inbound-0002b',
        exactOuterEnvelopeBytes: wire,
        now: now.add(const Duration(seconds: 5)),
      );

      expect(duplicate.duplicate, isTrue);
      expect(duplicate.recipientDeliveryConfirmed, isFalse);
      expect(packetStore.read(duplicate.packetId), isNotNull);
    },
  );

  test('untrusted peer session is rejected before durable intake', () {
    final directory = Directory.systemTemp.createTempSync(
      'loom-inbound-reject-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    final service = LoomV2InboundReplicaService(
      intakeStore: intake,
      peerTrust: const _TestPeerTrust(<String>{'peer-session-trusted'}),
    );
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    final wire = _wire('packet-inbound-msg-0003');
    expect(
      () => service.acceptFromPeer(
        peerSessionId: 'peer-session-untrusted',
        transmissionId: 'transmission-inbound-0003',
        exactOuterEnvelopeBytes: wire,
        now: now,
      ),
      throwsStateError,
    );
    expect(packetStore.read('packet-inbound-msg-0003'), isNull);
  });

  test('trusted conflicting peer data produces no ACK result', () {
    final directory = Directory.systemTemp.createTempSync(
      'loom-inbound-conflict-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    final service = LoomV2InboundReplicaService(
      intakeStore: intake,
      peerTrust: const _TestPeerTrust(<String>{'peer-session-0004'}),
    );
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    final wire = _wire('packet-inbound-msg-0004');
    service.acceptFromPeer(
      peerSessionId: 'peer-session-0004',
      transmissionId: 'transmission-inbound-0004a',
      exactOuterEnvelopeBytes: wire,
      now: now,
    );
    expect(
      () => service.acceptFromPeer(
        peerSessionId: 'peer-session-0004',
        transmissionId: 'transmission-inbound-0004b',
        exactOuterEnvelopeBytes: _wire(
          'packet-inbound-msg-0004',
          payloadByte: 99,
        ),
        now: now.add(const Duration(seconds: 1)),
      ),
      throwsA(isA<LoomReplicaConflict>()),
    );
  });

  test('malformed peer session id is rejected before trust lookup', () {
    final directory = Directory.systemTemp.createTempSync('loom-inbound-id-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    final trust = _CountingPeerTrust();
    final service = LoomV2InboundReplicaService(
      intakeStore: intake,
      peerTrust: trust,
    );
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    expect(
      () => service.acceptFromPeer(
        peerSessionId: ' x ',
        transmissionId: 'transmission-inbound-0005',
        exactOuterEnvelopeBytes: _wire('packet-inbound-msg-0005'),
        now: now,
      ),
      throwsFormatException,
    );
    expect(trust.lookupCount, 0);
    expect(packetStore.read('packet-inbound-msg-0005'), isNull);
  });
}

final class _TestPeerTrust implements LoomPeerSessionTrustGate {
  const _TestPeerTrust(this.authenticatedSessionIds);

  final Set<String> authenticatedSessionIds;

  @override
  bool isAuthenticatedPeerSession(String peerSessionId) =>
      authenticatedSessionIds.contains(peerSessionId);
}

final class _CountingPeerTrust implements LoomPeerSessionTrustGate {
  int lookupCount = 0;

  @override
  bool isAuthenticatedPeerSession(String peerSessionId) {
    lookupCount += 1;
    return false;
  }
}

Uint8List _wire(String packetId, {int payloadByte = 7}) {
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 17)),
    ),
    expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: const LoomForwardingStateV2(
      hopsUsed: 1,
      copiesRemaining: 2,
    ),
    encryptedPayload: Uint8List.fromList(<int>[payloadByte, 2, 3, 4]),
  );
  return LoomEnvelopeV2Codec.encodeOuter(outer);
}
