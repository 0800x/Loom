import 'package:loom_calls/src/incoming_ice_buffer.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final created = DateTime.utc(2026, 9, 27);
  LoomCallSignal signal(String kind,
          {String call = 'call', String peer = 'peer', int sequence = 1}) =>
      LoomCallSignal(
        callId: call,
        conversationId: 'conv',
        senderIdentityId: peer,
        targetIdentityId: 'self',
        kind: kind,
        sequence: sequence,
        createdAt: created,
        mediaKind: LoomCallKind.audio,
        sdp: kind == 'call.offer' ? 'v=0\r\n' : null,
        candidate: kind == 'call.ice'
            ? 'candidate:$sequence 1 UDP 1 192.0.2.1 5000 typ host'
            : null,
        sdpMid: '0',
        sdpMLineIndex: 0,
      );

  test(
      'candidates gathered while ringing survive until answer and are consumed once',
      () {
    final buffer = LoomIncomingIceBuffer('self', now: () => created);
    buffer.observe(signal('call.ice')); // no verified offer yet
    buffer.observe(signal('call.offer'));
    buffer.observe(signal('call.ice', sequence: 2));
    buffer.observe(signal('call.ice', sequence: 2)); // replay
    buffer.observe(signal('call.ice', sequence: 3, peer: 'other'));
    buffer.observe(signal('call.ice', sequence: 4));
    expect(buffer.take('call', 'peer').map((s) => s.sequence), [2, 4]);
    expect(buffer.take('call', 'peer'), isEmpty);
  });

  test('expired, cancelled and unrelated calls cannot supply candidates', () {
    var now = created;
    final buffer = LoomIncomingIceBuffer('self', now: () => now);
    buffer.observe(signal('call.offer'));
    buffer.observe(signal('call.ice'));
    now = created.add(const Duration(seconds: 46));
    expect(buffer.take('call', 'peer'), isEmpty);
    now = created;
    buffer.observe(signal('call.offer'));
    buffer.observe(signal('call.ice'));
    buffer.observe(signal('call.end'));
    expect(buffer.take('call', 'peer'), isEmpty);
    buffer.observe(signal('call.offer'));
    buffer.observe(signal('call.ice'));
    expect(buffer.take('call', 'other'), isEmpty);
  });

  test('retained call and candidate counts are bounded', () {
    final buffer = LoomIncomingIceBuffer('self', now: () => created);
    for (var n = 0; n < 5; n++) {
      buffer.observe(signal('call.offer', call: '$n'));
      for (var i = 0; i < 300; i++) {
        buffer.observe(signal('call.ice', call: '$n', sequence: i));
      }
    }
    expect(buffer.take('0', 'peer'), isEmpty);
    expect(buffer.take('4', 'peer'), hasLength(256));
    buffer.clear();
    expect(buffer.take('3', 'peer'), isEmpty);
  });
}
