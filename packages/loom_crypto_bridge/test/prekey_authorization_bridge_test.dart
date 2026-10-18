import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'authorized Ed25519 device signature verifies prekey statement',
    () async {
      final ed25519 = Ed25519();
      final pair = await ed25519.newKeyPair();
      addTearDown(pair.destroy);
      final publicKey = await pair.extractPublicKey();
      final providerBundle = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final now = DateTime.utc(2026, 9, 5, 12);
      final statement = LoomPrekeyAuthorizationStatement(
        accountId: 'account-001',
        deviceId: 'device-001',
        deviceKeyVersion: 3,
        providerProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
        prekeyId: 'prekey-00000001',
        keyKind: LoomAuthorizedPrekeyKind.fallback,
        providerBundle: providerBundle,
        notBefore: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(days: 7)),
      );
      final signature = await ed25519.sign(
        statement.canonicalBytes(),
        keyPair: pair,
      );
      final verifier = LoomPrekeyAuthorizationVerifierV1(
        deviceSignatureVerifier: LoomDevicePrekeySignatureVerifier(
          keyResolver: _Resolver(
            LoomAuthorizedDeviceSigningKey(
              accountId: 'account-001',
              deviceId: 'device-001',
              deviceKeyVersion: 3,
              ed25519PublicKey: Uint8List.fromList(publicKey.bytes),
            ),
          ),
        ),
      );
      final verified = await verifier.verify(
        authorization: LoomAuthorizedPrekeyBundle(
          statement: statement,
          providerBundle: providerBundle,
          deviceSignature: Uint8List.fromList(signature.bytes),
        ),
        now: now,
        expectedProviderProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
      );
      expect(verified.remoteDeviceId, 'device-001');
      expect(verified.remoteDeviceKeyVersion, 3);
      expect(verified.keyKind, LoomAuthorizedPrekeyKind.fallback);
    },
  );

  test('revoked resolver result rejects otherwise-valid signature', () async {
    final ed25519 = Ed25519();
    final pair = await ed25519.newKeyPair();
    addTearDown(pair.destroy);
    final providerBundle = Uint8List.fromList(<int>[5, 6, 7]);
    final now = DateTime.utc(2026, 9, 5, 12);
    final statement = LoomPrekeyAuthorizationStatement(
      accountId: 'account-002',
      deviceId: 'device-002',
      deviceKeyVersion: 1,
      providerProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
      prekeyId: 'prekey-00000002',
      keyKind: LoomAuthorizedPrekeyKind.oneTime,
      providerBundle: providerBundle,
      notBefore: now.subtract(const Duration(minutes: 1)),
      expiresAt: now.add(const Duration(days: 7)),
    );
    final signature = await ed25519.sign(
      statement.canonicalBytes(),
      keyPair: pair,
    );
    final verifier = LoomPrekeyAuthorizationVerifierV1(
      deviceSignatureVerifier: LoomDevicePrekeySignatureVerifier(
        keyResolver: const _Resolver(null),
      ),
    );
    await expectLater(
      verifier.verify(
        authorization: LoomAuthorizedPrekeyBundle(
          statement: statement,
          providerBundle: providerBundle,
          deviceSignature: Uint8List.fromList(signature.bytes),
        ),
        now: now,
        expectedProviderProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
      ),
      throwsFormatException,
    );
  });
}

final class _Resolver implements LoomAuthorizedDeviceSigningKeyResolver {
  const _Resolver(this.key);

  final LoomAuthorizedDeviceSigningKey? key;

  @override
  Future<LoomAuthorizedDeviceSigningKey?> resolveAuthorizedSigningKey({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required DateTime now,
  }) async =>
      key;
}
