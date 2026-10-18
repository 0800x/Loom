import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('destination route survives restart beside durable packet custody', () {
    final root = Directory.systemTemp.createTempSync('loom-dtn-route-');
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}${Platform.pathSeparator}dtn.sqlite3';
    final now = DateTime.utc(2026, 9, 10, 10);
    const packetId = 'packet-destination-route-0001';

    final packets = LoomSqlitePacketStore.openFile(path);
    packets.putLocalOutbound(
      operationId: 'operation-destination-route-0001',
      messageId: 'message-destination-route-0001',
      packetId: packetId,
      exactOuterEnvelopeBytes: _wire(packetId, now),
      now: now,
    );
    final routes = LoomSqlitePacketRouteStore.openExistingFile(path);
    routes.rememberDestinationRoute(
      packetId: packetId,
      destinationNodeDomain: 'Node.Example',
      now: now,
    );
    routes.close();
    packets.close();

    final reopenedPackets = LoomSqlitePacketStore.openFile(path);
    final reopenedRoutes = LoomSqlitePacketRouteStore.openExistingFile(path);
    addTearDown(reopenedRoutes.close);
    addTearDown(reopenedPackets.close);

    expect(reopenedPackets.read(packetId), isNotNull);
    final route = reopenedRoutes.readDestinationRoute(packetId);
    expect(route, isNotNull);
    expect(route!.destinationNodeDomain, 'node.example');
    expect(route.recordedAt, now);
  });

  test('destination route is immutable for one PacketId', () {
    final root = Directory.systemTemp.createTempSync(
      'loom-dtn-route-conflict-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final path = '${root.path}${Platform.pathSeparator}dtn.sqlite3';
    final now = DateTime.utc(2026, 9, 10, 11);
    const packetId = 'packet-destination-route-0002';
    final packets = LoomSqlitePacketStore.openFile(path);
    final routes = LoomSqlitePacketRouteStore.openExistingFile(path);
    addTearDown(routes.close);
    addTearDown(packets.close);
    packets.putLocalOutbound(
      operationId: 'operation-destination-route-0002',
      messageId: 'message-destination-route-0002',
      packetId: packetId,
      exactOuterEnvelopeBytes: _wire(packetId, now),
      now: now,
    );
    routes.rememberDestinationRoute(
      packetId: packetId,
      destinationNodeDomain: 'node.example',
      now: now,
    );

    expect(
      () => routes.rememberDestinationRoute(
        packetId: packetId,
        destinationNodeDomain: 'other.example',
        now: now.add(const Duration(seconds: 1)),
      ),
      throwsA(isA<LoomDtnPacketConflict>()),
    );
  });
}

Uint8List _wire(String packetId, DateTime now) =>
    LoomEnvelopeV2Codec.encodeOuter(
      LoomOuterEnvelopeV2(
        packetId: packetId,
        routingHint: LoomRoutingHintV2(
          scope: LoomRoutingScopeV2.globalRelay,
          mailboxToken: Uint8List.fromList(List<int>.filled(32, 17)),
        ),
        expiresAtBucket: DateTime.utc(
          now.year,
          now.month,
          now.day + 1,
          now.hour,
        ),
        priority: LoomPriorityClassV2.normal,
        initialHopLimit: 4,
        forwardingState: const LoomForwardingStateV2(
          hopsUsed: 0,
          copiesRemaining: 4,
        ),
        encryptedPayload: Uint8List.fromList(<int>[1, 2, 3, 4]),
      ),
    );
