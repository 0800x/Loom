import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_transport/loom_transport.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

final class _Signer implements LoomDirectTransportSigner {
  _Signer(this.keyPair, this.publicKey);

  final KeyPair keyPair;
  final SimplePublicKey publicKey;

  static Future<_Signer> create() async {
    final algorithm = Ed25519();
    final pair = await algorithm.newKeyPair();
    final public = await pair.extractPublicKey();
    return _Signer(pair, public);
  }

  @override
  Future<Uint8List> ed25519PublicKey() async =>
      Uint8List.fromList(publicKey.bytes);

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async {
    final signature = await Ed25519().sign(canonicalBytes, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }
}

void main() {
  test('recipient lease binds destination and both ephemeral keys', () async {
    final signer = await _Signer.create();
    final gateway = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final gatewayEphemeral = Uint8List.fromList(
      List<int>.generate(32, (i) => 100 + i),
    );
    final recipientEphemeral = Uint8List.fromList(
      List<int>.generate(32, (i) => 200 + i),
    );
    final now = DateTime.utc(2026, 9, 7, 12);

    final lease = await LoomProximityGatewayLease.create(
      recipientSigner: signer,
      sessionId: 'session-test-0123456789',
      recipientIdentityId: 'chn:recipient-test',
      recipientDeviceId: 'device-recipient-012345',
      recipientNodeId: 'node:test-node-012345',
      recipientNodeDomain: 'chat.example.test',
      gatewayDevicePublicKey: gateway,
      gatewayEphemeralPublicKey: gatewayEphemeral,
      recipientEphemeralPublicKey: recipientEphemeral,
      bearer: LoomProximityGatewayBearer.ble,
      now: now,
    );

    expect(lease.recipientNodeDomain, 'chat.example.test');
    expect(
      lease.gatewayEphemeralPublicKey,
      base64UrlEncode(gatewayEphemeral).replaceAll('=', ''),
    );
    expect(
      lease.recipientEphemeralPublicKey,
      base64UrlEncode(recipientEphemeral).replaceAll('=', ''),
    );
    expect(
      lease.expiresAt.difference(lease.issuedAt),
      const Duration(seconds: 90),
    );

    final signature = base64Url.decode(base64Url.normalize(lease.signature));
    final valid = await Ed25519().verify(
      lease.canonicalBytes(),
      signature: Signature(signature, publicKey: signer.publicKey),
    );
    expect(valid, isTrue);

    final json = lease.toJson();
    expect(LoomProximityGatewayLease.fromJson(json).sessionId, lease.sessionId);
  });

  test('lease rejects unsafe lifetime', () async {
    final signer = await _Signer.create();
    final bytes = Uint8List(32);
    await expectLater(
      LoomProximityGatewayLease.create(
        recipientSigner: signer,
        sessionId: 'session-test-0123456789',
        recipientIdentityId: 'chn:recipient-test',
        recipientDeviceId: 'device-recipient-012345',
        recipientNodeId: 'node:test-node-012345',
        recipientNodeDomain: 'chat.example.test',
        gatewayDevicePublicKey: bytes,
        gatewayEphemeralPublicKey: bytes,
        recipientEphemeralPublicKey: bytes,
        bearer: LoomProximityGatewayBearer.ble,
        lifetime: const Duration(minutes: 3),
      ),
      throwsFormatException,
    );
  });
}
