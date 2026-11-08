import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

LoomMlsSealedState sealed(int generation) =>
    LoomMlsSealedState(generation: generation, bytes: [1, 2, generation]);
LoomGroupOutbox pending(String id, {bool commit = false}) => LoomGroupOutbox(
  id: id,
  groupId: 'group',
  path: commit
      ? '/api/v1/groups/group/commits'
      : '/api/v1/groups/group/messages',
  body: {'operationId': id, 'ciphertext': 'opaque'},
  checkpoint: commit ? sealed(1) : null,
  localPayload: 'encrypted-local-history',
);
const memberJson = {
  'accountId': 'acc_owner',
  'deviceId': 'dev_owner',
  'identityId': 'id_owner',
  'role': 'owner',
  'mlsSignatureKey': 'key',
  'mlsSignature': 'signature',
};
void main() {
  test('state CAS commits with each queued message; a pending commit blocks new staging', () {
    final store = LoomGroupStore.openInMemory();
    addTearDown(store.close);
    store.saveState(0, sealed(1));
    store.stage(1, sealed(2), pending('one'));
    expect(store.version, 2);
    expect(store.state!.generation, 2);
    expect(store.outbox.single.body, {
      'operationId': 'one',
      'ciphertext': 'opaque',
    });
    // Application messages may queue up while the device is offline.
    store.stage(2, sealed(3), pending('two'));
    expect(store.version, 3);
    expect(store.state!.generation, 3);
    expect(store.outbox.length, 2);
    // The state CAS still rejects stale writers.
    expect(() => store.saveState(1, sealed(9)), throwsStateError);
    expect(store.state!.generation, 3);
    store.acknowledge('one', sequence: 4);
    store.acknowledge('two', sequence: 5);
    // A commit may be staged on top of queued messages, but while it is
    // pending nothing else may be staged: its acknowledgement rewrites the
    // sealed state.
    store.stage(3, sealed(4), pending('commit', commit: true));
    expect(store.outbox.single.checkpoint, isNotNull);
    expect(() => store.stage(4, sealed(5), pending('three')), throwsStateError);
    expect(store.version, 4);
  });
  test('acknowledgement records self echo and encrypted history in the same transaction', () {
    final store = LoomGroupStore.openInMemory();
    addTearDown(store.close);
    store.stage(0, sealed(1), pending('one'));
    store.acknowledge('one', sequence: 4);
    expect(store.outbox, isEmpty);
    expect(store.isOwnOperation('group', 4, 'one'), isTrue);
    expect(store.history('group').single.payload, 'encrypted-local-history');
    expect(() => store.isOwnOperation('group', 4, 'altered'), throwsStateError);
  });
  test('an authoritative rejected commit restores checkpoint with a new database version', () {
    final store = LoomGroupStore.openInMemory();
    addTearDown(store.close);
    store.saveState(0, sealed(1));
    store.stage(1, sealed(2), pending('commit', commit: true));
    store.rejectCommit('commit', 2);
    expect(store.version, 3);
    expect(store.state!.generation, 1);
    expect(store.outbox, isEmpty);
  });
  test('a rejected old-epoch message retains advanced ratchet state and a retry draft', () {
    final store = LoomGroupStore.openInMemory();
    addTearDown(store.close);
    store.stage(0, sealed(1), pending('one'));
    store.rejectMessage('one');
    expect(store.state!.generation, 1);
    expect(store.failed('group').single.payload, 'encrypted-local-history');
    expect(store.outbox, isEmpty);
  });
  test('a quarantined inbox event advances the cursor without touching state', () {
    final store = LoomGroupStore.openInMemory();
    addTearDown(store.close);
    store.saveState(0, sealed(1));
    final group = LoomGroupState.fromJson({
      'id': 'group',
      'title': 'Friends',
      'epoch': 1,
      'revision': 1,
      'sequence': 2,
      'members': [memberJson],
    });
    store.acknowledgeEcho(group, 2);
    expect(store.quarantine('group', 5, 'Bad state: undecryptable'), isTrue);
    expect(store.cursor('group'), 5);
    expect(store.quarantineCount('group'), 1);
    expect(store.quarantined('group').single.sequence, 5);
    expect(store.quarantined('group').single.reason, 'Bad state: undecryptable');
    // Already-past events are a no-op, and unknown groups cannot be skipped.
    expect(store.quarantine('group', 3, 'late duplicate'), isTrue);
    expect(store.cursor('group'), 5);
    expect(store.quarantineCount('group'), 1);
    expect(store.quarantine('other', 1, 'unknown group'), isFalse);
    // The sealed state is untouched by quarantining.
    expect(store.state!.generation, 1);
  });
}
