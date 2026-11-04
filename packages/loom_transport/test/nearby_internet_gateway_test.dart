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
  final now = DateTime.utc(2026, 9, 10, 13);

  test(
    'offline phone hands routed packet to claimed nearby Internet gateway',
    () async {
      final root = Directory.systemTemp.createTempSync('loom-nearby-uplink-');
      addTearDown(() => root.deleteSync(recursive: true));
      final aPath = '${root.path}${Platform.pathSeparator}a.sqlite3';
      final bPath = '${root.path}${Platform.pathSeparator}b.sqlite3';
      final aPackets = LoomSqlitePacketStore.openFile(aPath);
      final bPackets = LoomSqlitePacketStore.openFile(bPath);
      final aRoutes = LoomSqlitePacketRouteStore.openExistingFile(aPath);
      final bRoutes = LoomSqlitePacketRouteStore.openExistingFile(bPath);
      final bIntake = LoomSqliteReplicaIntakeStore.openExistingFile(bPath);
      addTearDown(aRoutes.close);
      addTearDown(bRoutes.close);
      addTearDown(bIntake.close);
      addTearDown(aPackets.close);
      addTearDown(bPackets.close);

      const packetId = 'packet-nearby-uplink-0001';
      aPackets.putLocalOutbound(
        operationId: 'operation-nearby-uplink-0001',
        messageId: 'message-nearby-uplink-0001',
        packetId: packetId,
        exactOuterEnvelopeBytes: _wire(packetId, now, copies: 4),
        now: now,
      );
      aRoutes.rememberDestinationRoute(
        packetId: packetId,
        destinationNodeDomain: 'recipient.example',
        now: now,
      );

      final a = LoomNearbyInternetGatewayEncounter(
        packetStore: aPackets,
        routeStore: aRoutes,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: aPackets,
          transferStore: aPackets,
          clock: () => now.add(const Duration(seconds: 2)),
        ),
        durablyAccept: ({
          required transmissionId,
          required exactOuterEnvelopeBytes,
          required destinationNodeDomain,
        }) => throw StateError('sender must not accept gateway packets'),
        bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
        clock: () => now.add(const Duration(seconds: 2)),
      );
      final b = LoomNearbyInternetGatewayEncounter(
        packetStore: bPackets,
        routeStore: bRoutes,
        transferExecutor: LoomDtnTransferExecutor(
          packetStore: bPackets,
          transferStore: bPackets,
          clock: () => now.add(const Duration(seconds: 1)),
        ),
        durablyAccept:
            ({
              required transmissionId,
              required exactOuterEnvelopeBytes,
              required destinationNodeDomain,
            }) {
              final intake = bIntake.acceptReplica(
                exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
                now: now.add(const Duration(seconds: 1)),
              );
              bRoutes.rememberDestinationRoute(
                packetId: intake.packetId,
                destinationNodeDomain: destinationNodeDomain,
                now: now.add(const Duration(seconds: 1)),
              );
              return LoomDtnHopAck(
                transmissionId: transmissionId,
                packetId: intake.packetId,
                acceptedAt: intake.storedAt,
                duplicate:
                    intake.disposition ==
                    LoomReplicaIntakeDisposition.duplicate,
              );
            },
        bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
        clock: () => now.add(const Duration(seconds: 1)),
      );

      final pair = _DuplexNearbyPair();
      final aSigner = await _CryptoSigner.create();
      final bSigner = await _CryptoSigner.create();
      final receiving = b.acceptOverLink(
        link: pair.right,
        signer: bSigner,
        internetGatewayAvailable: true,
        maxPackets: 1,
      );
      final forwarded = await a.forwardOverLink(
        link: pair.left,
        signer: aSigner,
        maxPackets: 1,
      );

      expect(await receiving, 1);
      expect(forwarded.gatewayOffered, isTrue);
      expect(forwarded.attempted, 1);
      expect(forwarded.accepted, 1);
      expect(bPackets.read(packetId), isNotNull);
      expect(
        bRoutes.readDestinationRoute(packetId)!.destinationNodeDomain,
        'recipient.example',
      );
      expect(
        bPackets.read(packetId)!.origin,
        LoomDtnPacketOrigin.carriedReplica,
      );
      expect(aPackets.read(packetId)!.copiesRemaining, lessThan(4));
    },
  );

  test(
    'claimed nearby Internet gateway never receives the final copy',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'loom-nearby-uplink-last-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final aPath = '${root.path}${Platform.pathSeparator}a.sqlite3';
      final bPath = '${root.path}${Platform.pathSeparator}b.sqlite3';
      final aPackets = LoomSqlitePacketStore.openFile(aPath);
      final bPackets = LoomSqlitePacketStore.openFile(bPath);
      final aRoutes = LoomSqlitePacketRouteStore.openExistingFile(aPath);
      final bRoutes = LoomSqlitePacketRouteStore.openExistingFile(bPath);
      final bIntake = LoomSqliteReplicaIntakeStore.openExistingFile(bPath);
      addTearDown(aRoutes.close);
      addTearDown(bRoutes.close);
      addTearDown(bIntake.close);
      addTearDown(aPackets.close);
      addTearDown(bPackets.close);

      const packetId = 'packet-nearby-uplink-last-0001';
      aPackets.putLocalOutbound(
        operationId: 'operation-nearby-uplink-last-0001',
        messageId: 'message-nearby-uplink-last-0001',
        packetId: packetId,
        exactOuterEnvelopeBytes: _wire(packetId, now, copies: 1),
        now: now,
      );
      aRoutes.rememberDestinationRoute(
        packetId: packetId,
        destinationNodeDomain: 'recipient.example',
        now: now,
      );

      final a = _encounter(
        packets: aPackets,
        routes: aRoutes,
        now: now,
        accept: ({
          required transmissionId,
          required exactOuterEnvelopeBytes,
          required destinationNodeDomain,
        }) => throw StateError('sender cannot receive'),
      );
      final b = _encounter(
        packets: bPackets,
        routes: bRoutes,
        now: now,
        accept:
            ({
              required transmissionId,
              required exactOuterEnvelopeBytes,
              required destinationNodeDomain,
            }) {
              final intake = bIntake.acceptReplica(
                exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
                now: now,
              );
              bRoutes.rememberDestinationRoute(
                packetId: intake.packetId,
                destinationNodeDomain: destinationNodeDomain,
                now: now,
              );
              return LoomDtnHopAck(
                transmissionId: transmissionId,
                packetId: intake.packetId,
                acceptedAt: now,
                duplicate: false,
              );
            },
      );
      final pair = _DuplexNearbyPair();
      final receiving = b.acceptOverLink(
        link: pair.right,
        signer: await _CryptoSigner.create(),
        internetGatewayAvailable: true,
        maxPackets: 1,
        idleTimeout: const Duration(milliseconds: 50),
      );
      final forwarded = await a.forwardOverLink(
        link: pair.left,
        signer: await _CryptoSigner.create(),
        maxPackets: 1,
      );

      expect(forwarded.gatewayOffered, isTrue);
      expect(forwarded.attempted, 0);
      expect(forwarded.accepted, 0);
      expect(await receiving, 0);
      expect(bPackets.read(packetId), isNull);
      expect(aPackets.read(packetId)!.copiesRemaining, 1);
    },
  );
}

LoomNearbyInternetGatewayEncounter _encounter({
  required LoomSqlitePacketStore packets,
  required LoomSqlitePacketRouteStore routes,
  required DateTime now,
  required LoomNearbyGatewayDurableAccept accept,
}) => LoomNearbyInternetGatewayEncounter(
  packetStore: packets,
  routeStore: routes,
  transferExecutor: LoomDtnTransferExecutor(
    packetStore: packets,
    transferStore: packets,
    clock: () => now,
  ),
  durablyAccept: accept,
  bootstrap: LoomNearbyDtnPeerBootstrap(clock: () => now),
  clock: () => now,
);

Uint8List _wire(String packetId, DateTime now, {required int copies}) =>
    LoomEnvelopeV2Codec.encodeOuter(
      LoomOuterEnvelopeV2(
        packetId: packetId,
        routingHint: LoomRoutingHintV2(
          scope: LoomRoutingScopeV2.globalRelay,
          mailboxToken: Uint8List.fromList(List<int>.filled(32, 99)),
        ),
        expiresAtBucket: now.add(const Duration(days: 1)),
        priority: LoomPriorityClassV2.normal,
        initialHopLimit: 4,
        forwardingState: LoomForwardingStateV2(
          hopsUsed: 0,
          copiesRemaining: copies,
        ),
        encryptedPayload: Uint8List.fromList(<int>[10, 20, 30]),
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
