import 'dart:typed_data';

import 'package:loom_identity/loom_identity.dart';
import 'package:test/test.dart';

void main() {
  test(
    'AccountId and DeviceId are random opaque identifiers independent of keys',
    () {
      final accountA = LoomAccountId.generate();
      final accountB = LoomAccountId.generate();
      final device = LoomDeviceId.generate();
      expect(accountA, isNot(accountB));
      expect(LoomAccountId.parse(accountA.value), accountA);
      expect(LoomDeviceId.parse(device.value), device);
      expect(accountA.value, startsWith('acc2_'));
      expect(device.value, startsWith('dev2_'));
    },
  );

  test(
    'directory verifier checks every account-signed object and snapshot',
    () async {
      final now = DateTime.utc(2026, 9, 6);
      final account = LoomAccountId.generate();
      final device = LoomDeviceId.generate();
      final authorization = LoomDeviceAuthorizationV2(
        accountId: account,
        deviceId: device,
        deviceKeyVersion: 3,
        signingPublicKey: Uint8List(32),
        agreementPublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
        issuedAt: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(days: 30)),
        capabilities: const <String>['messaging.v2', 'nearby.ble'],
        accountSignature: Uint8List.fromList(List<int>.filled(64, 7)),
      );
      final revocation = LoomDeviceRevocationV2(
        accountId: account,
        deviceId: LoomDeviceId.generate(),
        revokedThroughKeyVersion: 2,
        revocationSequence: 1,
        revokedAt: now,
        reasonCode: 'rotated',
        accountSignature: Uint8List.fromList(List<int>.filled(64, 8)),
      );
      final snapshot = LoomDeviceDirectorySnapshotV2(
        accountId: account,
        directoryRevision: 9,
        accountKeyVersion: 2,
        generatedAt: now,
        authorizations: <LoomDeviceAuthorizationV2>[authorization],
        revocations: <LoomDeviceRevocationV2>[revocation],
        accountSignature: Uint8List.fromList(List<int>.filled(64, 9)),
      );
      final verifier = _RecordingVerifier();
      final verified = await LoomDeviceDirectoryVerifierV2(
        signatureVerifier: verifier,
      ).verify(snapshot, now: now);
      expect(verified.snapshot.directoryRevision, 9);
      expect(verifier.calls, 3);
    },
  );

  test('snapshot rejects duplicate device key authorization', () {
    final now = DateTime.utc(2026, 9, 6);
    final account = LoomAccountId.generate();
    final device = LoomDeviceId.generate();
    LoomDeviceAuthorizationV2 build() => LoomDeviceAuthorizationV2(
      accountId: account,
      deviceId: device,
      deviceKeyVersion: 1,
      signingPublicKey: Uint8List(32),
      agreementPublicKey: Uint8List(32),
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 1)),
      capabilities: const <String>[],
      accountSignature: Uint8List(64),
    );
    expect(
      () => LoomDeviceDirectorySnapshotV2(
        accountId: account,
        directoryRevision: 1,
        accountKeyVersion: 1,
        generatedAt: now,
        authorizations: <LoomDeviceAuthorizationV2>[build(), build()],
        revocations: const <LoomDeviceRevocationV2>[],
        accountSignature: Uint8List(64),
      ),
      throwsFormatException,
    );
  });
}

final class _RecordingVerifier implements LoomAccountSignatureVerifierV2 {
  int calls = 0;

  @override
  Future<bool> verifyAccountSignature({
    required LoomAccountId accountId,
    required int accountKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  }) async {
    calls += 1;
    return canonicalPayload.isNotEmpty && signature.length == 64;
  }
}
