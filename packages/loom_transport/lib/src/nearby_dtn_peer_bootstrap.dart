import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';

import 'direct_node_delivery.dart';
import 'nearby_transport.dart';

const _peerBootstrapDomain = 'loom-nearby-dtn-peer-bootstrap-v1';
const _peerLinkDomain = 'Loom-Nearby-DTN-Peer-Link-v1';
const _initiatorRole = 'initiator';
const _responderRole = 'responder';

String _b64u(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

Uint8List _decodeB64u(String value, int expectedBytes, String label) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw FormatException('Invalid $label');
  }
  final bytes = base64Url.decode(base64Url.normalize(value));
  if (bytes.length != expectedBytes || _b64u(bytes) != value) {
    throw FormatException('Invalid $label');
  }
  return Uint8List.fromList(bytes);
}

String _iso(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  value.toUtc().millisecondsSinceEpoch,
  isUtc: true,
).toIso8601String();

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

final class LoomNearbyDtnPeerSession {
  const LoomNearbyDtnPeerSession({
    required this.connection,
    required this.opportunity,
    required this.remoteFingerprint,
  });

  final LoomNearbySecureConnection connection;
  final LoomDtnOpportunity opportunity;
  final String remoteFingerprint;
}

final class _PeerHello {
  const _PeerHello({
    required this.role,
    required this.sessionId,
    required this.devicePublicKey,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.issuedAt,
    required this.canStoreCarry,
    required this.signature,
  });

  final String role;
  final String sessionId;
  final String devicePublicKey;
  final String ephemeralPublicKey;
  final String nonce;
  final DateTime issuedAt;
  final bool canStoreCarry;
  final String signature;

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(<Object?>[
        _peerBootstrapDomain,
        role,
        sessionId,
        devicePublicKey,
        ephemeralPublicKey,
        nonce,
        _iso(issuedAt),
        canStoreCarry,
      ]),
    ),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': _peerBootstrapDomain,
    'version': 1,
    'role': role,
    'sessionId': sessionId,
    'devicePublicKey': devicePublicKey,
    'ephemeralPublicKey': ephemeralPublicKey,
    'nonce': nonce,
    'issuedAt': _iso(issuedAt),
    'canStoreCarry': canStoreCarry,
    'signature': signature,
  };

  factory _PeerHello.fromJson(Map<String, Object?> json) {
    String string(String key, {int max = 256}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid nearby DTN peer hello $key');
      }
      return value;
    }

    if (json['kind'] != _peerBootstrapDomain || json['version'] != 1) {
      throw const FormatException('Invalid nearby DTN peer hello');
    }
    final role = string('role', max: 16);
    if (role != _initiatorRole && role != _responderRole) {
      throw const FormatException('Invalid nearby DTN peer role');
    }
    final issuedAt = DateTime.tryParse(string('issuedAt', max: 64))?.toUtc();
    if (issuedAt == null || json['canStoreCarry'] is! bool) {
      throw const FormatException('Invalid nearby DTN peer hello fields');
    }
    final hello = _PeerHello(
      role: role,
      sessionId: string('sessionId', max: 128),
      devicePublicKey: string('devicePublicKey', max: 128),
      ephemeralPublicKey: string('ephemeralPublicKey', max: 128),
      nonce: string('nonce', max: 128),
      issuedAt: issuedAt,
      canStoreCarry: json['canStoreCarry'] as bool,
      signature: string('signature', max: 256),
    );
    _decodeB64u(hello.devicePublicKey, 32, 'nearby DTN signing key');
    _decodeB64u(hello.ephemeralPublicKey, 32, 'nearby DTN ephemeral key');
    _decodeB64u(hello.nonce, 24, 'nearby DTN nonce');
    _decodeB64u(hello.signature, 64, 'nearby DTN signature');
    return hello;
  }
}

/// Establishes a mutually proof-of-possession authenticated secure DTN link.
///
/// A peer proves possession of its Ed25519 device key and an ephemeral X25519
/// key. This deliberately does not grant account trust, recipient status or
/// verified-gateway status. Generic peers therefore remain Spray-and-Wait
/// store/carry opportunities and cannot receive the last forwarding copy.
final class LoomNearbyDtnPeerBootstrap {
  LoomNearbyDtnPeerBootstrap({
    DateTime Function()? clock,
    this.maxClockSkew = const Duration(minutes: 2),
  }) : _clock = clock ?? DateTime.now;

  static final X25519 _x25519 = X25519();
  static final Ed25519 _ed25519 = Ed25519();
  static final Sha256 _sha256 = Sha256();

  final DateTime Function() _clock;
  final Duration maxClockSkew;

  Future<LoomNearbyDtnPeerSession> establishAsInitiator({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    bool canStoreCarry = true,
  }) async {
    final sessionId = _b64u(_randomBytes(24));
    final ephemeral = await _x25519.newKeyPair();
    try {
      final local = await _createHello(
        role: _initiatorRole,
        sessionId: sessionId,
        signer: signer,
        ephemeral: ephemeral,
        canStoreCarry: canStoreCarry,
      );
      await link.send(utf8.encode(jsonEncode(local.toJson())));
      final remote = _PeerHello.fromJson(
        _jsonObject(await link.receive(timeout: const Duration(seconds: 15))),
      );
      await _verifyRemote(
        remote,
        expectedRole: _responderRole,
        expectedSessionId: sessionId,
      );
      final connection = await _secureConnection(
        link: link,
        localEphemeral: ephemeral,
        initiator: local,
        responder: remote,
        remoteEphemeralPublicKey: remote.ephemeralPublicKey,
      );
      return await _session(connection, remote);
    } catch (_) {
      ephemeral.destroy();
      rethrow;
    }
  }

  Future<LoomNearbyDtnPeerSession> establishAsResponder({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    bool canStoreCarry = true,
  }) async {
    final remote = _PeerHello.fromJson(
      _jsonObject(await link.receive(timeout: const Duration(seconds: 15))),
    );
    await _verifyRemote(remote, expectedRole: _initiatorRole);

    final ephemeral = await _x25519.newKeyPair();
    try {
      final local = await _createHello(
        role: _responderRole,
        sessionId: remote.sessionId,
        signer: signer,
        ephemeral: ephemeral,
        canStoreCarry: canStoreCarry,
      );
      await link.send(utf8.encode(jsonEncode(local.toJson())));
      final connection = await _secureConnection(
        link: link,
        localEphemeral: ephemeral,
        initiator: remote,
        responder: local,
        remoteEphemeralPublicKey: remote.ephemeralPublicKey,
      );
      return await _session(connection, remote);
    } catch (_) {
      ephemeral.destroy();
      rethrow;
    }
  }

  Future<_PeerHello> _createHello({
    required String role,
    required String sessionId,
    required LoomDirectTransportSigner signer,
    required SimpleKeyPair ephemeral,
    required bool canStoreCarry,
  }) async {
    final devicePublicKey = await signer.ed25519PublicKey();
    if (devicePublicKey.length != 32) {
      throw const FormatException('Invalid nearby DTN device signing key');
    }
    final ephemeralPublicKey = await ephemeral.extractPublicKey();
    final unsigned = _PeerHello(
      role: role,
      sessionId: sessionId,
      devicePublicKey: _b64u(devicePublicKey),
      ephemeralPublicKey: _b64u(ephemeralPublicKey.bytes),
      nonce: _b64u(_randomBytes(24)),
      issuedAt: _clock().toUtc(),
      canStoreCarry: canStoreCarry,
      signature: '',
    );
    final signature = await signer.sign(unsigned.canonicalBytes());
    if (signature.length != 64) {
      throw const FormatException('Invalid nearby DTN device signature');
    }
    return _PeerHello(
      role: unsigned.role,
      sessionId: unsigned.sessionId,
      devicePublicKey: unsigned.devicePublicKey,
      ephemeralPublicKey: unsigned.ephemeralPublicKey,
      nonce: unsigned.nonce,
      issuedAt: unsigned.issuedAt,
      canStoreCarry: unsigned.canStoreCarry,
      signature: _b64u(signature),
    );
  }

  Future<void> _verifyRemote(
    _PeerHello remote, {
    required String expectedRole,
    String? expectedSessionId,
  }) async {
    if (remote.role != expectedRole ||
        (expectedSessionId != null && remote.sessionId != expectedSessionId)) {
      throw const FormatException('Nearby DTN peer transcript binding failed');
    }
    final now = _clock().toUtc();
    if (now.difference(remote.issuedAt).abs() > maxClockSkew) {
      throw const FormatException('Stale nearby DTN peer hello');
    }
    final publicKey = _decodeB64u(
      remote.devicePublicKey,
      32,
      'nearby DTN signing key',
    );
    final valid = await _ed25519.verify(
      remote.canonicalBytes(),
      signature: Signature(
        _decodeB64u(remote.signature, 64, 'nearby DTN signature'),
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const FormatException('Nearby DTN peer proof-of-possession failed');
    }
  }

  Future<LoomNearbySecureConnection> _secureConnection({
    required LoomNearbyLink link,
    required SimpleKeyPair localEphemeral,
    required _PeerHello initiator,
    required _PeerHello responder,
    required String remoteEphemeralPublicKey,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: localEphemeral,
      remotePublicKey: SimplePublicKey(
        _decodeB64u(
          remoteEphemeralPublicKey,
          32,
          'remote nearby DTN ephemeral key',
        ),
        type: KeyPairType.x25519,
      ),
    );
    try {
      final transcript = await _sha256.hash(<int>[
        ...initiator.canonicalBytes(),
        ...utf8.encode(initiator.signature),
        ...responder.canonicalBytes(),
        ...utf8.encode(responder.signature),
      ]);
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: shared,
        nonce: transcript.bytes,
        info: utf8.encode(_peerLinkDomain),
      );
      final cipher = _NearbyDtnPeerCipher(
        key: key,
        sessionId: initiator.sessionId,
      );
      return LoomNearbySecureConnection(
        link: link,
        seal: cipher.seal,
        open: cipher.open,
      );
    } finally {
      shared.destroy();
      localEphemeral.destroy();
    }
  }

  Future<LoomNearbyDtnPeerSession> _session(
    LoomNearbySecureConnection connection,
    _PeerHello remote,
  ) async {
    final fingerprint = _b64u(
      (await _sha256.hash(
        _decodeB64u(remote.devicePublicKey, 32, 'nearby DTN signing key'),
      )).bytes,
    );
    return LoomNearbyDtnPeerSession(
      connection: connection,
      remoteFingerprint: fingerprint,
      opportunity: LoomDtnOpportunity(
        opportunityId: 'nearby:$fingerprint',
        authenticated: true,
        directRecipient: false,
        gatewayClaim: LoomGatewayClaimState.none,
        supportedRelayScopes: const <LoomRoutingScopeV2>{},
        canStoreCarry: remote.canStoreCarry,
        linkQualityPercent: 75,
        congestionPercent: 0,
        batteryConstrained: false,
        recentSuccessfulTransfers: 0,
        recentFailedTransfers: 0,
      ),
    );
  }

  Map<String, Object?> _jsonObject(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 16 * 1024) {
      throw const FormatException('Nearby DTN bootstrap frame exceeds bounds');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) {
      throw const FormatException(
        'Nearby DTN bootstrap frame must be an object',
      );
    }
    return value.map(
      (key, value) => MapEntry(key.toString(), value as Object?),
    );
  }
}

final class _NearbyDtnPeerCipher {
  _NearbyDtnPeerCipher({required SecretKey key, required this.sessionId})
    : _key = key;

  final SecretKey _key;
  final String sessionId;
  final AesGcm _aes = AesGcm.with256bits();
  int _sendSequence = 0;
  int _highestReceivedSequence = -1;

  Future<List<int>> seal(List<int> plaintext) async {
    final sequence = _sendSequence++;
    final nonce = _randomBytes(_aes.nonceLength);
    try {
      final box = await _aes.encrypt(
        plaintext,
        secretKey: _key,
        nonce: nonce,
        aad: utf8.encode('$_peerLinkDomain\n$sessionId\n$sequence'),
      );
      return utf8.encode(
        jsonEncode(<String, Object?>{
          'v': 1,
          'sessionId': sessionId,
          'sequence': sequence,
          'box': base64Encode(box.concatenation()),
        }),
      );
    } finally {
      nonce.fillRange(0, nonce.length, 0);
    }
  }

  Future<List<int>> open(List<int> protectedBytes) async {
    final value = jsonDecode(utf8.decode(protectedBytes));
    if (value is! Map ||
        value['v'] != 1 ||
        value['sessionId'] != sessionId ||
        value['sequence'] is! int ||
        value['box'] is! String) {
      throw const FormatException('Invalid nearby DTN protected frame');
    }
    final sequence = value['sequence'] as int;
    if (sequence <= _highestReceivedSequence) {
      throw const FormatException('Replayed nearby DTN protected frame');
    }
    final box = SecretBox.fromConcatenation(
      base64Decode(value['box'] as String),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    final plaintext = await _aes.decrypt(
      box,
      secretKey: _key,
      aad: utf8.encode('$_peerLinkDomain\n$sessionId\n$sequence'),
    );
    _highestReceivedSequence = sequence;
    return plaintext;
  }
}
