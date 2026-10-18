import 'dart:typed_data';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:loom_crypto_bridge/src/device_link_codec.dart';
import 'package:test/test.dart';

void main() {
  test(
    'authorization token hash matches the server UTF8 wire contract',
    () async {
      final codec = LoomDeviceLinkCodec();
      final token = codec.createToken();
      final hash = await Sha256().hash(utf8.encode(token));
      expect(
        await codec.tokenHash(token),
        hash.bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
      );
    },
  );
  test(
    'device-link QR round-trips only public routing and one-time token data',
    () {
      final codec = LoomDeviceLinkCodec();
      final linkId = codec.createLinkId();
      final token = codec.createToken();
      final encryptionSecret = codec.createEncryptionSecret();
      final encoded = codec.qrPayload(
        homeNode: 'chat.example.org',
        linkId: linkId,
        token: token,
        encryptionSecret: encryptionSecret,
      );

      expect(encoded, startsWith('loom-device-link:'));
      expect(encoded, isNot(contains('recovery')));
      final parsed = codec.parseQrPayload(encoded);
      expect(parsed.homeNode, 'chat.example.org');
      expect(parsed.linkId, linkId);
      expect(parsed.token, token);
      expect(parsed.encryptionSecret, encryptionSecret);
      expect(encryptionSecret, isNot(token));
    },
  );

  test('encrypted device-link package opens with the independent QR encryption secret', () async {
    final codec = LoomDeviceLinkCodec();
    final linkId = codec.createLinkId();
    final token = codec.createToken();
    final encryptionSecret = codec.createEncryptionSecret();
    final recovery = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final agreement = Uint8List.fromList(
      List<int>.generate(32, (i) => 255 - i),
    );

    final envelope = await codec.seal(
      linkId: linkId,
      encryptionSecret: encryptionSecret,
      identityId: 'chn:test-identity',
      sourceDeviceId: 'dev_11111111-1111-1111-1111-111111111111',
      recoveryEntropy: recovery,
      sourceAgreementSecret: agreement,
    );

    expect(envelope, isNot(contains('chn:test-identity')));
    // The malicious relay knows token, linkId, identity, device and envelope.
    // Reusing its legitimate authorization token as key material MUST fail.
    await expectLater(
      codec.open(
        envelope: envelope,
        linkId: linkId,
        encryptionSecret: token,
        expectedIdentityId: 'chn:test-identity',
        sourceDeviceId: 'dev_11111111-1111-1111-1111-111111111111',
      ),
      throwsA(isA<FormatException>()),
    );
    final opened = await codec.open(
      envelope: envelope,
      linkId: linkId,
      encryptionSecret: encryptionSecret,
      expectedIdentityId: 'chn:test-identity',
      sourceDeviceId: 'dev_11111111-1111-1111-1111-111111111111',
    );

    expect(opened.recoveryEntropy, orderedEquals(recovery));
    expect(opened.sourceAgreementSecret, orderedEquals(agreement));
  });

  test(
    'wrong encryption secret cannot decrypt a device-link package',
    () async {
      final codec = LoomDeviceLinkCodec();
      final linkId = codec.createLinkId();
      final encryptionSecret = codec.createEncryptionSecret();
      final envelope = await codec.seal(
        linkId: linkId,
        encryptionSecret: encryptionSecret,
        identityId: 'chn:test-identity',
        sourceDeviceId: 'dev_22222222-2222-2222-2222-222222222222',
        recoveryEntropy: List<int>.filled(32, 7),
        sourceAgreementSecret: List<int>.filled(32, 9),
      );

      await expectLater(
        codec.open(
          envelope: envelope,
          linkId: linkId,
          encryptionSecret: codec.createEncryptionSecret(),
          expectedIdentityId: 'chn:test-identity',
          sourceDeviceId: 'dev_22222222-2222-2222-2222-222222222222',
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
