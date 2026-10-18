import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';

import 'direct_node_delivery.dart';
import 'nearby_transport.dart';
import 'proximity_gateway.dart';

const _bootstrapDomain = 'loom-proximity-gateway-bootstrap-v1';
const _linkDomain = 'Loom-Proximity-Gateway-Link-v1';
const _gatewayHelloKind = 'proximity.gateway.bootstrap.hello.v1';
const _recipientLeaseKind = 'proximity.gateway.bootstrap.lease.v1';
const _registeredKind = 'proximity.gateway.bootstrap.registered.v1';

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

final class _GatewayHello {
  const _GatewayHello({
    required this.sessionId,
    required this.devicePublicKey,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.issuedAt,
    required this.signature,
  });

  final String sessionId;
  final String devicePublicKey;
  final String ephemeralPublicKey;
  final String nonce;
  final DateTime issuedAt;
  final String signature;

  Uint8List canonicalBytes() => Uint8List.fromList(
        utf8.encode(
          jsonEncode(<Object?>[
            _bootstrapDomain,
            sessionId,
            devicePublicKey,
            ephemeralPublicKey,
            nonce,
            _iso(issuedAt),
          ]),
        ),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': _gatewayHelloKind,
        'sessionId': sessionId,
        'devicePublicKey': devicePublicKey,
        'ephemeralPublicKey': ephemeralPublicKey,
        'nonce': nonce,
        'issuedAt': _iso(issuedAt),
        'signature': signature,
      };

  factory _GatewayHello.fromJson(Map<String, Object?> json) {
    String string(String key, {int max = 256}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid gateway hello $key');
      }
      return value;
    }

    if (json['kind'] != _gatewayHelloKind) {
      throw const FormatException('Invalid gateway bootstrap hello');
    }
    final issuedAt = DateTime.tryParse(string('issuedAt', max: 64))?.toUtc();
    if (issuedAt == null ||
        DateTime.now().toUtc().difference(issuedAt).inSeconds.abs() > 120) {
      throw const FormatException('Stale gateway bootstrap hello');
    }
    final hello = _GatewayHello(
      sessionId: string('sessionId', max: 128),
      devicePublicKey: string('devicePublicKey', max: 128),
      ephemeralPublicKey: string('ephemeralPublicKey', max: 128),
      nonce: string('nonce', max: 128),
      issuedAt: issuedAt,
      signature: string('signature', max: 256),
    );
    _decodeB64u(hello.devicePublicKey, 32, 'gateway signing key');
    _decodeB64u(hello.ephemeralPublicKey, 32, 'gateway ephemeral key');
    _decodeB64u(hello.nonce, 24, 'gateway bootstrap nonce');
    _decodeB64u(hello.signature, 64, 'gateway bootstrap signature');
    return hello;
  }
}

final class LoomGatewayEstablishedSession {
  const LoomGatewayEstablishedSession({
    required this.lease,
    required this.connection,
    required this.client,
  });

  final LoomProximityGatewayLease lease;
  final LoomNearbySecureConnection connection;
  final LoomProximityGatewayClient client;
}

final class LoomRecipientGatewaySession {
  const LoomRecipientGatewaySession({
    required this.lease,
    required this.connection,
  });

  final LoomProximityGatewayLease lease;
  final LoomNearbySecureConnection connection;
}

/// Bootstrap for a stranger/unknown Loom device acting only as a last-mile
/// gateway. It intentionally does not promote the gateway to a trusted account
/// identity. The gateway proves possession of an Ed25519 key, the recipient
/// binds that key and both X25519 ephemeral keys into a short-lived signed
/// lease, and the destination Node validates the recipient signature before it
/// releases any opaque pending traffic.
final class LoomProximityGatewayBootstrap {
  const LoomProximityGatewayBootstrap();

  static final X25519 _x25519 = X25519();
  static final Ed25519 _ed25519 = Ed25519();
  static final Sha256 _sha256 = Sha256();

  Future<LoomGatewayEstablishedSession> establishAsGateway({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner gatewaySigner,
    LoomNodeClient? nodeClient,
  }) async {
    final signingPublic = await gatewaySigner.ed25519PublicKey();
    if (signingPublic.length != 32) {
      throw const FormatException('Invalid gateway device signing key');
    }
    final ephemeral = await _x25519.newKeyPair();
    try {
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final unsigned = _GatewayHello(
        sessionId: _b64u(_randomBytes(24)),
        devicePublicKey: _b64u(signingPublic),
        ephemeralPublicKey: _b64u(ephemeralPublic.bytes),
        nonce: _b64u(_randomBytes(24)),
        issuedAt: DateTime.now().toUtc(),
        signature: '',
      );
      final signature = await gatewaySigner.sign(unsigned.canonicalBytes());
      if (signature.length != 64) {
        throw const FormatException('Invalid gateway bootstrap signature');
      }
      final hello = _GatewayHello(
        sessionId: unsigned.sessionId,
        devicePublicKey: unsigned.devicePublicKey,
        ephemeralPublicKey: unsigned.ephemeralPublicKey,
        nonce: unsigned.nonce,
        issuedAt: unsigned.issuedAt,
        signature: _b64u(signature),
      );
      await link.send(utf8.encode(jsonEncode(hello.toJson())));

      final response = _jsonObject(
        await link.receive(timeout: const Duration(seconds: 15)),
      );
      if (response['kind'] != _recipientLeaseKind ||
          response['lease'] is! Map) {
        throw const FormatException('Invalid recipient gateway lease response');
      }
      final rawLease = response['lease'] as Map;
      final lease = LoomProximityGatewayLease.fromJson(
        rawLease.map(
          (key, value) => MapEntry(key.toString(), value as Object?),
        ),
      );
      if (lease.sessionId != hello.sessionId ||
          lease.gatewayDevicePublicKey != hello.devicePublicKey ||
          lease.gatewayEphemeralPublicKey != hello.ephemeralPublicKey) {
        throw const FormatException('Gateway lease bootstrap binding mismatch');
      }

      final target = await LoomProximityGatewayTarget.discoverForLease(
        lease,
        nodeClient: nodeClient,
      );
      final client = LoomProximityGatewayClient(
        target: target,
        gatewaySigner: gatewaySigner,
      );
      await client.registerLease(lease);

      final cipher = await _deriveCipher(
        lease: lease,
        localEphemeral: ephemeral,
        remoteEphemeralPublicKey: lease.recipientEphemeralPublicKey,
      );
      final connection = LoomNearbySecureConnection(
        link: link,
        seal: cipher.seal,
        open: cipher.open,
      );
      await connection.send(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'kind': _registeredKind,
            'leaseId': lease.leaseId,
          }),
        ),
      );
      return LoomGatewayEstablishedSession(
        lease: lease,
        connection: connection,
        client: client,
      );
    } catch (_) {
      ephemeral.destroy();
      rethrow;
    }
  }

  Future<LoomRecipientGatewaySession> establishAsRecipient({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner recipientSigner,
    required String recipientIdentityId,
    required String recipientDeviceId,
    required String recipientNodeId,
    required String recipientNodeDomain,
    required LoomProximityGatewayBearer bearer,
  }) async {
    final helloJson = _jsonObject(
      await link.receive(timeout: const Duration(seconds: 15)),
    );
    final hello = _GatewayHello.fromJson(helloJson);
    final gatewaySigningBytes = _decodeB64u(
      hello.devicePublicKey,
      32,
      'gateway signing key',
    );
    final valid = await _ed25519.verify(
      hello.canonicalBytes(),
      signature: Signature(
        _decodeB64u(hello.signature, 64, 'gateway signature'),
        publicKey: SimplePublicKey(
          gatewaySigningBytes,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) {
      throw const FormatException('Gateway bootstrap key possession failed');
    }

    final recipientEphemeral = await _x25519.newKeyPair();
    try {
      final recipientEphemeralPublic =
          await recipientEphemeral.extractPublicKey();
      final lease = await LoomProximityGatewayLease.create(
        recipientSigner: recipientSigner,
        sessionId: hello.sessionId,
        recipientIdentityId: recipientIdentityId,
        recipientDeviceId: recipientDeviceId,
        recipientNodeId: recipientNodeId,
        recipientNodeDomain: recipientNodeDomain,
        gatewayDevicePublicKey: gatewaySigningBytes,
        gatewayEphemeralPublicKey: _decodeB64u(
          hello.ephemeralPublicKey,
          32,
          'gateway ephemeral key',
        ),
        recipientEphemeralPublicKey: Uint8List.fromList(
          recipientEphemeralPublic.bytes,
        ),
        bearer: bearer,
      );
      await link.send(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'kind': _recipientLeaseKind,
            'lease': lease.toJson(),
          }),
        ),
      );

      final cipher = await _deriveCipher(
        lease: lease,
        localEphemeral: recipientEphemeral,
        remoteEphemeralPublicKey: lease.gatewayEphemeralPublicKey,
      );
      final connection = LoomNearbySecureConnection(
        link: link,
        seal: cipher.seal,
        open: cipher.open,
      );
      final registered = _jsonObject(
        await connection.receive(timeout: const Duration(seconds: 20)),
      );
      if (registered['kind'] != _registeredKind ||
          registered['leaseId'] != lease.leaseId) {
        throw const FormatException(
          'Gateway did not confirm Node registration',
        );
      }
      return LoomRecipientGatewaySession(lease: lease, connection: connection);
    } catch (_) {
      recipientEphemeral.destroy();
      rethrow;
    }
  }

  Future<_GatewayLinkCipher> _deriveCipher({
    required LoomProximityGatewayLease lease,
    required KeyPair localEphemeral,
    required String remoteEphemeralPublicKey,
  }) async {
    final remote = _decodeB64u(
      remoteEphemeralPublicKey,
      32,
      'remote gateway ephemeral key',
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: localEphemeral,
      remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
    );
    try {
      final transcript = await _sha256.hash(<int>[
        ...lease.canonicalBytes(),
        ...utf8.encode(lease.signature),
      ]);
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: shared,
        nonce: transcript.bytes,
        info: utf8.encode(_linkDomain),
      );
      return _GatewayLinkCipher(key: key, sessionId: lease.sessionId);
    } finally {
      shared.destroy();
      localEphemeral.destroy();
    }
  }

  Map<String, Object?> _jsonObject(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 320 * 1024) {
      throw const FormatException('Gateway bootstrap frame exceeds bounds');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) {
      throw const FormatException('Gateway bootstrap frame must be an object');
    }
    return value.map(
      (key, value) => MapEntry(key.toString(), value as Object?),
    );
  }
}

final class _GatewayLinkCipher {
  _GatewayLinkCipher({required SecretKey key, required this.sessionId})
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
        aad: utf8.encode('$_linkDomain\n$sessionId\n$sequence'),
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
      throw const FormatException('Invalid proximity gateway protected frame');
    }
    final sequence = value['sequence'] as int;
    if (sequence <= _highestReceivedSequence) {
      throw const FormatException('Replayed proximity gateway protected frame');
    }
    final box = SecretBox.fromConcatenation(
      base64Decode(value['box'] as String),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    final plaintext = await _aes.decrypt(
      box,
      secretKey: _key,
      aad: utf8.encode('$_linkDomain\n$sessionId\n$sequence'),
    );
    _highestReceivedSequence = sequence;
    return plaintext;
  }
}
