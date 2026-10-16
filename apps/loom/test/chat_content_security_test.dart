import 'dart:convert';
import 'dart:typed_data';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_next/features/messaging/application/encrypted_media.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Future<LoomDeviceKeyBundle> device(
  String identity,
  String id,
  SimpleKeyPair signing,
  SimpleKeyPair agreement,
) async => LoomDeviceKeyBundle(
  bundleVersion: 1,
  identityId: identity,
  deviceId: id,
  deviceName: id,
  signingPublicKey: base64Encode((await signing.extractPublicKey()).bytes),
  agreementPublicKey: base64Encode((await agreement.extractPublicKey()).bytes),
  createdAt: DateTime.utc(2026),
  capabilities: const ['signing-ed25519', 'agreement-x25519'],
  fingerprint: 'TEST',
  deviceSignature: base64Encode(List.filled(64, 1)),
  identitySignature: base64Encode(List.filled(64, 2)),
);

void main() {
  test(
    'authenticated quote survives another device without original history',
    () async {
      final ed = Ed25519(), x = X25519();
      final aliceSign = await ed.newKeyPair(),
          aliceAgree = await x.newKeyPair();
      final bobSign = await ed.newKeyPair(), bobAgree = await x.newKeyPair();
      final alice = await device('chn:alice', 'phone-a', aliceSign, aliceAgree);
      final bob = await device('chn:bob', 'phone-b', bobSign, bobAgree);
      final sealer = LoomRelaySealer();
      final codec = LoomDirectMessageCodec(
        signer: (bytes) async =>
            (await ed.sign(bytes, keyPair: aliceSign)).bytes,
        opener: ({required payload, required associatedData}) => sealer.open(
          payload: payload,
          recipientAgreementKeyPair: bobAgree,
          associatedData: associatedData,
        ),
      );
      const message = LoomMessageContent(
        text: 'reply',
        reply: {
          'clientId': 'stable-original-id',
          'sender': '@bob:b.test',
          'text': 'متن اصلی روی گوشی دوم',
        },
        location: {'lat': 35.7, 'lon': 51.4, 'at': 1000},
        attachment: {
          'kind': 'audio',
          'url': 'https://a.test/api/v1/attachments/att_test',
          'key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'bytes': 128,
        },
      );
      final envelope = await codec.encryptText(
        conversationId: 'node-a-row',
        plaintext: message.encode(),
        senderAddress: '@alice:a.test',
        senderIdentityId: alice.identityId,
        senderDeviceId: alice.deviceId,
        recipientDevices: [alice, bob],
        replyToMessageId: 'sender-node-original-row',
      );
      expect(envelope, isNot(contains('متن اصلی')));
      expect(envelope, isNot(contains('35.7')));
      expect(
        envelope,
        isNot(contains('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')),
      );
      final received = await codec.decryptText(
        envelope: envelope,
        expectedConversationId: 'node-b-different-row',
        expectedSenderAddress: '@alice:a.test',
        localIdentityId: bob.identityId,
        localDeviceId: bob.deviceId,
        senderDevice: alice,
        expectedReplyToMessageId: 'sender-node-original-row',
      );
      final content = LoomMessageContent.decode(received);
      expect(content.reply!['text'], 'متن اصلی روی گوشی دوم');
      expect(content.reply!['clientId'], 'stable-original-id');
      expect(content.attachment!['kind'], 'audio');
      await expectLater(
        codec.decryptText(
          envelope: envelope,
          expectedConversationId: 'node-b-different-row',
          expectedSenderAddress: '@alice:a.test',
          localIdentityId: bob.identityId,
          localDeviceId: bob.deviceId,
          senderDevice: alice,
          expectedReplyToMessageId: 'substituted-row',
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );
  test('legacy text and reserved-prefix text remain readable', () {
    expect(LoomMessageContent.decode('older message').text, 'older message');
    const text = '${LoomMessageContent.prefix}typed by the user';
    expect(
      LoomMessageContent.decode(
        const LoomMessageContent(text: text).encode(),
      ).text,
      text,
    );
  });
  test('malformed coordinates and unbounded live duration are rejected', () {
    for (final location in [
      {'lat': 91, 'lon': 2, 'at': 1},
      {'lat': 2, 'lon': 181, 'at': 1},
      {
        'lat': 2,
        'lon': 2,
        'at': 1,
        'session': 's',
        'until': 7200001,
        'stopped': false,
      },
    ]) {
      expect(
        () => LoomMessageContent.decode(
          LoomMessageContent(location: location).encode(),
        ),
        throwsFormatException,
      );
    }
  });
  test(
    'fresh file keys, authenticated decryption and tamper rejection',
    () async {
      final clear = Uint8List.fromList(utf8.encode('photo fixture'));
      final one = await LoomEncryptedMedia.encrypt(clear),
          two = await LoomEncryptedMedia.encrypt(clear);
      expect(one.key, isNot(two.key));
      expect(one.bytes, isNot(two.bytes));
      expect(
        await LoomEncryptedMedia.decrypt(one.bytes, one.key, clear.length),
        clear,
      );
      final tampered = Uint8List.fromList(one.bytes)..[13] ^= 1;
      await expectLater(
        LoomEncryptedMedia.decrypt(tampered, one.key, clear.length),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        LoomEncryptedMedia.decrypt(one.bytes, two.key, clear.length),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        LoomEncryptedMedia.decrypt(one.bytes, one.key, clear.length + 1),
        throwsFormatException,
      );
    },
  );
  test(
    'foreign/cleartext/path-injection media endpoint rejected before network',
    () async {
      for (final url in [
        'http://a.test/api/v1/attachments/att_${List.filled(64, 'a').join()}',
        'https://other.test/api/v1/attachments/att_${List.filled(64, 'a').join()}',
        'https://a.test/api/v1/attachments/../../secrets',
        'https://a.test/api/v1/attachments/att_${List.filled(64, 'a').join()}?redirect=x',
      ]) {
        await expectLater(
          LoomEncryptedMedia.download({
            'url': url,
            'key': '',
            'bytes': 2,
          }, 'a.test'),
          throwsFormatException,
        );
      }
    },
  );
}
