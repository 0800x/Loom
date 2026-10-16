import 'app_lock.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'identity_core.dart';
import 'relay_sealing.dart';

abstract interface class LoomDeviceSecurityCore {
  Future<LoomDeviceKeyBundle> createOrLoadDevice({
    required LoomIdentityPublic identity,
    required String deviceId,
    required String deviceName,
    required LoomIdentitySigner identitySigner,
  });

  Future<LoomDeviceKeyBundle?> readDevice({
    required String identityId,
    required String deviceId,
  });

  Future<List<int>> signDevicePayload({
    required String identityId,
    required String deviceId,
    required List<int> payload,
  });

  Future<List<int>> exportAgreementSecret({
    required String identityId,
    required String deviceId,
  });

  Future<void> importHistoricalAgreementSecret({
    required String identityId,
    required String sourceDeviceId,
    required List<int> secret,
  });

  Future<List<String>> historicalAgreementDeviceIds({
    required String identityId,
  });

  Future<Uint8List> openSealedPayload({
    required String identityId,
    required String deviceId,
    required LoomRelaySealedPayload payload,
    required List<int> associatedData,
  });

  Future<String> deriveNearbyRendezvousId({
    required String identityId,
    required String deviceId,
    required String remoteAgreementPublicKey,
    required int timeSlot,
  });

  Future<List<int>> createNearbyPairAuthTag({
    required String identityId,
    required String deviceId,
    required String remoteAgreementPublicKey,
    required List<int> context,
  });

  Future<void> revokeLocalDeviceSecrets({
    required String identityId,
    required String deviceId,
  });
}

class LoomDeviceSecurityCoreV1 implements LoomDeviceSecurityCore {
  LoomDeviceSecurityCoreV1({FlutterSecureStorage? storage})
      : _storage = LoomSecretStorage(storage);

  static const int _maxHistoricalDevices = 32;

  final LoomSecretStorage _storage;
  final Ed25519 _signing = Ed25519();
  final X25519 _agreement = X25519();
  final Sha256 _sha256 = Sha256();

  String _key(String identityId, String deviceId, String suffix) =>
      'loom.device.v1.${base64Url.encode(utf8.encode(identityId))}.${base64Url.encode(utf8.encode(deviceId))}.$suffix';

  String _historyIndexKey(String identityId) =>
      'loom.device.history.v1.${base64Url.encode(utf8.encode(identityId))}.index';

  String _historySecretKey(String identityId, String deviceId) =>
      'loom.device.history.v1.${base64Url.encode(utf8.encode(identityId))}.${base64Url.encode(utf8.encode(deviceId))}.agreement-secret';

  @override
  Future<LoomDeviceKeyBundle> createOrLoadDevice({
    required LoomIdentityPublic identity,
    required String deviceId,
    required String deviceName,
    required LoomIdentitySigner identitySigner,
  }) async {
    final existing = await readDevice(
      identityId: identity.identityId,
      deviceId: deviceId,
    );
    if (existing != null) {
      return existing;
    }

    final signingPair = await _signing.newKeyPair();
    final agreementPair = await _agreement.newKeyPair();
    final signingSecret = await signingPair.extract();
    final agreementSecret = await agreementPair.extract();
    try {
      final signingPublic = await signingPair.extractPublicKey();
      final agreementPublic = await agreementPair.extractPublicKey();
      final createdAt = DateTime.now().toUtc();

      final unsigned = LoomDeviceKeyBundle.unsigned(
        identityId: identity.identityId,
        deviceId: deviceId,
        deviceName: deviceName,
        signingPublicKey: base64Encode(signingPublic.bytes),
        agreementPublicKey: base64Encode(agreementPublic.bytes),
        createdAt: createdAt,
        capabilities: const <String>[
          'signing-ed25519',
          'agreement-x25519',
          'loom-call-audio-v1',
          'loom-call-video-v1',
        ],
      );
      final canonical = unsigned.canonicalBindingBytes();
      final deviceSignature = await _signing.sign(
        canonical,
        keyPair: signingPair,
      );
      final identitySignature = await identitySigner.signIdentityBinding(
        canonical,
      );
      final digest = await _sha256.hash(canonical);
      final bundle = unsigned.copyWith(
        fingerprint: _formatFingerprint(digest.bytes),
        deviceSignature: base64Encode(deviceSignature.bytes),
        identitySignature: base64Encode(identitySignature),
      );

      await _storage.write(
        key: _key(identity.identityId, deviceId, 'signing-secret'),
        value: base64Encode(signingSecret.bytes),
      );
      await _storage.write(
        key: _key(identity.identityId, deviceId, 'agreement-secret'),
        value: base64Encode(agreementSecret.bytes),
      );
      await _storage.write(
        key: _key(identity.identityId, deviceId, 'bundle'),
        value: jsonEncode(bundle.toJson()),
      );
      return bundle;
    } finally {
      signingSecret.destroy();
      agreementSecret.destroy();
    }
  }

  @override
  Future<LoomDeviceKeyBundle?> readDevice({
    required String identityId,
    required String deviceId,
  }) async {
    final encoded = await _storage.read(
      key: _key(identityId, deviceId, 'bundle'),
    );
    if (encoded == null) {
      return null;
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Stored device bundle is malformed');
    }
    final bundle = LoomDeviceKeyBundle.fromJson(decoded);
    if (bundle.identityId != identityId || bundle.deviceId != deviceId) {
      throw const FormatException('Stored device bundle binding mismatch');
    }
    return bundle;
  }

  @override
  Future<List<int>> signDevicePayload({
    required String identityId,
    required String deviceId,
    required List<int> payload,
  }) async {
    final encoded = await _storage.read(
      key: _key(identityId, deviceId, 'signing-secret'),
    );
    if (encoded == null) {
      throw StateError('Device signing secret is unavailable');
    }
    final secret = base64Decode(encoded);
    try {
      if (secret.length != 32) {
        throw const FormatException('Invalid local device signing secret');
      }
      final pair = await _signing.newKeyPairFromSeed(secret);
      try {
        final signature = await _signing.sign(payload, keyPair: pair);
        return signature.bytes;
      } finally {
        pair.destroy();
      }
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  @override
  Future<List<int>> exportAgreementSecret({
    required String identityId,
    required String deviceId,
  }) async {
    final encoded = await _storage.read(
      key: _key(identityId, deviceId, 'agreement-secret'),
    );
    if (encoded == null) {
      throw StateError('Device agreement secret is unavailable');
    }
    final secret = base64Decode(encoded);
    if (secret.length != 32) {
      secret.fillRange(0, secret.length, 0);
      throw const FormatException('Invalid local device agreement secret');
    }
    try {
      return Uint8List.fromList(secret);
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  @override
  Future<void> importHistoricalAgreementSecret({
    required String identityId,
    required String sourceDeviceId,
    required List<int> secret,
  }) async {
    if (identityId.trim().isEmpty ||
        sourceDeviceId.trim().isEmpty ||
        secret.length != 32) {
      throw const FormatException('Invalid historical agreement key');
    }
    final ids = await historicalAgreementDeviceIds(identityId: identityId);
    final next = <String>[
      sourceDeviceId,
      ...ids.where((id) => id != sourceDeviceId),
    ];
    if (next.length > _maxHistoricalDevices) {
      final removed = next.sublist(_maxHistoricalDevices);
      for (final id in removed) {
        await _storage.delete(key: _historySecretKey(identityId, id));
      }
      next.removeRange(_maxHistoricalDevices, next.length);
    }
    await _storage.write(
      key: _historySecretKey(identityId, sourceDeviceId),
      value: base64Encode(secret),
    );
    await _storage.write(
      key: _historyIndexKey(identityId),
      value: jsonEncode(next),
    );
  }

  @override
  Future<List<String>> historicalAgreementDeviceIds({
    required String identityId,
  }) async {
    final encoded = await _storage.read(key: _historyIndexKey(identityId));
    if (encoded == null) {
      return const <String>[];
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! List || decoded.any((value) => value is! String)) {
      throw const FormatException('Historical device-key index is malformed');
    }
    return decoded
        .cast<String>()
        .where((value) => value.isNotEmpty && value.length <= 256)
        .take(_maxHistoricalDevices)
        .toList(growable: false);
  }

  @override
  Future<Uint8List> openSealedPayload({
    required String identityId,
    required String deviceId,
    required LoomRelaySealedPayload payload,
    required List<int> associatedData,
  }) async {
    if (associatedData.isEmpty || associatedData.length > 16 * 1024) {
      throw ArgumentError.value(associatedData.length, 'associatedData.length');
    }
    final encoded = await _storage.read(
          key: _key(identityId, deviceId, 'agreement-secret'),
        ) ??
        await _storage.read(key: _historySecretKey(identityId, deviceId));
    if (encoded == null) {
      throw StateError('Device agreement secret is unavailable');
    }
    final secret = base64Decode(encoded);
    if (secret.length != 32) {
      secret.fillRange(0, secret.length, 0);
      throw const FormatException('Invalid local device agreement secret');
    }
    final pair = await _agreement.newKeyPairFromSeed(secret);
    try {
      return await LoomRelaySealer(keyAgreement: _agreement).open(
        payload: payload,
        recipientAgreementKeyPair: pair,
        associatedData: associatedData,
      );
    } finally {
      secret.fillRange(0, secret.length, 0);
      pair.destroy();
    }
  }

  @override
  Future<String> deriveNearbyRendezvousId({
    required String identityId,
    required String deviceId,
    required String remoteAgreementPublicKey,
    required int timeSlot,
  }) async {
    if (timeSlot < 0) {
      throw ArgumentError.value(timeSlot, 'timeSlot');
    }
    final tag = await createNearbyPairAuthTag(
      identityId: identityId,
      deviceId: deviceId,
      remoteAgreementPublicKey: remoteAgreementPublicKey,
      context: utf8.encode('Loom-Nearby-Rendezvous-v1\n$timeSlot'),
    );
    return base64UrlEncode(
      tag.take(18).toList(growable: false),
    ).replaceAll('=', '');
  }

  @override
  Future<List<int>> createNearbyPairAuthTag({
    required String identityId,
    required String deviceId,
    required String remoteAgreementPublicKey,
    required List<int> context,
  }) async {
    if (context.isEmpty || context.length > 4096) {
      throw ArgumentError.value(context.length, 'context.length');
    }
    final encodedSecret = await _storage.read(
      key: _key(identityId, deviceId, 'agreement-secret'),
    );
    if (encodedSecret == null) {
      throw StateError('Device agreement secret is unavailable');
    }
    final secret = base64Decode(encodedSecret);
    final remotePublic = base64Decode(remoteAgreementPublicKey);
    if (secret.length != 32 || remotePublic.length != 32) {
      secret.fillRange(0, secret.length, 0);
      throw const FormatException('Invalid nearby agreement key material');
    }
    SecretKey? shared;
    SimpleKeyPair? localPair;
    try {
      localPair = await _agreement.newKeyPairFromSeed(secret);
      shared = await _agreement.sharedSecretKey(
        keyPair: localPair,
        remotePublicKey: SimplePublicKey(
          remotePublic,
          type: KeyPairType.x25519,
        ),
      );
      final mac = await Hmac.sha256().calculateMac(context, secretKey: shared);
      return List<int>.unmodifiable(mac.bytes);
    } finally {
      secret.fillRange(0, secret.length, 0);
      if (shared != null) {
        shared.destroy();
      }
      localPair?.destroy();
    }
  }

  @override
  Future<void> revokeLocalDeviceSecrets({
    required String identityId,
    required String deviceId,
  }) async {
    await _storage.delete(key: _key(identityId, deviceId, 'signing-secret'));
    await _storage.delete(key: _key(identityId, deviceId, 'agreement-secret'));
    await _storage.delete(key: _key(identityId, deviceId, 'bundle'));
  }

  String _formatFingerprint(List<int> bytes) {
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return <String>[
      for (var index = 0; index < hex.length; index += 4)
        hex.substring(index, index + 4),
    ].join(' ');
  }
}
