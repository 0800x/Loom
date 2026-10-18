import 'dart:convert';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'verification validates device and identity binding signatures',
    () async {
      final ed25519 = Ed25519();
      final identityPair = await ed25519.newKeyPair();
      final devicePair = await ed25519.newKeyPair();
      final identityPublic = await identityPair.extractPublicKey();
      final devicePublic = await devicePair.extractPublicKey();
      final agreementPublic = await X25519().newKeyPair().then(
        (pair) => pair.extractPublicKey(),
      );
      final identity = LoomIdentityPublic(
        identityId: 'chn:test-identity',
        publicKey: base64Encode(identityPublic.bytes),
        fingerprint: 'TEST IDENTITY',
        createdAt: DateTime.utc(2026, 9, 1),
      );
      final unsigned = LoomDeviceKeyBundle.unsigned(
        identityId: identity.identityId,
        deviceId: 'device-1',
        deviceName: 'Test Device',
        signingPublicKey: base64Encode(devicePublic.bytes),
        agreementPublicKey: base64Encode(agreementPublic.bytes),
        createdAt: DateTime.utc(2026, 9, 1),
        capabilities: const <String>['signing-ed25519', 'agreement-x25519'],
      );
      final payload = unsigned.canonicalBindingBytes();
      final deviceSignature = await ed25519.sign(payload, keyPair: devicePair);
      final identitySignature = await ed25519.sign(
        payload,
        keyPair: identityPair,
      );
      final bundle = unsigned.copyWith(
        fingerprint: 'TEST DEVICE',
        deviceSignature: base64Encode(deviceSignature.bytes),
        identitySignature: base64Encode(identitySignature.bytes),
      );
      final service = LoomVerificationService();
      expect(await service.verifyDeviceSelfSignature(bundle), isTrue);
      expect(
        await service.verifyIdentityBinding(bundle: bundle, identity: identity),
        isTrue,
      );
    },
  );

  test('verification comparison is order-independent', () async {
    final a = LoomIdentityPublic(
      identityId: 'chn:a',
      publicKey: 'a',
      fingerprint: 'A',
      createdAt: DateTime.utc(2026),
    );
    final b = LoomIdentityPublic(
      identityId: 'chn:b',
      publicKey: 'b',
      fingerprint: 'B',
      createdAt: DateTime.utc(2026),
    );
    LoomDeviceKeyBundle device(String identity, String id) =>
        LoomDeviceKeyBundle(
          bundleVersion: 1,
          identityId: identity,
          deviceId: id,
          deviceName: id,
          signingPublicKey: 'sign-$id',
          agreementPublicKey: 'agree-$id',
          createdAt: DateTime.utc(2026),
          capabilities: const <String>[],
          fingerprint: 'fp-$id',
          deviceSignature: 'sig-$id',
          identitySignature: 'identity-sig-$id',
        );
    final service = LoomVerificationService();
    final first = await service.compare(
      localIdentity: a,
      localDevice: device('chn:a', 'a1'),
      remoteIdentity: b,
      remoteDevice: device('chn:b', 'b1'),
    );
    final second = await service.compare(
      localIdentity: b,
      localDevice: device('chn:b', 'b1'),
      remoteIdentity: a,
      remoteDevice: device('chn:a', 'a1'),
    );
    expect(first.displayGroups, second.displayGroups);
    expect(first.qrPayload, second.qrPayload);
  });

  test('legacy adapter rejects a different protocol version', () {
    final adapter = LoomLegacyDeviceEnvelopeAdapter();
    expect(
      () => adapter.inspect(
        jsonEncode(<String, Object?>{
          'protocolVersion': 'something-else',
          'ciphertext': 'ciphertext',
          'nonce': 'nonce',
          'wrappedKeys': <String, String>{'device': 'key'},
        }),
      ),
      throwsFormatException,
    );
  });
}
