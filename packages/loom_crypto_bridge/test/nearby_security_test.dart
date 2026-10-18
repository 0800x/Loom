import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryDeviceSecurity implements LoomDeviceSecurityCore {
  _MemoryDeviceSecurity(this.bundle, this.signingPair, this.agreementPair);
  final LoomDeviceKeyBundle bundle;
  final SimpleKeyPair signingPair;
  final SimpleKeyPair agreementPair;
  final Ed25519 signing = Ed25519();
  final X25519 agreement = X25519();
  final Map<String, Uint8List> historicalAgreementSecrets =
      <String, Uint8List>{};

  @override
  Future<LoomDeviceKeyBundle> createOrLoadDevice({
    required LoomIdentityPublic identity,
    required String deviceId,
    required String deviceName,
    required LoomIdentitySigner identitySigner,
  }) async => bundle;

  @override
  Future<LoomDeviceKeyBundle?> readDevice({
    required String identityId,
    required String deviceId,
  }) async => bundle;

  @override
  Future<List<int>> exportAgreementSecret({
    required String identityId,
    required String deviceId,
  }) async {
    if (identityId != bundle.identityId || deviceId != bundle.deviceId) {
      throw StateError('Device agreement secret is unavailable');
    }
    final extracted = await agreementPair.extract();
    try {
      return List<int>.from(extracted.bytes);
    } finally {
      extracted.destroy();
    }
  }

  @override
  Future<void> importHistoricalAgreementSecret({
    required String identityId,
    required String sourceDeviceId,
    required List<int> secret,
  }) async {
    if (identityId != bundle.identityId || secret.length != 32) {
      throw StateError('Invalid historical agreement secret');
    }
    historicalAgreementSecrets[sourceDeviceId] = Uint8List.fromList(secret);
  }

  @override
  Future<List<String>> historicalAgreementDeviceIds({
    required String identityId,
  }) async {
    if (identityId != bundle.identityId) return const <String>[];
    return historicalAgreementSecrets.keys.toList(growable: false);
  }

  @override
  Future<Uint8List> openSealedPayload({
    required String identityId,
    required String deviceId,
    required LoomRelaySealedPayload payload,
    required List<int> associatedData,
  }) async {
    if (identityId != bundle.identityId) {
      throw StateError('Device agreement secret is unavailable');
    }
    if (deviceId == bundle.deviceId) {
      return LoomRelaySealer(keyAgreement: agreement).open(
        payload: payload,
        recipientAgreementKeyPair: agreementPair,
        associatedData: associatedData,
      );
    }
    final historicalSecret = historicalAgreementSecrets[deviceId];
    if (historicalSecret == null) {
      throw StateError('Device agreement secret is unavailable');
    }
    final historicalPair = await agreement.newKeyPairFromSeed(historicalSecret);
    try {
      return await LoomRelaySealer(keyAgreement: agreement).open(
        payload: payload,
        recipientAgreementKeyPair: historicalPair,
        associatedData: associatedData,
      );
    } finally {
      historicalPair.destroy();
    }
  }

  @override
  Future<String> deriveNearbyRendezvousId({
    required String identityId,
    required String deviceId,
    required String remoteAgreementPublicKey,
    required int timeSlot,
  }) async {
    final tag = await createNearbyPairAuthTag(
      identityId: identityId,
      deviceId: deviceId,
      remoteAgreementPublicKey: remoteAgreementPublicKey,
      context: utf8.encode('Loom-Nearby-Rendezvous-v1\n$timeSlot'),
    );
    return base64UrlEncode(tag.take(18).toList()).replaceAll('=', '');
  }

  @override
  Future<List<int>> createNearbyPairAuthTag({
    required String identityId,
    required String deviceId,
    required String remoteAgreementPublicKey,
    required List<int> context,
  }) async {
    final remote = SimplePublicKey(
      base64Decode(remoteAgreementPublicKey),
      type: KeyPairType.x25519,
    );
    final shared = await agreement.sharedSecretKey(
      keyPair: agreementPair,
      remotePublicKey: remote,
    );
    try {
      return (await Hmac.sha256().calculateMac(
        context,
        secretKey: shared,
      )).bytes;
    } finally {
      shared.destroy();
    }
  }

  @override
  Future<void> revokeLocalDeviceSecrets({
    required String identityId,
    required String deviceId,
  }) async {}

  @override
  Future<List<int>> signDevicePayload({
    required String identityId,
    required String deviceId,
    required List<int> payload,
  }) async => (await signing.sign(payload, keyPair: signingPair)).bytes;
}

Future<
  ({
    LoomDeviceKeyBundle bundle,
    SimpleKeyPair signingPair,
    SimpleKeyPair agreementPair,
  })
>
_device(String identityId, String deviceId) async {
  final ed = Ed25519();
  final x = X25519();
  final signingPair = await ed.newKeyPair();
  final agreementPair = await x.newKeyPair();
  final signingPublic = await signingPair.extractPublicKey();
  final agreementPublic = await agreementPair.extractPublicKey();
  return (
    signingPair: signingPair,
    agreementPair: agreementPair,
    bundle: LoomDeviceKeyBundle(
      bundleVersion: 1,
      identityId: identityId,
      deviceId: deviceId,
      deviceName: deviceId,
      signingPublicKey: base64Encode(signingPublic.bytes),
      agreementPublicKey: base64Encode(agreementPublic.bytes),
      createdAt: DateTime.utc(2026, 9, 1),
      capabilities: const ['signing-ed25519', 'agreement-x25519'],
      fingerprint: 'TEST-$identityId-$deviceId',
      deviceSignature: 'test',
      identitySignature: 'test',
    ),
  );
}

void main() {
  test(
    'trusted devices derive the same rotating rendezvous and pre-authenticate',
    () async {
      final a = await _device('identity-a', 'device-a');
      final b = await _device('identity-b', 'device-b');
      final aSecurity = _MemoryDeviceSecurity(
        a.bundle,
        a.signingPair,
        a.agreementPair,
      );
      final bSecurity = _MemoryDeviceSecurity(
        b.bundle,
        b.signingPair,
        b.agreementPair,
      );
      final aAuth = LoomNearbyPairAuthenticator(
        localDevice: a.bundle,
        deviceSecurity: aSecurity,
      );
      final bAuth = LoomNearbyPairAuthenticator(
        localDevice: b.bundle,
        deviceSecurity: bSecurity,
      );
      final now = DateTime.utc(2026, 9, 1, 9);

      final aRendezvous = await aAuth.currentRendezvousId(
        remoteDevice: b.bundle,
        now: now,
      );
      final bRendezvous = await bAuth.currentRendezvousId(
        remoteDevice: a.bundle,
        now: now,
      );
      expect(aRendezvous, bRendezvous);

      final challenge = await aAuth.create(
        remoteDevice: b.bundle,
        sessionId: 'session-1234567890',
        rendezvousId: aRendezvous,
        role: LoomNearbyHandshakeRole.initiator,
      );
      expect(
        await bAuth.verify(
          packet: challenge,
          remoteDevice: a.bundle,
          expectedRole: LoomNearbyHandshakeRole.initiator,
          now: now,
        ),
        isTrue,
      );
    },
  );

  test(
    'authenticated nearby peers derive interoperable hop-local cipher',
    () async {
      final a = await _device('identity-a', 'device-a');
      final b = await _device('identity-b', 'device-b');
      final now = DateTime.utc(2026, 9, 1, 9);

      final aContext = await LoomNearbyHandshakeContext.create(
        sessionId: 'session-1234567890',
        role: LoomNearbyHandshakeRole.initiator,
        localDevice: a.bundle,
        deviceSecurity: _MemoryDeviceSecurity(
          a.bundle,
          a.signingPair,
          a.agreementPair,
        ),
        now: now,
      );
      final bContext = await LoomNearbyHandshakeContext.create(
        sessionId: 'session-1234567890',
        role: LoomNearbyHandshakeRole.responder,
        localDevice: b.bundle,
        deviceSecurity: _MemoryDeviceSecurity(
          b.bundle,
          b.signingPair,
          b.agreementPair,
        ),
        now: now,
      );

      final aCipher = await aContext.acceptRemote(
        remote: bContext.localHello,
        expectedRemoteDevice: b.bundle,
        now: now,
      );
      final bCipher = await bContext.acceptRemote(
        remote: aContext.localHello,
        expectedRemoteDevice: a.bundle,
        now: now,
      );

      final protected = await aCipher.seal(utf8.encode('opaque-envelope'));
      expect(utf8.decode(await bCipher.open(protected)), 'opaque-envelope');
    },
  );
}
