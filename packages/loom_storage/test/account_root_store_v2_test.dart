import 'dart:typed_data';

import 'package:loom_identity/loom_identity.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  test('trusted root pin is idempotent and exact version resolves', () async {
    final store = LoomAccountRootStoreV2.openInMemory();
    addTearDown(store.close);
    final now = DateTime.utc(2026, 9, 6, 8);
    final root = LoomTrustedAccountRootKeyV2(
      accountId: LoomAccountId.generate(),
      accountKeyVersion: 2,
      ed25519PublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      validFrom: now.subtract(const Duration(hours: 1)),
      validUntil: now.add(const Duration(days: 90)),
    );

    store.pinRoot(root, now: now);
    store.pinRoot(root, now: now.add(const Duration(minutes: 1)));
    final resolved = await store.resolveTrustedAccountRoot(
      accountId: root.accountId,
      accountKeyVersion: 2,
      now: now,
    );
    expect(resolved, isNotNull);
    expect(resolved!.ed25519PublicKey, orderedEquals(root.ed25519PublicKey));
    expect(
      await store.resolveTrustedAccountRoot(
        accountId: root.accountId,
        accountKeyVersion: 1,
        now: now,
      ),
      isNull,
    );
  });

  test('same account root version cannot be rebound to different key', () {
    final store = LoomAccountRootStoreV2.openInMemory();
    addTearDown(store.close);
    final now = DateTime.utc(2026, 9, 6, 8);
    final accountId = LoomAccountId.generate();
    store.pinRoot(
      LoomTrustedAccountRootKeyV2(
        accountId: accountId,
        accountKeyVersion: 1,
        ed25519PublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
        validFrom: now,
      ),
      now: now,
    );

    expect(
      () => store.pinRoot(
        LoomTrustedAccountRootKeyV2(
          accountId: accountId,
          accountKeyVersion: 1,
          ed25519PublicKey: Uint8List.fromList(List<int>.filled(32, 2)),
          validFrom: now,
        ),
        now: now,
      ),
      throwsStateError,
    );
  });
}
