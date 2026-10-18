import 'dart:typed_data';

import 'package:loom_identity/loom_identity.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 6);

  test(
    'verified directory persists latest key and rejects revision rollback',
    () async {
      final store = LoomDeviceDirectoryStoreV2.openInMemory();
      addTearDown(store.close);
      final account = LoomAccountId.generate();
      final device = LoomDeviceId.generate();

      await _apply(
        store,
        _snapshot(account, device, revision: 1, keyVersion: 1, now: now),
        now,
      );
      expect(
        store.resolveDevice(
          accountId: account.value,
          deviceId: device.value,
          deviceKeyVersion: 1,
          now: now,
        ),
        isNotNull,
      );

      await _apply(
        store,
        _snapshot(account, device, revision: 2, keyVersion: 2, now: now),
        now,
      );
      expect(
        store.resolveDevice(
          accountId: account.value,
          deviceId: device.value,
          deviceKeyVersion: 1,
          now: now,
        ),
        isNull,
      );
      expect(
        store.resolveDevice(
          accountId: account.value,
          deviceId: device.value,
          deviceKeyVersion: 2,
          now: now,
        ),
        isNotNull,
      );

      final oldVerified = await (const LoomDeviceDirectoryVerifierV2(
        signatureVerifier: _AllowAllVerifier(),
      )).verify(
        _snapshot(account, device, revision: 1, keyVersion: 1, now: now),
        now: now,
      );
      expect(() => store.applyVerifiedSnapshot(oldVerified), throwsStateError);
    },
  );

  test(
    'revocation is sticky but a later higher key version can be authorized',
    () async {
      final store = LoomDeviceDirectoryStoreV2.openInMemory();
      addTearDown(store.close);
      final account = LoomAccountId.generate();
      final device = LoomDeviceId.generate();

      await _apply(
        store,
        _snapshot(
          account,
          device,
          revision: 1,
          keyVersion: 1,
          now: now,
          revokeThrough: 1,
        ),
        now,
      );
      expect(
        await store.resolveAuthorizedSigningKey(
          accountId: account.value,
          deviceId: device.value,
          deviceKeyVersion: 1,
          now: now,
        ),
        isNull,
      );

      await _apply(
        store,
        _snapshot(account, device, revision: 2, keyVersion: 2, now: now),
        now,
      );
      expect(
        await store.resolveAuthorizedSigningKey(
          accountId: account.value,
          deviceId: device.value,
          deviceKeyVersion: 2,
          now: now,
        ),
        isNotNull,
      );
      expect(
        await store.resolveAuthorizedSigningKey(
          accountId: account.value,
          deviceId: device.value,
          deviceKeyVersion: 1,
          now: now,
        ),
        isNull,
      );
    },
  );

  test('same revision is idempotent only for exact snapshot bytes', () async {
    final store = LoomDeviceDirectoryStoreV2.openInMemory();
    addTearDown(store.close);
    final account = LoomAccountId.generate();
    final device = LoomDeviceId.generate();
    final snapshot = _snapshot(
      account,
      device,
      revision: 1,
      keyVersion: 1,
      now: now,
    );
    await _apply(store, snapshot, now);
    await _apply(store, snapshot, now);

    final changed = _snapshot(
      account,
      device,
      revision: 1,
      keyVersion: 1,
      now: now,
      capabilities: const <String>['messaging.v2', 'different'],
    );
    final verified = await (const LoomDeviceDirectoryVerifierV2(
      signatureVerifier: _AllowAllVerifier(),
    )).verify(changed, now: now);
    expect(() => store.applyVerifiedSnapshot(verified), throwsStateError);
  });
}

Future<void> _apply(
  LoomDeviceDirectoryStoreV2 store,
  LoomDeviceDirectorySnapshotV2 snapshot,
  DateTime now,
) async {
  final verified = await (const LoomDeviceDirectoryVerifierV2(
    signatureVerifier: _AllowAllVerifier(),
  )).verify(snapshot, now: now);
  store.applyVerifiedSnapshot(verified);
}

LoomDeviceDirectorySnapshotV2 _snapshot(
  LoomAccountId account,
  LoomDeviceId device, {
  required int revision,
  required int keyVersion,
  required DateTime now,
  int? revokeThrough,
  List<String> capabilities = const <String>['messaging.v2'],
}) {
  final authorization = LoomDeviceAuthorizationV2(
    accountId: account,
    deviceId: device,
    deviceKeyVersion: keyVersion,
    signingPublicKey: Uint8List.fromList(List<int>.filled(32, keyVersion)),
    agreementPublicKey: Uint8List.fromList(
      List<int>.filled(32, keyVersion + 1),
    ),
    issuedAt: now.subtract(const Duration(minutes: 1)),
    expiresAt: now.add(const Duration(days: 30)),
    capabilities: capabilities,
    accountSignature: Uint8List.fromList(List<int>.filled(64, 3)),
  );
  return LoomDeviceDirectorySnapshotV2(
    accountId: account,
    directoryRevision: revision,
    accountKeyVersion: 1,
    generatedAt: now,
    authorizations: <LoomDeviceAuthorizationV2>[authorization],
    revocations:
        revokeThrough == null
            ? const <LoomDeviceRevocationV2>[]
            : <LoomDeviceRevocationV2>[
              LoomDeviceRevocationV2(
                accountId: account,
                deviceId: device,
                revokedThroughKeyVersion: revokeThrough,
                revocationSequence: revision,
                revokedAt: now,
                reasonCode: 'revoked',
                accountSignature: Uint8List.fromList(List<int>.filled(64, 4)),
              ),
            ],
    accountSignature: Uint8List.fromList(List<int>.filled(64, 5)),
  );
}

final class _AllowAllVerifier implements LoomAccountSignatureVerifierV2 {
  const _AllowAllVerifier();

  @override
  Future<bool> verifyAccountSignature({
    required LoomAccountId accountId,
    required int accountKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  }) async => signature.length == 64 && canonicalPayload.isNotEmpty;
}
