import 'package:loom_calls/loom_calls.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('persists answered call timestamps and duration', () {
    final store = LoomCallHistoryStore.openInMemory();
    addTearDown(store.close);
    final started = DateTime.utc(2026, 9, 5, 10);
    final answered = started.add(const Duration(seconds: 4));
    final ended = answered.add(const Duration(minutes: 6, seconds: 12));

    store.upsert(
      LoomCallHistoryEntry(
        callId: 'call-answered',
        conversationId: 'conv-a',
        peerIdentityId: 'chn:peer-a',
        peerAddress: '@alice:node.example',
        peerDisplayName: 'Alice',
        kind: LoomCallKind.video,
        direction: LoomCallDirection.outgoing,
        outcome: LoomCallHistoryOutcome.answered,
        startedAt: started,
        answeredAt: answered,
        endedAt: ended,
        endReason: LoomCallEndReason.remoteHangup,
      ),
    );

    final restored = store.get('call-answered');
    expect(restored, isNotNull);
    expect(restored!.kind, LoomCallKind.video);
    expect(restored.direction, LoomCallDirection.outgoing);
    expect(restored.outcome, LoomCallHistoryOutcome.answered);
    expect(restored.duration, const Duration(minutes: 6, seconds: 12));
    expect(restored.endReason, LoomCallEndReason.remoteHangup);
  });

  test('missed filter returns only missed incoming calls', () {
    final store = LoomCallHistoryStore.openInMemory();
    addTearDown(store.close);
    final now = DateTime.utc(2026, 9, 5, 10);

    store.upsert(
      LoomCallHistoryEntry(
        callId: 'missed',
        conversationId: 'conv-a',
        peerIdentityId: 'chn:peer-a',
        peerAddress: '@alice:node.example',
        peerDisplayName: 'Alice',
        kind: LoomCallKind.audio,
        direction: LoomCallDirection.incoming,
        outcome: LoomCallHistoryOutcome.missed,
        startedAt: now,
        endedAt: now.add(const Duration(seconds: 45)),
        endReason: LoomCallEndReason.timeout,
      ),
    );
    store.upsert(
      LoomCallHistoryEntry(
        callId: 'answered',
        conversationId: 'conv-b',
        peerIdentityId: 'chn:peer-b',
        peerAddress: '@bob:node.example',
        peerDisplayName: 'Bob',
        kind: LoomCallKind.audio,
        direction: LoomCallDirection.incoming,
        outcome: LoomCallHistoryOutcome.answered,
        startedAt: now.add(const Duration(minutes: 1)),
        answeredAt: now.add(const Duration(minutes: 1, seconds: 2)),
        endedAt: now.add(const Duration(minutes: 2)),
        endReason: LoomCallEndReason.localHangup,
      ),
    );

    final missed = store.list(missedOnly: true);
    expect(missed, hasLength(1));
    expect(missed.single.callId, 'missed');
    expect(missed.single.missed, isTrue);
  });

  test('upsert moves a started call to its final outcome', () {
    final store = LoomCallHistoryStore.openInMemory();
    addTearDown(store.close);
    final started = DateTime.utc(2026, 9, 5, 10);

    store.upsert(
      LoomCallHistoryEntry(
        callId: 'call-transition',
        conversationId: 'conv-a',
        peerIdentityId: 'chn:peer-a',
        peerAddress: '@alice:node.example',
        peerDisplayName: 'Alice',
        kind: LoomCallKind.audio,
        direction: LoomCallDirection.outgoing,
        outcome: LoomCallHistoryOutcome.canceled,
        startedAt: started,
      ),
    );
    store.upsert(
      LoomCallHistoryEntry(
        callId: 'call-transition',
        conversationId: 'conv-a',
        peerIdentityId: 'chn:peer-a',
        peerAddress: '@alice:node.example',
        peerDisplayName: 'Alice',
        kind: LoomCallKind.audio,
        direction: LoomCallDirection.outgoing,
        outcome: LoomCallHistoryOutcome.busy,
        startedAt: started,
        endedAt: started.add(const Duration(seconds: 2)),
        endReason: LoomCallEndReason.busy,
      ),
    );

    expect(store.list(), hasLength(1));
    expect(store.get('call-transition')!.outcome, LoomCallHistoryOutcome.busy);
  });
}
