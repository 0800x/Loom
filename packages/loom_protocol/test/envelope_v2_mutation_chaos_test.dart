import 'dart:math';
import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('mutated OuterEnvelope corpus either decodes safely or fails with FormatException', () {
    final valid = LoomEnvelopeV2Codec.encodeOuter(
      LoomOuterEnvelopeV2(
        packetId: 'packet-mutation-0001',
        routingHint: LoomRoutingHintV2(
          scope: LoomRoutingScopeV2.globalRelay,
          mailboxToken: Uint8List.fromList(List<int>.generate(16, (i) => i)),
        ),
        expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
        priority: LoomPriorityClassV2.urgent,
        initialHopLimit: 6,
        forwardingState: const LoomForwardingStateV2(
          hopsUsed: 0,
          copiesRemaining: 8,
        ),
        encryptedPayload: Uint8List.fromList(List<int>.generate(128, (i) => i)),
      ),
    );
    final random = Random(0x4e555632);

    for (var iteration = 0; iteration < 2000; iteration++) {
      final mutated = Uint8List.fromList(valid);
      final changes = 1 + random.nextInt(6);
      for (var change = 0; change < changes; change++) {
        final index = random.nextInt(mutated.length);
        mutated[index] ^= 1 << random.nextInt(8);
      }
      if (random.nextInt(8) == 0 && mutated.length > 2) {
        final cut = 1 + random.nextInt(mutated.length - 1);
        _decodeOrReject(Uint8List.sublistView(mutated, 0, cut), iteration);
      } else {
        _decodeOrReject(mutated, iteration);
      }
    }
  });

  test('oversized and hostile varint inputs fail closed', () {
    expect(
      () => LoomEnvelopeV2Codec.decodeOuter(Uint8List(2 * 1024 * 1024)),
      throwsFormatException,
    );
    expect(
      () => LoomEnvelopeV2Codec.decodeOuter(
        Uint8List.fromList(List<int>.filled(32, 0x80)),
      ),
      throwsFormatException,
    );
  });
}

void _decodeOrReject(Uint8List bytes, int iteration) {
  try {
    final decoded = LoomEnvelopeV2Codec.decodeOuter(bytes);
    decoded.validate();
  } on FormatException {
    return;
  } catch (error, stackTrace) {
    fail(
      'mutation $iteration escaped the bounded parser contract with '
      '$error\n$stackTrace',
    );
  }
}
