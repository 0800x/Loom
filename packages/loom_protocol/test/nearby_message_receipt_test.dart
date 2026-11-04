import 'dart:convert';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  test('recipient signature binds ciphertext, message, parties and device; relay cannot forge it', () async {
    final ed = Ed25519();
    final recipient = await ed.newKeyPair();
    final relay = await ed.newKeyPair();
    final trusted = base64Encode((await recipient.extractPublicKey()).bytes);
    final receipt = await LoomNearbyMessageReceipt.create(
      clientId: 'message-1',
      sender: '@alice:one.example',
      recipient: '@bob:two.example',
      deviceId: 'bob-phone',
      ciphertext: 'exact encrypted message',
      sign: (bytes) async => (await ed.sign(bytes, keyPair: recipient)).bytes,
    );
    final decoded = LoomNearbyMessageReceipt.decode(receipt.encode());
    Future<bool> verify(
      LoomNearbyMessageReceipt value, {
      String id = 'message-1',
      String sender = '@alice:one.example',
      String peer = '@bob:two.example',
      String device = 'bob-phone',
      String body = 'exact encrypted message',
    }) => value.verify(
      expectedClientId: id,
      expectedSender: sender,
      expectedRecipient: peer,
      expectedDeviceId: device,
      ciphertext: body,
      trustedSigningPublicKey: trusted,
    );
    expect(await verify(decoded), isTrue);
    expect(
      await verify(decoded),
      isTrue,
    ); // Safe idempotent replay of this exact proof.
    expect(await verify(decoded, id: 'message-2'), isFalse);
    expect(await verify(decoded, sender: '@mallory:one.example'), isFalse);
    expect(await verify(decoded, peer: '@mallory:two.example'), isFalse);
    expect(await verify(decoded, device: 'relay-phone'), isFalse);
    expect(await verify(decoded, body: 'different encrypted message'), isFalse);
    final forged = await LoomNearbyMessageReceipt.create(
      clientId: receipt.clientId,
      sender: receipt.sender,
      recipient: receipt.recipient,
      deviceId: receipt.deviceId,
      ciphertext: 'exact encrypted message',
      sign: (bytes) async => (await ed.sign(bytes, keyPair: relay)).bytes,
    );
    expect(await verify(forged), isFalse);
    final changed = jsonDecode(receipt.encode()) as Map<String, dynamic>;
    changed['signature'] = base64Encode(List<int>.filled(64, 0));
    expect(
      await verify(LoomNearbyMessageReceipt.decode(jsonEncode(changed))),
      isFalse,
    );
  });

  test('malformed and oversized receipt frames are rejected', () {
    expect(() => LoomNearbyMessageReceipt.decode('{}'), throwsFormatException);
    expect(
      () => LoomNearbyMessageReceipt.decode('x' * 4097),
      throwsFormatException,
    );
    expect(
      () => LoomNearbyMessageReceipt.decode('{"version":2}'),
      throwsFormatException,
    );
  });
}
