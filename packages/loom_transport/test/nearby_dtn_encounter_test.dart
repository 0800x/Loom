import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 10, 12);

  for (final retainedCopies in [0, 1]) {
    for (final accepts in [false, true]) {
      test(
        'recipient probe with $retainedCopies copies / accepts=$accepts preserves custody authority',
        () async {
          final a = LoomSqlitePacketStore.openInMemory();
          final b = LoomSqlitePacketStore.openInMemory();
          addTearDown(a.close);
          addTearDown(b.close);
          const packetId = 'packet-recipient-probe-0001';
          a.putLocalOutbound(
            operationId: 'operation-recipient-probe',
            messageId: 'message-recipient-probe',
            packetId: packetId,
            exactOuterEnvelopeBytes: _sourcePacket(packetId, now, copies: 1),
            now: now,
          );
          if (retainedCopies == 0) {
            a.prepareTransfer(
              transmissionId: 'transfer-probe-node-custody',
              now: now,
              plan: const LoomDtnTransferPlan(
                packetId: packetId,
                opportunityId: 'destination-node:probe',
                reason: LoomDtnTransferReason.destinationNode,
                score: 900,
                copiesBefore: 1,
                copiesGranted: 1,
                copiesRetainedAfterSuccess: 0,
                requiresSingleCopyCustodyHandoff: true,
              ),
            );
            a.markTransferAccepted('transfer-probe-node-custody', now);
            a.markGatewayAccepted(packetId, now);
            expect(a.listEligible(now), isEmpty);
          }
          var recipientIntakes = 0;
          final sender = LoomNearbyDtnEncounterCoordinator(
            packetStore: a,
            transferExecutor: LoomDtnTransferExecutor(
              packetStore: a,
              transferStore: a,
              clock: () => now,
            ),
            bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
            clock: () => now,
            durablyAccept: ({
              required transmissionId,
              required exactOuterEnvelopeBytes,
            }) => throw StateError('No sender intake'),
          );
          final receiver =
              LoomNearbyDtnEncounterCoordinator(
                  packetStore: b,
                  transferExecutor: LoomDtnTransferExecutor(
                    packetStore: b,
                    transferStore: b,
                    clock: () => now,
                  ),
                  bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
                  clock: () => now,
                  durablyAccept:
                      ({
                        required transmissionId,
                        required exactOuterEnvelopeBytes,
                      }) => throw StateError(
                        'Probes must not create a relay replica',
                      ),
                )
                ..recipientProbeAcceptor = (bytes) async {
                  expect(
                    LoomEnvelopeV2Codec.decodeOuter(bytes).packetId,
                    packetId,
                  );
                  if (accepts) recipientIntakes++;
                  return accepts;
                };
          final pair = _DuplexNearbyPair();
          final receive = receiver.acceptOverLink(
            link: pair.right,
            signer: await _CryptoSigner.create(),
            localCanStoreCarry: false,
            maxPackets: 2,
            burstIdleTimeout: const Duration(milliseconds: 20),
          );
          final result = await sender.forwardOverLink(
            link: pair.left,
            signer: await _CryptoSigner.create(),
            supportsRecipientProbe: true,
            maxPackets: 1,
          );
          expect(await receive, accepts ? 1 : 0);
          expect(recipientIntakes, accepts ? 1 : 0);
          expect(result.accepted, accepts ? 1 : 0);
          expect(a.read(packetId)!.copiesRemaining, retainedCopies);
          expect(
            a.read(packetId)!.recipientConfirmedAt,
            isNull,
            reason: 'A probe reply is not E2EE delivery evidence',
          );
          expect(
            b.read(packetId),
            isNull,
            reason: 'Only a recipient inbox may accept a probe',
          );
          expect(a.listPreparedTransfers(), isEmpty);
        },
      );
    }
  }

  test('one encrypted Nearby link exchanges both directions without bouncing a received replica', () async {
    final root = Directory.systemTemp.createTempSync('loom-duplex-');
    addTearDown(() => root.deleteSync(recursive: true));
    final aPath = '${root.path}/a.sqlite3', bPath = '${root.path}/b.sqlite3';
    final a = LoomSqlitePacketStore.openFile(aPath),
        b = LoomSqlitePacketStore.openFile(bPath);
    final aIntake = LoomSqliteReplicaIntakeStore.openExistingFile(aPath),
        bIntake = LoomSqliteReplicaIntakeStore.openExistingFile(bPath);
    addTearDown(a.close);
    addTearDown(b.close);
    addTearDown(aIntake.close);
    addTearDown(bIntake.close);
    for (final entry in [
      (a, 'packet-duplex-offline-0001'),
      (b, 'packet-duplex-online-0001'),
    ]) {
      entry.$1.putLocalOutbound(
        operationId: 'operation-${entry.$2}',
        messageId: 'message-${entry.$2}',
        packetId: entry.$2,
        exactOuterEnvelopeBytes: _sourcePacket(entry.$2, now),
        now: now,
      );
    }
    LoomNearbyDtnEncounterCoordinator coordinator(
      LoomSqlitePacketStore store,
      LoomSqliteReplicaIntakeStore intake,
    ) => LoomNearbyDtnEncounterCoordinator(
      packetStore: store,
      transferExecutor: LoomDtnTransferExecutor(
        packetStore: store,
        transferStore: store,
        clock: () => now,
      ),
      bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
      clock: () => now,
      durablyAccept:
          ({required transmissionId, required exactOuterEnvelopeBytes}) {
            final result = intake.acceptReplica(
              exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
              now: now,
            );
            return LoomDtnHopAck(
              transmissionId: transmissionId,
              packetId: result.packetId,
              acceptedAt: result.storedAt,
              duplicate:
                  result.disposition == LoomReplicaIntakeDisposition.duplicate,
            );
          },
    );
    final offline = coordinator(a, aIntake), online = coordinator(b, bIntake);
    final forwardedBack = <String>[];
    online.onPacketForwarded = (packet) => forwardedBack.add(packet.packetId);
    final pair = _DuplexNearbyPair();
    final receive = online.acceptOverLink(
      link: pair.right,
      signer: await _CryptoSigner.create(),
      localCanStoreCarry: true,
      maxPackets: 2,
    );
    final sent = await offline.forwardOverLink(
      link: pair.left,
      signer: await _CryptoSigner.create(),
      localCanStoreCarry: true,
      maxPackets: 2,
      supportsDuplex: true,
    );
    expect(await receive, 1);
    expect(sent.accepted, 1);
    expect(sent.received, 1);
    expect(forwardedBack, ['packet-duplex-online-0001']);
    expect(
      a.read('packet-duplex-online-0001')!.origin,
      LoomDtnPacketOrigin.carriedReplica,
    );
    expect(
      b.read('packet-duplex-offline-0001')!.origin,
      LoomDtnPacketOrigin.carriedReplica,
    );
    expect(a.read('packet-duplex-offline-0001')!.recipientConfirmedAt, isNull);
    expect(b.read('packet-duplex-online-0001')!.recipientConfirmedAt, isNull);
  });

  test(
    'duplex permits recipient-only replies while relay custody is disabled',
    () async {
      final a = LoomSqlitePacketStore.openInMemory(),
          b = LoomSqlitePacketStore.openInMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      b.putLocalOutbound(
        operationId: 'operation-reverse-probe',
        messageId: 'message-reverse-probe',
        packetId: 'packet-reverse-probe-0001',
        exactOuterEnvelopeBytes: _sourcePacket(
          'packet-reverse-probe-0001',
          now,
          copies: 1,
        ),
        now: now,
      );
      LoomNearbyDtnEncounterCoordinator coordinator(
        LoomSqlitePacketStore store,
      ) => LoomNearbyDtnEncounterCoordinator(
        packetStore: store,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: store,
          transferStore: store,
          clock: () => now,
        ),
        bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
        clock: () => now,
        durablyAccept: ({
          required transmissionId,
          required exactOuterEnvelopeBytes,
        }) => throw StateError('Recipient probe must not take relay custody'),
      );
      final offline = coordinator(a), online = coordinator(b);
      var received = 0;
      offline.recipientProbeAcceptor = (bytes) async {
        received++;
        return true;
      };
      final pair = _DuplexNearbyPair();
      final accept = online.acceptOverLink(
        link: pair.right,
        signer: await _CryptoSigner.create(),
        localCanStoreCarry: false,
      );
      final result = await offline.forwardOverLink(
        link: pair.left,
        signer: await _CryptoSigner.create(),
        localCanStoreCarry: false,
        supportsDuplex: true,
      );
      expect(await accept, 0);
      expect(result.received, 1);
      expect(received, 1);
      expect(a.listEligible(now), isEmpty);
      expect(b.read('packet-reverse-probe-0001')!.copiesRemaining, 1);
      expect(b.read('packet-reverse-probe-0001')!.recipientConfirmedAt, isNull);
    },
  );

  test(
    'authenticated Nearby commits custody despite Internet retry backoff',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'loom-nearby-encounter-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final aPath = '${root.path}${Platform.pathSeparator}a.sqlite3';
      final bPath = '${root.path}${Platform.pathSeparator}b.sqlite3';
      final a = LoomSqlitePacketStore.openFile(aPath);
      final b = LoomSqlitePacketStore.openFile(bPath);
      final bIntake = LoomSqliteReplicaIntakeStore.openExistingFile(bPath);
      addTearDown(a.close);
      addTearDown(b.close);
      addTearDown(bIntake.close);

      const packetId = 'packet-nearby-encounter-0001';
      a.putLocalOutbound(
        operationId: 'operation-nearby-encounter-0001',
        messageId: 'message-nearby-encounter-0001',
        packetId: packetId,
        exactOuterEnvelopeBytes: _sourcePacket(packetId, now),
        now: now,
      );

      a.recordAttempt(
        packetId,
        attemptedAt: now,
        nextAttemptAt: now.add(const Duration(minutes: 3)),
        errorCode: 'destination-node-unverified',
      );
      expect(a.listEligible(now), isEmpty);

      final pair = _DuplexNearbyPair();
      final aSigner = await _CryptoSigner.create();
      final bSigner = await _CryptoSigner.create();
      final aCoordinator = LoomNearbyDtnEncounterCoordinator(
        packetStore: a,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: a,
          transferStore: a,
          clock: () => now.add(const Duration(seconds: 2)),
        ),
        durablyAccept: ({
          required transmissionId,
          required exactOuterEnvelopeBytes,
        }) => throw StateError('sender must not accept inbound packets'),
        bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
        clock: () => now.add(const Duration(seconds: 2)),
      );
      var durableCommitCompleted = false;
      final bCoordinator = LoomNearbyDtnEncounterCoordinator(
        packetStore: b,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: b,
          transferStore: b,
          clock: () => now.add(const Duration(seconds: 1)),
        ),
        durablyAccept:
            ({required transmissionId, required exactOuterEnvelopeBytes}) {
              final result = bIntake.acceptReplica(
                exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
                now: now.add(const Duration(seconds: 1)),
              );
              durableCommitCompleted = true;
              return LoomDtnHopAck(
                transmissionId: transmissionId,
                packetId: result.packetId,
                acceptedAt: result.storedAt,
                duplicate:
                    result.disposition ==
                    LoomReplicaIntakeDisposition.duplicate,
              );
            },
        bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
        clock: () => now.add(const Duration(seconds: 1)),
      );

      final receiveFuture = bCoordinator.acceptOverLink(
        link: pair.right,
        signer: bSigner,
        localCanStoreCarry: true,
        maxPackets: 2,
        idleTimeout: const Duration(milliseconds: 50),
        burstIdleTimeout: const Duration(milliseconds: 20),
      );
      final result = await aCoordinator.forwardOverLink(
        link: pair.left,
        signer: aSigner,
        maxPackets: 1,
      );
      final received = await receiveFuture;

      expect(durableCommitCompleted, isTrue);
      expect(result.attempted, 1);
      expect(result.accepted, 1);
      expect(result.failed, 0);
      expect(received, 1);

      final carried = b.read(packetId);
      expect(carried, isNotNull);
      expect(carried!.origin, LoomDtnPacketOrigin.carriedReplica);
      expect(carried.hopsUsed, 1);
      expect(carried.copiesRemaining, 2);
      expect(a.read(packetId)!.copiesRemaining, 2);
      expect(
        a.listEligible(now.add(const Duration(seconds: 2))).single.packetId,
        packetId,
        reason: 'A successful local hop clears the stale route failure',
      );
    },
  );

  test('generic Nearby peer cannot receive the last forwarding copy', () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    const packetId = 'packet-nearby-last-copy-0001';
    final wire = LoomEnvelopeV2Codec.encodeOuter(
      LoomOuterEnvelopeV2(
        packetId: packetId,
        routingHint: LoomRoutingHintV2(
          scope: LoomRoutingScopeV2.globalRelay,
          mailboxToken: Uint8List.fromList(List<int>.filled(32, 77)),
        ),
        expiresAtBucket: now.add(const Duration(days: 1)),
        priority: LoomPriorityClassV2.normal,
        initialHopLimit: 4,
        forwardingState: const LoomForwardingStateV2(
          hopsUsed: 0,
          copiesRemaining: 1,
        ),
        encryptedPayload: Uint8List.fromList(<int>[1, 2, 3]),
      ),
    );
    store.putLocalOutbound(
      operationId: 'operation-nearby-last-copy-0001',
      messageId: 'message-nearby-last-copy-0001',
      packetId: packetId,
      exactOuterEnvelopeBytes: wire,
      now: now,
    );

    final plan =
        LoomDtnTransferExecutor(
          packetStore: store,
          transferStore: store,
        ).prepareNext(
          packetId: packetId,
          opportunities: <LoomDtnOpportunity>[
            LoomDtnOpportunity(
              opportunityId: 'nearby:generic-peer',
              authenticated: true,
              directRecipient: false,
              gatewayClaim: LoomGatewayClaimState.none,
              supportedRelayScopes: const <LoomRoutingScopeV2>{},
              canStoreCarry: true,
              linkQualityPercent: 100,
              congestionPercent: 0,
              batteryConstrained: false,
              recentSuccessfulTransfers: 10,
              recentFailedTransfers: 0,
            ),
          ],
          transmissionId: 'transmission-nearby-last-copy-0001',
          now: now,
        );

    expect(plan, isNull);
  });
}

Uint8List _sourcePacket(String packetId, DateTime now, {int copies = 4}) =>
    LoomEnvelopeV2Codec.encodeOuter(
      LoomOuterEnvelopeV2(
        packetId: packetId,
        routingHint: LoomRoutingHintV2(
          scope: LoomRoutingScopeV2.globalRelay,
          mailboxToken: Uint8List.fromList(List<int>.filled(32, 55)),
        ),
        expiresAtBucket: now.add(const Duration(days: 1)),
        priority: LoomPriorityClassV2.normal,
        initialHopLimit: 4,
        forwardingState: LoomForwardingStateV2(
          hopsUsed: 0,
          copiesRemaining: copies,
        ),
        encryptedPayload: Uint8List.fromList(<int>[90, 91, 92, 93]),
      ),
    );

final class _CryptoSigner implements LoomDirectTransportSigner {
  _CryptoSigner(this._keyPair);

  final KeyPair _keyPair;
  static final Ed25519 _algorithm = Ed25519();

  static Future<_CryptoSigner> create() async =>
      _CryptoSigner(await _algorithm.newKeyPair());

  @override
  Future<Uint8List> ed25519PublicKey() async => Uint8List.fromList(
    (await _keyPair.extractPublicKey() as SimplePublicKey).bytes,
  );

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async => Uint8List.fromList(
    (await _algorithm.sign(canonicalBytes, keyPair: _keyPair)).bytes,
  );
}

final class _DuplexNearbyPair {
  _DuplexNearbyPair() {
    left = _DuplexNearbyLink(_rightIncoming);
    right = _DuplexNearbyLink(_leftIncoming);
    left._incoming = _leftIncoming;
    right._incoming = _rightIncoming;
    left._peer = right;
    right._peer = left;
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
  bool _remoteClosed = false;
  _DuplexNearbyLink? _peer;

  @override
  LoomNearbyBearer get bearer => LoomNearbyBearer.localPeer;

  @override
  Future<List<int>> receive({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!_closed && !_remoteClosed && _incoming.isEmpty) {
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException('duplex nearby timeout', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (_closed || (_remoteClosed && _incoming.isEmpty))
      throw StateError('duplex nearby link is closed');
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
    _peer?._remoteClosed = true;
  }
}
