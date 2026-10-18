import 'dart:math';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'randomized PacketStore retries preserve exact bytes and collisions fail',
    () {
      final store = LoomSqlitePacketStore.openInMemory();
      addTearDown(store.close);
      final random = Random(0x44544e32);
      final now = DateTime.utc(2026, 9, 6, 8);

      for (var i = 0; i < 200; i++) {
        final suffix = i.toString().padLeft(4, '0');
        final packetId = 'packet-random-$suffix';
        final operationId = 'operation-random-$suffix';
        final messageId = 'message-random-$suffix';
        final payload = Uint8List.fromList(
          List<int>.generate(
            32 + random.nextInt(256),
            (_) => random.nextInt(256),
          ),
        );
        final wire = LoomEnvelopeV2Codec.encodeOuter(
          LoomOuterEnvelopeV2(
            packetId: packetId,
            routingHint: LoomRoutingHintV2(
              scope: random.nextBool()
                  ? LoomRoutingScopeV2.domesticRelay
                  : LoomRoutingScopeV2.globalRelay,
              mailboxToken: Uint8List.fromList(
                List<int>.generate(16, (_) => random.nextInt(256)),
              ),
            ),
            expiresAtBucket: now.add(Duration(hours: 1 + random.nextInt(48))),
            priority: random.nextBool()
                ? LoomPriorityClassV2.normal
                : LoomPriorityClassV2.urgent,
            initialHopLimit: 1 + random.nextInt(8),
            forwardingState: LoomForwardingStateV2(
              hopsUsed: 0,
              copiesRemaining: 1 + random.nextInt(8),
            ),
            encryptedPayload: payload,
          ),
        );

        final first = store.putLocalOutbound(
          operationId: operationId,
          messageId: messageId,
          packetId: packetId,
          exactOuterEnvelopeBytes: wire,
          now: now,
        );
        final retry = store.putLocalOutbound(
          operationId: operationId,
          messageId: messageId,
          packetId: packetId,
          exactOuterEnvelopeBytes: wire,
          now: now.add(const Duration(minutes: 1)),
        );
        expect(retry.packetId, first.packetId);
        expect(retry.wireBytes, orderedEquals(first.wireBytes));
        expect(retry.copiesRemaining, first.copiesRemaining);

        final changed = Uint8List.fromList(wire);
        changed[changed.length - 1] ^= 1;
        expect(
          () => store.putLocalOutbound(
            operationId: operationId,
            messageId: messageId,
            packetId: packetId,
            exactOuterEnvelopeBytes: changed,
            now: now,
          ),
          throwsA(anyOf(isA<LoomDtnPacketConflict>(), isA<FormatException>())),
        );
      }
    },
  );
}
