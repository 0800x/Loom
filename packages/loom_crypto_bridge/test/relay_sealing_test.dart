import 'dart:convert';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  test(
    'relay payload opens only with recipient key and bound metadata',
    () async {
      final x = X25519();
      final recipient = await x.newKeyPair();
      final publicKey = await recipient.extractPublicKey();
      final sealer = LoomRelaySealer();
      final aad = utf8.encode('bundle-1|tag-1');
      final sealed = await sealer.seal(
        plaintext: utf8.encode('opaque-inner-envelope'),
        recipientAgreementPublicKey: base64Encode(publicKey.bytes),
        associatedData: aad,
      );
      final opened = await sealer.open(
        payload: sealed,
        recipientAgreementKeyPair: recipient,
        associatedData: aad,
      );
      expect(utf8.decode(opened), 'opaque-inner-envelope');
      await expectLater(
        sealer.open(
          payload: sealed,
          recipientAgreementKeyPair: recipient,
          associatedData: utf8.encode('tampered'),
        ),
        throwsA(anything),
      );
    },
  );
}
