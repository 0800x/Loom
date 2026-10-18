import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/helpers.dart' show randomBytes;

import 'device_security_core.dart';

/// Authenticated ephemeral handshake for direct nearby links.
///
/// Discovery itself is anonymous. Identity is disclosed only after a native
/// nearby link exists, and the remote device must match a previously trusted
/// device key bundle before this handshake is accepted for messaging.
class LoomNearbyHello {
  const LoomNearbyHello({
    required this.version,
    required this.sessionId,
    required this.role,
    required this.identityId,
    required this.deviceId,
    required this.deviceFingerprint,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.createdAt,
    required this.signature,
  });

  factory LoomNearbyHello.fromJson(Map<String, Object?> json) {
    String string(String key, {int max = 1024}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid nearby hello $key');
      }
      return value;
    }

    if (json['version'] != 1) {
      throw const FormatException('Unsupported nearby hello version');
    }
    final role = LoomNearbyHandshakeRole.values.byName(string('role', max: 32));
    final createdAt = DateTime.tryParse(string('createdAt', max: 64))?.toUtc();
    if (createdAt == null) {
      throw const FormatException('Invalid nearby hello createdAt');
    }
    final ephemeral = base64Decode(string('ephemeralPublicKey', max: 128));
    final nonce = base64Decode(string('nonce', max: 128));
    final signature = base64Decode(string('signature', max: 256));
    if (ephemeral.length != 32 ||
        nonce.length != 16 ||
        signature.length != 64) {
      throw const FormatException(
        'Invalid nearby hello cryptographic field length',
      );
    }
    return LoomNearbyHello(
      version: 1,
      sessionId: string('sessionId', max: 128),
      role: role,
      identityId: string('identityId', max: 512),
      deviceId: string('deviceId', max: 256),
      deviceFingerprint: string('deviceFingerprint', max: 512),
      ephemeralPublicKey: base64Encode(ephemeral),
      nonce: base64Encode(nonce),
      createdAt: createdAt,
      signature: base64Encode(signature),
    );
  }

  final int version;
  final String sessionId;
  final LoomNearbyHandshakeRole role;
  final String identityId;
  final String deviceId;
  final String deviceFingerprint;
  final String ephemeralPublicKey;
  final String nonce;
  final DateTime createdAt;
  final String signature;

  LoomNearbyHello copyWithSignature(String value) => LoomNearbyHello(
        version: version,
        sessionId: sessionId,
        role: role,
        identityId: identityId,
        deviceId: deviceId,
        deviceFingerprint: deviceFingerprint,
        ephemeralPublicKey: ephemeralPublicKey,
        nonce: nonce,
        createdAt: createdAt,
        signature: value,
      );

  List<int> canonicalBytes() => utf8.encode(
        <String>[
          'Loom-Nearby-Hello-v1',
          sessionId,
          role.name,
          identityId,
          deviceId,
          deviceFingerprint,
          ephemeralPublicKey,
          nonce,
          createdAt.toUtc().toIso8601String(),
        ].join('\n'),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'sessionId': sessionId,
        'role': role.name,
        'identityId': identityId,
        'deviceId': deviceId,
        'deviceFingerprint': deviceFingerprint,
        'ephemeralPublicKey': ephemeralPublicKey,
        'nonce': nonce,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'signature': signature,
      };
}

enum LoomNearbyHandshakeRole { initiator, responder }

class LoomNearbyPreAuth {
  const LoomNearbyPreAuth({
    required this.version,
    required this.sessionId,
    required this.rendezvousId,
    required this.role,
    required this.nonce,
    required this.tag,
    this.peerNonce,
  });

  factory LoomNearbyPreAuth.fromJson(Map<String, Object?> json) {
    String string(String key, {int max = 256}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid nearby pre-auth $key');
      }
      return value;
    }

    if (json['version'] != 1) {
      throw const FormatException('Unsupported nearby pre-auth version');
    }
    final nonceBytes = base64Decode(string('nonce', max: 128));
    final tagBytes = base64Decode(string('tag', max: 128));
    if (nonceBytes.length != 16 || tagBytes.length != 32) {
      throw const FormatException(
        'Invalid nearby pre-auth cryptographic field length',
      );
    }
    final peerNonceRaw = json['peerNonce'];
    if (peerNonceRaw != null) {
      if (peerNonceRaw is! String || base64Decode(peerNonceRaw).length != 16) {
        throw const FormatException('Invalid nearby pre-auth peer nonce');
      }
    }
    return LoomNearbyPreAuth(
      version: 1,
      sessionId: string('sessionId', max: 128),
      rendezvousId: string('rendezvousId', max: 128),
      role: LoomNearbyHandshakeRole.values.byName(string('role', max: 32)),
      nonce: base64Encode(nonceBytes),
      peerNonce: peerNonceRaw as String?,
      tag: base64Encode(tagBytes),
    );
  }

  final int version;
  final String sessionId;
  final String rendezvousId;
  final LoomNearbyHandshakeRole role;
  final String nonce;
  final String? peerNonce;
  final String tag;

  List<int> canonicalContext() => utf8.encode(
        <String>[
          'Loom-Nearby-PreAuth-v1',
          sessionId,
          rendezvousId,
          role.name,
          nonce,
          peerNonce ?? '',
        ].join('\n'),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'sessionId': sessionId,
        'rendezvousId': rendezvousId,
        'role': role.name,
        'nonce': nonce,
        if (peerNonce != null) 'peerNonce': peerNonce,
        'tag': tag,
      };
}

class LoomNearbyPairAuthenticator {
  LoomNearbyPairAuthenticator({
    required this.localDevice,
    required this.deviceSecurity,
  });

  final LoomDeviceKeyBundle localDevice;
  final LoomDeviceSecurityCore deviceSecurity;

  static const Duration rendezvousPeriod = Duration(minutes: 5);

  int timeSlot(DateTime time) =>
      time.toUtc().millisecondsSinceEpoch ~/ rendezvousPeriod.inMilliseconds;

  Future<Set<String>> acceptedRendezvousIds({
    required LoomDeviceKeyBundle remoteDevice,
    DateTime? now,
  }) async {
    final slot = timeSlot(now ?? DateTime.now());
    final values = <String>{};
    for (final candidateSlot in <int>[slot - 1, slot, slot + 1]) {
      if (candidateSlot < 0) continue;
      values.add(
        await deviceSecurity.deriveNearbyRendezvousId(
          identityId: localDevice.identityId,
          deviceId: localDevice.deviceId,
          remoteAgreementPublicKey: remoteDevice.agreementPublicKey,
          timeSlot: candidateSlot,
        ),
      );
    }
    return Set<String>.unmodifiable(values);
  }

  Future<String> currentRendezvousId({
    required LoomDeviceKeyBundle remoteDevice,
    DateTime? now,
  }) =>
      deviceSecurity.deriveNearbyRendezvousId(
        identityId: localDevice.identityId,
        deviceId: localDevice.deviceId,
        remoteAgreementPublicKey: remoteDevice.agreementPublicKey,
        timeSlot: timeSlot(now ?? DateTime.now()),
      );

  Future<LoomNearbyPreAuth> create({
    required LoomDeviceKeyBundle remoteDevice,
    required String sessionId,
    required String rendezvousId,
    required LoomNearbyHandshakeRole role,
    String? peerNonce,
  }) async {
    final nonce = randomBytes(16);
    try {
      final unsigned = LoomNearbyPreAuth(
        version: 1,
        sessionId: sessionId,
        rendezvousId: rendezvousId,
        role: role,
        nonce: base64Encode(nonce),
        peerNonce: peerNonce,
        tag: base64Encode(List<int>.filled(32, 0)),
      );
      final tag = await deviceSecurity.createNearbyPairAuthTag(
        identityId: localDevice.identityId,
        deviceId: localDevice.deviceId,
        remoteAgreementPublicKey: remoteDevice.agreementPublicKey,
        context: unsigned.canonicalContext(),
      );
      return LoomNearbyPreAuth(
        version: 1,
        sessionId: sessionId,
        rendezvousId: rendezvousId,
        role: role,
        nonce: unsigned.nonce,
        peerNonce: peerNonce,
        tag: base64Encode(tag),
      );
    } finally {
      nonce.fillRange(0, nonce.length, 0);
    }
  }

  Future<bool> verify({
    required LoomNearbyPreAuth packet,
    required LoomDeviceKeyBundle remoteDevice,
    required LoomNearbyHandshakeRole expectedRole,
    String? expectedPeerNonce,
    DateTime? now,
  }) async {
    if (packet.role != expectedRole || packet.peerNonce != expectedPeerNonce) {
      return false;
    }
    final acceptedIds = await acceptedRendezvousIds(
      remoteDevice: remoteDevice,
      now: now,
    );
    if (!acceptedIds.contains(packet.rendezvousId)) return false;
    final expected = await deviceSecurity.createNearbyPairAuthTag(
      identityId: localDevice.identityId,
      deviceId: localDevice.deviceId,
      remoteAgreementPublicKey: remoteDevice.agreementPublicKey,
      context: packet.canonicalContext(),
    );
    final actual = base64Decode(packet.tag);
    return _constantTimeEqual(expected, actual);
  }

  bool _constantTimeEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class LoomNearbyHandshakeContext {
  LoomNearbyHandshakeContext._({
    required this.sessionId,
    required this.role,
    required this.localDevice,
    required this.localHello,
    required KeyPair ephemeralKeyPair,
  }) : _ephemeralKeyPair = ephemeralKeyPair;

  final String sessionId;
  final LoomNearbyHandshakeRole role;
  final LoomDeviceKeyBundle localDevice;
  final LoomNearbyHello localHello;
  final KeyPair _ephemeralKeyPair;

  static final X25519 _x25519 = X25519();
  static final Ed25519 _ed25519 = Ed25519();
  static final Sha256 _sha256 = Sha256();

  static Future<LoomNearbyHandshakeContext> create({
    required String sessionId,
    required LoomNearbyHandshakeRole role,
    required LoomDeviceKeyBundle localDevice,
    required LoomDeviceSecurityCore deviceSecurity,
    DateTime? now,
  }) async {
    if (sessionId.isEmpty || sessionId.length > 128) {
      throw ArgumentError.value(sessionId, 'sessionId');
    }
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeralKeyPair.extractPublicKey();
    final nonceBytes = randomBytes(16);
    final unsigned = LoomNearbyHello(
      version: 1,
      sessionId: sessionId,
      role: role,
      identityId: localDevice.identityId,
      deviceId: localDevice.deviceId,
      deviceFingerprint: localDevice.fingerprint,
      ephemeralPublicKey: base64Encode(ephemeralPublic.bytes),
      nonce: base64Encode(nonceBytes),
      createdAt: (now ?? DateTime.now()).toUtc(),
      signature: '',
    );
    final signature = await deviceSecurity.signDevicePayload(
      identityId: localDevice.identityId,
      deviceId: localDevice.deviceId,
      payload: unsigned.canonicalBytes(),
    );
    nonceBytes.fillRange(0, nonceBytes.length, 0);
    return LoomNearbyHandshakeContext._(
      sessionId: sessionId,
      role: role,
      localDevice: localDevice,
      localHello: unsigned.copyWithSignature(base64Encode(signature)),
      ephemeralKeyPair: ephemeralKeyPair,
    );
  }

  Future<LoomNearbySessionCipher> acceptRemote({
    required LoomNearbyHello remote,
    required LoomDeviceKeyBundle expectedRemoteDevice,
    DateTime? now,
  }) async {
    if (remote.sessionId != sessionId || remote.role == role) {
      throw const FormatException('Nearby handshake role/session mismatch');
    }
    if (remote.identityId != expectedRemoteDevice.identityId ||
        remote.deviceId != expectedRemoteDevice.deviceId ||
        remote.deviceFingerprint != expectedRemoteDevice.fingerprint) {
      throw const FormatException('Nearby peer does not match trusted device');
    }
    final current = (now ?? DateTime.now()).toUtc();
    if (current.difference(remote.createdAt).inSeconds.abs() >
        const Duration(minutes: 2).inSeconds) {
      throw const FormatException('Nearby handshake is stale');
    }

    final signingKey = base64Decode(expectedRemoteDevice.signingPublicKey);
    final signature = base64Decode(remote.signature);
    if (signingKey.length != 32 || signature.length != 64) {
      throw const FormatException('Invalid trusted device signing material');
    }
    final valid = await _ed25519.verify(
      remote.canonicalBytes(),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const FormatException(
        'Nearby handshake signature verification failed',
      );
    }

    final remoteEphemeral = base64Decode(remote.ephemeralPublicKey);
    if (remoteEphemeral.length != 32) {
      throw const FormatException('Invalid nearby ephemeral key');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: _ephemeralKeyPair,
      remotePublicKey: SimplePublicKey(
        remoteEphemeral,
        type: KeyPairType.x25519,
      ),
    );

    try {
      final helloLines = <String>[
        base64Encode(localHello.canonicalBytes()),
        base64Encode(remote.canonicalBytes()),
      ]..sort();
      final transcript = await _sha256.hash(utf8.encode(helloLines.join('\n')));
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final key = await hkdf.deriveKey(
        secretKey: shared,
        nonce: transcript.bytes,
        info: utf8.encode('Loom-Nearby-Link-v1'),
      );
      return LoomNearbySessionCipher(secretKey: key, sessionId: sessionId);
    } finally {
      shared.destroy();
      _ephemeralKeyPair.destroy();
    }
  }
}

/// Hop-local AEAD for nearby metadata and opaque E2EE envelopes. This layer is
/// additional to message E2EE; it is not a substitute for conversation crypto.
class LoomNearbySessionCipher {
  LoomNearbySessionCipher({
    required SecretKey secretKey,
    required this.sessionId,
  }) : _secretKey = secretKey;

  final SecretKey _secretKey;
  final String sessionId;
  final AesGcm _aes = AesGcm.with256bits();
  int _sendSequence = 0;
  int _highestReceivedSequence = -1;

  Future<List<int>> seal(List<int> plaintext) async {
    if (plaintext.isEmpty || plaintext.length > 256 * 1024) {
      throw ArgumentError.value(
        plaintext.length,
        'plaintext.length',
        'Nearby plaintext exceeds bounds',
      );
    }
    final sequence = _sendSequence++;
    final nonce = randomBytes(_aes.nonceLength);
    try {
      final aad = _aad(sequence);
      final box = await _aes.encrypt(
        plaintext,
        secretKey: _secretKey,
        nonce: nonce,
        aad: aad,
      );
      final document = <String, Object?>{
        'v': 1,
        'sessionId': sessionId,
        'sequence': sequence,
        'box': base64Encode(box.concatenation()),
      };
      return utf8.encode(jsonEncode(document));
    } finally {
      nonce.fillRange(0, nonce.length, 0);
    }
  }

  Future<List<int>> open(List<int> protectedBytes) async {
    if (protectedBytes.isEmpty || protectedBytes.length > 320 * 1024) {
      throw const FormatException('Nearby protected frame exceeds bounds');
    }
    final decoded = jsonDecode(utf8.decode(protectedBytes));
    if (decoded is! Map<String, Object?> ||
        decoded['v'] != 1 ||
        decoded['sessionId'] != sessionId) {
      throw const FormatException('Invalid nearby protected frame');
    }
    final sequence = decoded['sequence'];
    final encodedBox = decoded['box'];
    if (sequence is! int ||
        sequence < 0 ||
        encodedBox is! String ||
        encodedBox.length > 440 * 1024) {
      throw const FormatException('Invalid nearby protected frame fields');
    }
    if (sequence <= _highestReceivedSequence) {
      throw const FormatException(
        'Nearby protected frame replayed or reordered',
      );
    }
    final concatenated = base64Decode(encodedBox);
    final box = SecretBox.fromConcatenation(
      concatenated,
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    final plaintext = await _aes.decrypt(
      box,
      secretKey: _secretKey,
      aad: _aad(sequence),
    );
    if (plaintext.length > 256 * 1024) {
      throw const FormatException('Nearby plaintext exceeds bounds');
    }
    _highestReceivedSequence = sequence;
    return Uint8List.fromList(plaintext);
  }

  List<int> _aad(int sequence) =>
      utf8.encode('Loom-Nearby-Link-v1\n$sessionId\n$sequence');

  void destroy() => _secretKey.destroy();
}
