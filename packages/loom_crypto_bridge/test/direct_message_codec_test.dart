import 'dart:convert';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

Future<LoomDeviceKeyBundle> bundle({
  required String identityId,
  required String deviceId,
  required SimplePublicKey signingPublicKey,
  required SimplePublicKey agreementPublicKey,
}) async =>
    LoomDeviceKeyBundle(
      bundleVersion: 1,
      identityId: identityId,
      deviceId: deviceId,
      deviceName: deviceId,
      signingPublicKey: base64Encode(signingPublicKey.bytes),
      agreementPublicKey: base64Encode(agreementPublicKey.bytes),
      createdAt: DateTime.utc(2026, 9, 4),
      capabilities: const <String>['signing-ed25519', 'agreement-x25519'],
      fingerprint: 'TEST',
      deviceSignature: base64Encode(List<int>.filled(64, 1)),
      identitySignature: base64Encode(List<int>.filled(64, 2)),
    );

void main() {
  test('direct E2EE survives different Node-local conversation IDs', () async {
    final ed = Ed25519();
    final x = X25519();
    final senderSigning = await ed.newKeyPair();
    final senderSigningPublic = await senderSigning.extractPublicKey();
    final senderAgreement = await x.newKeyPair();
    final senderAgreementPublic = await senderAgreement.extractPublicKey();
    final recipientAgreement = await x.newKeyPair();
    final recipientAgreementPublic =
        await recipientAgreement.extractPublicKey();
    final recipientSigning = await ed.newKeyPair();
    final recipientSigningPublic = await recipientSigning.extractPublicKey();

    final alice = await bundle(
      identityId: 'chn:alice',
      deviceId: 'alice-phone',
      signingPublicKey: senderSigningPublic,
      agreementPublicKey: senderAgreementPublic,
    );
    final bob = await bundle(
      identityId: 'chn:bob',
      deviceId: 'bob-phone',
      signingPublicKey: recipientSigningPublic,
      agreementPublicKey: recipientAgreementPublic,
    );
    final sealer = LoomRelaySealer();
    final codec = LoomDirectMessageCodec(
      signer: (payload) async =>
          (await ed.sign(payload, keyPair: senderSigning)).bytes,
      opener: ({required payload, required associatedData}) => sealer.open(
        payload: payload,
        recipientAgreementKeyPair: recipientAgreement,
        associatedData: associatedData,
      ),
    );

    final envelope = await codec.encryptText(
      conversationId: 'conv-node-a-123',
      plaintext: 'hello across federation',
      senderAddress: '@alice:loom-a.test',
      senderIdentityId: alice.identityId,
      senderDeviceId: alice.deviceId,
      recipientDevices: <LoomDeviceKeyBundle>[alice, bob],
    );

    expect(
      await codec.decryptText(
        envelope: envelope,
        expectedConversationId: 'conv-node-b-999',
        expectedSenderAddress: '@alice:loom-a.test',
        localIdentityId: bob.identityId,
        localDeviceId: bob.deviceId,
        senderDevice: alice,
      ),
      'hello across federation',
    );
  });

  test('tampered direct-message sender signature is rejected', () async {
    final ed = Ed25519();
    final x = X25519();
    final senderSigning = await ed.newKeyPair();
    final senderAgreement = await x.newKeyPair();
    final recipientAgreement = await x.newKeyPair();
    final recipientSigning = await ed.newKeyPair();
    final alice = await bundle(
      identityId: 'chn:alice',
      deviceId: 'alice-phone',
      signingPublicKey: await senderSigning.extractPublicKey(),
      agreementPublicKey: await senderAgreement.extractPublicKey(),
    );
    final bob = await bundle(
      identityId: 'chn:bob',
      deviceId: 'bob-phone',
      signingPublicKey: await recipientSigning.extractPublicKey(),
      agreementPublicKey: await recipientAgreement.extractPublicKey(),
    );
    final sealer = LoomRelaySealer();
    final codec = LoomDirectMessageCodec(
      signer: (payload) async =>
          (await ed.sign(payload, keyPair: senderSigning)).bytes,
      opener: ({required payload, required associatedData}) => sealer.open(
        payload: payload,
        recipientAgreementKeyPair: recipientAgreement,
        associatedData: associatedData,
      ),
    );
    final envelope = await codec.encryptText(
      conversationId: 'conv-a',
      plaintext: 'signed',
      senderAddress: '@alice:a.test',
      senderIdentityId: alice.identityId,
      senderDeviceId: alice.deviceId,
      recipientDevices: <LoomDeviceKeyBundle>[alice, bob],
    );
    final decoded = jsonDecode(envelope) as Map<String, Object?>;
    decoded['signature'] = base64Encode(List<int>.filled(64, 0));

    await expectLater(
      codec.decryptText(
        envelope: jsonEncode(decoded),
        expectedConversationId: 'conv-b',
        expectedSenderAddress: '@alice:a.test',
        localIdentityId: bob.identityId,
        localDeviceId: bob.deviceId,
        senderDevice: alice,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'participant identity substitution is rejected before decryption',
    () async {
      final ed = Ed25519();
      final x = X25519();
      final senderSigning = await ed.newKeyPair();
      final senderAgreement = await x.newKeyPair();
      final recipientAgreement = await x.newKeyPair();
      final recipientSigning = await ed.newKeyPair();
      final alice = await bundle(
        identityId: 'chn:alice',
        deviceId: 'alice-phone',
        signingPublicKey: await senderSigning.extractPublicKey(),
        agreementPublicKey: await senderAgreement.extractPublicKey(),
      );
      final bob = await bundle(
        identityId: 'chn:bob',
        deviceId: 'bob-phone',
        signingPublicKey: await recipientSigning.extractPublicKey(),
        agreementPublicKey: await recipientAgreement.extractPublicKey(),
      );
      final sealer = LoomRelaySealer();
      final codec = LoomDirectMessageCodec(
        signer: (payload) async =>
            (await ed.sign(payload, keyPair: senderSigning)).bytes,
        opener: ({required payload, required associatedData}) => sealer.open(
          payload: payload,
          recipientAgreementKeyPair: recipientAgreement,
          associatedData: associatedData,
        ),
      );
      final envelope = await codec.encryptText(
        conversationId: 'conv-a',
        plaintext: 'bound identities',
        senderAddress: '@alice:a.test',
        senderIdentityId: alice.identityId,
        senderDeviceId: alice.deviceId,
        recipientDevices: <LoomDeviceKeyBundle>[alice, bob],
      );
      final decoded = jsonDecode(envelope) as Map<String, Object?>;
      final boxes = (decoded['boxes'] as List).cast<Map<String, Object?>>();
      final bobBox = boxes.firstWhere((box) => box['identityId'] == 'chn:bob');
      bobBox['identityId'] = 'chn:mallory';

      await expectLater(
        codec.decryptText(
          envelope: jsonEncode(decoded),
          expectedConversationId: 'conv-b',
          expectedSenderAddress: '@alice:a.test',
          localIdentityId: bob.identityId,
          localDeviceId: bob.deviceId,
          senderDevice: alice,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
