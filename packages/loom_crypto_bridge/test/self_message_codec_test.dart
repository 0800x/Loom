import 'dart:convert';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final entropy = List<int>.generate(32, (index) => index);

  LoomSelfMessageCodec codec() => LoomSelfMessageCodec(
    recoveryEntropyProvider: () async => List<int>.from(entropy),
  );

  test(
    'Saved Message round-trips with identity and conversation binding',
    () async {
      final value = await codec().encryptText(
        identityId: 'chn:alice',
        conversationId: 'self-1',
        plaintext: 'سلام لوم',
      );

      expect(value, isNot(contains('سلام')));
      expect(
        await codec().decryptText(
          identityId: 'chn:alice',
          conversationId: 'self-1',
          envelope: value,
        ),
        'سلام لوم',
      );
    },
  );

  test('Saved Message cannot be moved to another conversation', () async {
    final value = await codec().encryptText(
      identityId: 'chn:alice',
      conversationId: 'self-1',
      plaintext: 'private',
    );

    await expectLater(
      codec().decryptText(
        identityId: 'chn:alice',
        conversationId: 'self-2',
        envelope: value,
      ),
      throwsFormatException,
    );
  });

  test('Saved Message rejects tampered ciphertext', () async {
    final value = await codec().encryptText(
      identityId: 'chn:alice',
      conversationId: 'self-1',
      plaintext: 'private',
    );
    final json = jsonDecode(value) as Map<String, Object?>;
    final bytes = base64Decode(json['ciphertext']! as String);
    bytes[0] ^= 1;
    json['ciphertext'] = base64Encode(bytes);

    await expectLater(
      codec().decryptText(
        identityId: 'chn:alice',
        conversationId: 'self-1',
        envelope: jsonEncode(json),
      ),
      throwsFormatException,
    );
  });
}
