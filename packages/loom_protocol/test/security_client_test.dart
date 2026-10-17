import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final bundle = LoomDeviceKeyBundle(
    bundleVersion: 1,
    identityId: 'chn:test',
    deviceId: 'device-1',
    deviceName: 'Test',
    signingPublicKey: 'signing',
    agreementPublicKey: 'agreement',
    createdAt: DateTime.utc(2026, 9, 1),
    capabilities: const <String>[],
    fingerprint: 'fingerprint',
    deviceSignature: 'device-signature',
    identitySignature: 'identity-signature',
  );
  final deviceProofProvider = LoomDeviceRequestProofProvider(
    deviceId: 'dev_00000000-0000-0000-0000-000000000000',
    signer: (_) async => List<int>.filled(64, 0),
  );

  test(
    'security client rejects insecure remote endpoint before network access',
    () async {
      final client = LoomSecurityClient();
      await expectLater(
        client.publishDeviceBundle(
          baseUri: Uri.parse('http://example.org'),
          accessToken: 'token',
          bundle: bundle,
        ),
        throwsA(isA<LoomProtocolException>()),
      );
    },
  );

  test('security client rejects newline-bearing bearer token', () async {
    final client = LoomSecurityClient();
    await expectLater(
      client.listIdentityDevices(
        baseUri: Uri.parse('https://example.org'),
        accessToken: 'bad\ntoken',
        identityId: 'chn:test',
        identityPublicKey: 'unused',
        deviceProofProvider: deviceProofProvider,
      ),
      throwsA(isA<LoomProtocolException>()),
    );
  });
}
