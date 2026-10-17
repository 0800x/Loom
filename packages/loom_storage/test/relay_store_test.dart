import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  test('relay store deduplicates and prunes expired bundles', () {
    final store = LoomRelayStore.openInMemory();
    addTearDown(store.close);
    final now = DateTime.utc(2026, 9, 1, 12);
    final bundle = LoomStoredRelayBundle(
      bundleId: 'bundle-1',
      recipientTag: 'recipient-tag-123456',
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
      hopCount: 0,
      maxHops: 3,
      payloadJson: const <String, Object?>{'kind': 'relay.bundle.v1'},
      sizeBytes: 32,
    );
    expect(store.putIfAbsent(bundle, now: now), isTrue);
    expect(store.putIfAbsent(bundle, now: now), isFalse);
    expect(
      store.findByRecipientTags({bundle.recipientTag}, now: now),
      hasLength(1),
    );
    expect(store.pruneExpired(now.add(const Duration(hours: 2))), 1);
  });
}
