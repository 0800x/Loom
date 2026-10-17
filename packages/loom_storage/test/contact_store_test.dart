import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'contact persistence keeps resolved identity and canonical routing data',
    () {
      final store = LoomContactStore.openInMemory();
      addTearDown(store.close);
      final createdAt = DateTime.utc(2026, 9, 4, 12);
      final first = LoomContact(
        identityId: 'chn:identity-b',
        username: 'bob',
        displayName: 'Bob',
        canonicalAddress: '@bob:node-b.example',
        homeNode: 'node-b.example',
        securityState: LoomContactSecurityState.resolved,
        createdAt: createdAt,
        updatedAt: createdAt,
        lastResolvedAt: createdAt,
      );

      store.upsert(first);
      final persisted = store.findByAddress('@BOB:NODE-B.EXAMPLE');
      expect(persisted, isNotNull);
      expect(persisted!.identityId, 'chn:identity-b');
      expect(persisted.accountId, isNull);
      expect(persisted.homeNode, 'node-b.example');
      expect(persisted.securityState, LoomContactSecurityState.resolved);

      final refreshedAt = createdAt.add(const Duration(hours: 1));
      store.upsert(
        first.copyWith(
          displayName: 'Bob B',
          securityState: LoomContactSecurityState.verified,
          updatedAt: refreshedAt,
          lastResolvedAt: refreshedAt,
        ),
      );
      final updated = store.list().single;
      expect(updated.displayName, 'Bob B');
      expect(updated.createdAt, createdAt);
      expect(updated.updatedAt, refreshedAt);
    },
  );
}
