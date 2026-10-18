import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 20);

  LoomAuthorizedPrekeyBundle authorization() {
    final bundle = Uint8List.fromList(List<int>.generate(48, (i) => i + 1));
    final statement = LoomPrekeyAuthorizationStatement(
      accountId: 'account-v2-0001',
      deviceId: 'device-0001',
      deviceKeyVersion: 1,
      providerProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
      prekeyId: 'prekey-00000001',
      keyKind: LoomAuthorizedPrekeyKind.oneTime,
      providerBundle: bundle,
      notBefore: now,
      expiresAt: now.add(const Duration(days: 28)),
    );
    return LoomAuthorizedPrekeyBundle(
      statement: statement,
      providerBundle: bundle,
      deviceSignature: Uint8List.fromList(
        List<int>.generate(64, (i) => 63 - i),
      ),
    );
  }

  test('round trips exact signed authorization material', () {
    final source = authorization();
    final encoded = LoomAuthorizedPrekeyWireV1.encode(source);
    final decoded = LoomAuthorizedPrekeyWireV1.decode(encoded);

    expect(decoded.statement.accountId, source.statement.accountId);
    expect(decoded.statement.deviceId, source.statement.deviceId);
    expect(
      decoded.statement.deviceKeyVersion,
      source.statement.deviceKeyVersion,
    );
    expect(
      decoded.statement.providerProtocolVersion,
      source.statement.providerProtocolVersion,
    );
    expect(decoded.statement.prekeyId, source.statement.prekeyId);
    expect(decoded.statement.keyKind, source.statement.keyKind);
    expect(decoded.statement.notBefore, source.statement.notBefore);
    expect(decoded.statement.expiresAt, source.statement.expiresAt);
    expect(decoded.providerBundle, orderedEquals(source.providerBundle));
    expect(decoded.deviceSignature, orderedEquals(source.deviceSignature));
    expect(decoded.statement.authorizesBundle(decoded.providerBundle), isTrue);
  });

  test('rejects unknown fields and provider-bundle tampering', () {
    final encoded = LoomAuthorizedPrekeyWireV1.encode(authorization());
    final text = String.fromCharCodes(encoded);
    final withUnknown = Uint8List.fromList(
      '$text'.replaceFirst('{', '{"unknown":1,').codeUnits,
    );
    expect(
      () => LoomAuthorizedPrekeyWireV1.decode(withUnknown),
      throwsFormatException,
    );

    final decoded = LoomAuthorizedPrekeyWireV1.decode(encoded);
    final tampered = Uint8List.fromList(decoded.providerBundle);
    tampered[0] ^= 0xff;
    expect(decoded.statement.authorizesBundle(tampered), isFalse);
  });

  test(
    'rejects expired or unsupported material at verifier boundary',
    () async {
      final source = authorization();
      const verifier = LoomPrekeyAuthorizationVerifierV1(
        deviceSignatureVerifier: const _AlwaysTrustedSignatureVerifier(),
      );
      await expectLater(
        verifier.verify(
          authorization: source,
          now: now.add(const Duration(days: 29)),
          expectedProviderProtocolVersion:
              source.statement.providerProtocolVersion,
        ),
        throwsFormatException,
      );
    },
  );
}

final class _AlwaysTrustedSignatureVerifier
    implements LoomAuthorizedDeviceSignatureVerifier {
  const _AlwaysTrustedSignatureVerifier();

  @override
  Future<bool> verifyAuthorizedDeviceSignature({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  }) async =>
      true;
}
