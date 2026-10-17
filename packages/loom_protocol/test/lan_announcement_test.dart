import 'dart:convert';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  test(
    'signed LAN announcement verifies against the trusted Node key',
    () async {
      final algorithm = Ed25519();
      final pair = await algorithm.newKeyPair();
      final public = await pair.extractPublicKey();
      final key = base64Encode(public.bytes);
      final unsigned = LoomLanAnnouncement(
        schemaVersion: 1,
        nodeId: 'node:test',
        domain: 'node.example',
        endpoint: Uri.parse('https://node.example'),
        publicKey: key,
        fingerprint: 'TEST',
        timestamp: DateTime.utc(2026, 9, 1, 8),
        nonce: 'nonce-for-test',
        signature: 'pending',
      );
      final signature = await algorithm.sign(
        utf8.encode(unsigned.canonicalPayload()),
        keyPair: pair,
      );
      final announcement = LoomLanAnnouncement(
        schemaVersion: unsigned.schemaVersion,
        nodeId: unsigned.nodeId,
        domain: unsigned.domain,
        endpoint: unsigned.endpoint,
        publicKey: unsigned.publicKey,
        fingerprint: unsigned.fingerprint,
        timestamp: unsigned.timestamp,
        nonce: unsigned.nonce,
        signature: base64Encode(signature.bytes),
      );
      await LoomLanAnnouncementVerifier(
        now: () => DateTime.utc(2026, 9, 1, 8, 0, 30),
      ).verify(
        announcement,
        expectedNodeId: 'node:test',
        expectedPublicKey: key,
      );
    },
  );

  test('LAN announcement parser rejects plaintext endpoints', () {
    expect(
      () => LoomLanAnnouncement.fromJson({
        'schemaVersion': 1,
        'nodeId': 'node:test',
        'domain': 'node.example',
        'endpoint': 'http://192.168.1.2:7483',
        'publicKey': 'x',
        'fingerprint': 'x',
        'timestamp': '2026-09-01T08:00:00.000Z',
        'nonce': 'x',
        'signature': 'x',
      }),
      throwsFormatException,
    );
  });
}
