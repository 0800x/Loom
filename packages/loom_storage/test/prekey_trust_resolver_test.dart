import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  late LoomSecurityStore store;
  const accountId = 'account-v2-0001';
  const identityId = 'identity-v1-0001';
  const deviceId = 'device-0001';
  final now = DateTime.utc(2026, 9, 5, 20);

  LoomDeviceKeyBundle bundle({String fingerprint = 'AA BB CC DD'}) =>
      LoomDeviceKeyBundle(
        bundleVersion: 1,
        identityId: identityId,
        deviceId: deviceId,
        deviceName: 'Test device',
        signingPublicKey: base64Encode(List<int>.generate(32, (i) => i + 1)),
        agreementPublicKey: base64Encode(
          List<int>.generate(32, (i) => 255 - i),
        ),
        createdAt: now.subtract(const Duration(days: 1)),
        capabilities: const <String>['signing-ed25519'],
        fingerprint: fingerprint,
        deviceSignature: base64Encode(List<int>.filled(64, 1)),
        identitySignature: base64Encode(List<int>.filled(64, 2)),
      );

  LoomSecurityStoreDeviceSigningKeyResolver resolver() =>
      LoomSecurityStoreDeviceSigningKeyResolver(
        securityStore: store,
        resolveIdentityId: (requestedAccountId) async =>
            requestedAccountId == accountId ? identityId : null,
      );

  setUp(() {
    store = LoomSecurityStore.openInMemory();
  });

  tearDown(() {
    store.close();
  });

  test('returns signing key only after local verification', () async {
    final observed = bundle();
    expect(
      store.observeDevice(observed, observedAt: now),
      LoomDeviceTrustState.unknown,
    );
    expect(
      await resolver().resolveAuthorizedSigningKey(
        accountId: accountId,
        deviceId: deviceId,
        deviceKeyVersion: 1,
        now: now,
      ),
      isNull,
    );

    store.markVerified(
      identityId: identityId,
      deviceId: deviceId,
      expectedFingerprint: observed.fingerprint,
      verifiedAt: now,
    );
    final resolved = await resolver().resolveAuthorizedSigningKey(
      accountId: accountId,
      deviceId: deviceId,
      deviceKeyVersion: 1,
      now: now,
    );
    expect(resolved, isNotNull);
    expect(resolved!.accountId, accountId);
    expect(resolved.deviceId, deviceId);
    expect(resolved.deviceKeyVersion, 1);
    expect(
      resolved.ed25519PublicKey,
      orderedEquals(List<int>.generate(32, (i) => i + 1)),
    );
  });

  test('revocation is sticky and prevents prekey trust resolution', () async {
    final observed = bundle();
    store.observeDevice(observed, observedAt: now);
    store.markVerified(
      identityId: identityId,
      deviceId: deviceId,
      expectedFingerprint: observed.fingerprint,
      verifiedAt: now,
    );
    store.markRevoked(identityId: identityId, deviceId: deviceId);

    expect(
      await resolver().resolveAuthorizedSigningKey(
        accountId: accountId,
        deviceId: deviceId,
        deviceKeyVersion: 1,
        now: now,
      ),
      isNull,
    );

    store.observeDevice(
      observed,
      observedAt: now.add(const Duration(minutes: 1)),
    );
    expect(
      await resolver().resolveAuthorizedSigningKey(
        accountId: accountId,
        deviceId: deviceId,
        deviceKeyVersion: 1,
        now: now.add(const Duration(minutes: 1)),
      ),
      isNull,
    );
  });

  test(
    'fails closed for unmapped account and unsupported key version',
    () async {
      final observed = bundle();
      store.observeDevice(observed, observedAt: now);
      store.markVerified(
        identityId: identityId,
        deviceId: deviceId,
        expectedFingerprint: observed.fingerprint,
        verifiedAt: now,
      );

      expect(
        await resolver().resolveAuthorizedSigningKey(
          accountId: 'other-account',
          deviceId: deviceId,
          deviceKeyVersion: 1,
          now: now,
        ),
        isNull,
      );
      expect(
        await resolver().resolveAuthorizedSigningKey(
          accountId: accountId,
          deviceId: deviceId,
          deviceKeyVersion: 2,
          now: now,
        ),
        isNull,
      );
    },
  );
}
