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
void main() {
  test('state CAS and exact ciphertext outbox commit together; failed stage rolls back', () {
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
    expect(() => store.stage(2, sealed(3), pending('two')), throwsStateError);
    expect(store.version, 2);
    expect(store.state!.generation, 2);
    expect(() => store.saveState(1, sealed(9)), throwsStateError);
    expect(store.state!.generation, 2);
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
}
