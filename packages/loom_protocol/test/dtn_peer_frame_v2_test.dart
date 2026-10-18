import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('packet-transfer frame round-trips exact OuterEnvelope bytes', () {
    final outer = _outerWire('packet-peer-frame-0001');
    final frame = LoomDtnPacketTransferFrameV2(
      transmissionId: 'transmission-peer-frame-0001',
      outerEnvelopeBytes: outer,
    );

    final encoded = LoomDtnPeerFrameV2Codec.encode(frame);
    final decoded = LoomDtnPeerFrameV2Codec.decode(encoded);

    expect(decoded, isA<LoomDtnPacketTransferFrameV2>());
    final transfer = decoded as LoomDtnPacketTransferFrameV2;
    expect(transfer.transmissionId, frame.transmissionId);
    expect(transfer.outerEnvelopeBytes, outer);
    expect(transfer.destinationNodeDomain, isNull);
  });

  test('packet-transfer frame round-trips destination route sidecar', () {
    final frame = LoomDtnPacketTransferFrameV2(
      transmissionId: 'transmission-peer-frame-route-0001',
      outerEnvelopeBytes: _outerWire('packet-peer-frame-route-0001'),
      destinationNodeDomain: 'Relay.Example.',
    );

    final decoded = LoomDtnPeerFrameV2Codec.decode(
      LoomDtnPeerFrameV2Codec.encode(frame),
    ) as LoomDtnPacketTransferFrameV2;

    expect(decoded.destinationNodeDomain, 'relay.example');
    expect(decoded.packetId, 'packet-peer-frame-route-0001');
  });

  test('hop ACK frame round-trips and remains non-delivery metadata', () {
    final frame = LoomDtnHopAckFrameV2(
      transmissionId: 'transmission-peer-frame-0002',
      packetId: 'packet-peer-frame-0002',
      acceptedAt: DateTime.utc(2026, 9, 5, 12, 30),
      duplicate: true,
    );

    final decoded = LoomDtnPeerFrameV2Codec.decode(
      LoomDtnPeerFrameV2Codec.encode(frame),
    ) as LoomDtnHopAckFrameV2;

    expect(decoded.transmissionId, frame.transmissionId);
    expect(decoded.packetId, frame.packetId);
    expect(decoded.acceptedAt, frame.acceptedAt);
    expect(decoded.duplicate, isTrue);
  });

  test('unknown top-level field is rejected', () {
    final valid = LoomDtnPeerFrameV2Codec.encode(
      LoomDtnPacketTransferFrameV2(
        transmissionId: 'transmission-peer-frame-0003',
        outerEnvelopeBytes: _outerWire('packet-peer-frame-0003'),
      ),
    );
    final bytes = Uint8List.fromList(<int>[...valid, 0x20, 0x00]);
    expect(() => LoomDtnPeerFrameV2Codec.decode(bytes), throwsFormatException);
  });

  test('duplicate oneof bodies are rejected', () {
    final transferSubmessage = _transferSubmessage(
      'transmission-peer-frame-0004',
      _outerWire('packet-peer-frame-0004'),
    );
    final ackSubmessage = _ackSubmessage(
      transmissionId: 'transmission-peer-frame-0004',
      packetId: 'packet-peer-frame-0004',
      acceptedAtMs: DateTime.utc(2026, 9, 5, 12).millisecondsSinceEpoch,
      duplicate: false,
    );
    final bytes = Uint8List.fromList(<int>[
      0x08,
      0x02,
      ..._lengthField(2, transferSubmessage),
      ..._lengthField(3, ackSubmessage),
    ]);

    expect(() => LoomDtnPeerFrameV2Codec.decode(bytes), throwsFormatException);
  });

  test('unsupported peer-frame version is rejected', () {
    final transferSubmessage = _transferSubmessage(
      'transmission-peer-frame-0005',
      _outerWire('packet-peer-frame-0005'),
    );
    final bytes = Uint8List.fromList(<int>[
      0x08,
      0x03,
      ..._lengthField(2, transferSubmessage),
    ]);
    expect(() => LoomDtnPeerFrameV2Codec.decode(bytes), throwsFormatException);
  });

  test('invalid hop ACK boolean value is rejected', () {
    final ack = <int>[
      ..._lengthField(1, _utf8('transmission-peer-frame-0006')),
      ..._lengthField(2, _utf8('packet-peer-frame-0006')),
      ..._varintField(3, DateTime.utc(2026, 9, 5, 12).millisecondsSinceEpoch),
      ..._varintField(4, 2),
    ];
    final frame = Uint8List.fromList(<int>[
      0x08,
      0x02,
      ..._lengthField(3, ack),
    ]);
    expect(() => LoomDtnPeerFrameV2Codec.decode(frame), throwsFormatException);
  });

  test('raw ACK timestamp is bounded before DateTime construction', () {
    final ack = _ackSubmessage(
      transmissionId: 'transmission-peer-frame-0007',
      packetId: 'packet-peer-frame-0007',
      acceptedAtMs: DateTime.utc(2200).millisecondsSinceEpoch,
      duplicate: false,
    );
    final frame = Uint8List.fromList(<int>[
      0x08,
      0x02,
      ..._lengthField(3, ack),
    ]);
    expect(() => LoomDtnPeerFrameV2Codec.decode(frame), throwsFormatException);
  });

  test(
    'malformed embedded OuterEnvelope is rejected at peer-frame boundary',
    () {
      final transfer = _transferSubmessage(
        'transmission-peer-frame-0008',
        Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      final frame = Uint8List.fromList(<int>[
        0x08,
        0x02,
        ..._lengthField(2, transfer),
      ]);
      expect(
        () => LoomDtnPeerFrameV2Codec.decode(frame),
        throwsFormatException,
      );
    },
  );

  test('non-minimal protobuf varint is rejected', () {
    final bytes = Uint8List.fromList(<int>[0x08, 0x82, 0x00]);
    expect(() => LoomDtnPeerFrameV2Codec.decode(bytes), throwsFormatException);
  });
}

Uint8List _outerWire(String packetId) {
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 31)),
    ),
    expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: const LoomForwardingStateV2(
      hopsUsed: 1,
      copiesRemaining: 2,
    ),
    encryptedPayload: Uint8List.fromList(<int>[7, 8, 9, 10]),
  );
  return LoomEnvelopeV2Codec.encodeOuter(outer);
}

List<int> _transferSubmessage(String transmissionId, Uint8List outer) => <int>[
  ..._lengthField(1, _utf8(transmissionId)),
  ..._lengthField(2, outer),
];

List<int> _ackSubmessage({
  required String transmissionId,
  required String packetId,
  required int acceptedAtMs,
  required bool duplicate,
}) => <int>[
  ..._lengthField(1, _utf8(transmissionId)),
  ..._lengthField(2, _utf8(packetId)),
  ..._varintField(3, acceptedAtMs),
  ..._varintField(4, duplicate ? 1 : 0),
];

List<int> _lengthField(int fieldNumber, List<int> bytes) => <int>[
  ..._varint((fieldNumber << 3) | 2),
  ..._varint(bytes.length),
  ...bytes,
];

List<int> _varintField(int fieldNumber, int value) => <int>[
  ..._varint(fieldNumber << 3),
  ..._varint(value),
];

List<int> _varint(int value) {
  final result = <int>[];
  var remaining = value;
  while (remaining >= 0x80) {
    result.add((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  result.add(remaining);
  return result;
}

List<int> _utf8(String value) => value.codeUnits;
