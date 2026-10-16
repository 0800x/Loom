import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);
  final bundle = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

  LoomPrekeyAuthorizationStatement statement() =>
      LoomPrekeyAuthorizationStatement(
        accountId: 'account-001',
        deviceId: 'device-001',
        deviceKeyVersion: 2,
        providerProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
        prekeyId: 'prekey-00000001',
        keyKind: LoomAuthorizedPrekeyKind.oneTime,
        providerBundle: bundle,
        notBefore: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(days: 7)),
      );

  test('canonical statement is deterministic and binds bundle digest', () {
    final first = statement();
    final second = statement();
    expect(first.canonicalBytes(), orderedEquals(second.canonicalBytes()));
    expect(first.authorizesBundle(bundle), isTrue);
    expect(
      first.authorizesBundle(Uint8List.fromList(<int>[1, 2, 3, 4, 6])),
      isFalse,
    );
  });

  test('verified result can only be obtained through trust verifier', () async {
    final signed = LoomAuthorizedPrekeyBundle(
      statement: statement(),
      providerBundle: bundle,
      deviceSignature: Uint8List.fromList(<int>[9, 9, 9]),
    );
    final trust = _RecordingTrustVerifier(accept: true);
    final verifier = LoomPrekeyAuthorizationVerifierV1(
      deviceSignatureVerifier: trust,
    );
    final verified = await verifier.verify(
      authorization: signed,
      now: now,
      expectedProviderProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
    );
    expect(verified.remoteAccountId, 'account-001');
    expect(verified.remoteDeviceId, 'device-001');
    expect(verified.remoteDeviceKeyVersion, 2);
    expect(verified.providerBundle, orderedEquals(bundle));
    expect(trust.calls, 1);
  });

  test('revoked or untrusted device fails closed', () async {
    final signed = LoomAuthorizedPrekeyBundle(
      statement: statement(),
      providerBundle: bundle,
      deviceSignature: Uint8List.fromList(<int>[9, 9, 9]),
    );
    final verifier = LoomPrekeyAuthorizationVerifierV1(
      deviceSignatureVerifier: _RecordingTrustVerifier(accept: false),
    );
    await expectLater(
      verifier.verify(
        authorization: signed,
        now: now,
        expectedProviderProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
      ),
      throwsFormatException,
    );
  });

  test(
    'wrong provider protocol and expired authorization fail closed',
    () async {
      final signed = LoomAuthorizedPrekeyBundle(
        statement: statement(),
        providerBundle: bundle,
        deviceSignature: Uint8List.fromList(<int>[9, 9, 9]),
      );
      final verifier = LoomPrekeyAuthorizationVerifierV1(
        deviceSignatureVerifier: _RecordingTrustVerifier(accept: true),
      );
      await expectLater(
        verifier.verify(
          authorization: signed,
          now: now,
          expectedProviderProtocolVersion: 'wrong-provider',
        ),
        throwsFormatException,
      );
      await expectLater(
        verifier.verify(
          authorization: signed,
          now: now.add(const Duration(days: 8)),
          expectedProviderProtocolVersion: 'Loom-Vodozemac-Olm-v1-poc',
        ),
        throwsFormatException,
      );
    },
  );

  test('authorization cannot be assembled with a substituted bundle', () {
    expect(
      () => LoomAuthorizedPrekeyBundle(
        statement: statement(),
        providerBundle: Uint8List.fromList(<int>[8, 8, 8]),
        deviceSignature: Uint8List.fromList(<int>[9]),
      ),
      throwsFormatException,
    );
  });
}

final class _RecordingTrustVerifier
    implements LoomAuthorizedDeviceSignatureVerifier {
  _RecordingTrustVerifier({required this.accept});

  final bool accept;
  int calls = 0;

  @override
  Future<bool> verifyAuthorizedDeviceSignature({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  }) async {
    calls += 1;
    expect(accountId, 'account-001');
    expect(deviceId, 'device-001');
    expect(deviceKeyVersion, 2);
    expect(canonicalPayload, isNotEmpty);
    expect(signature, orderedEquals(<int>[9, 9, 9]));
    return accept;
  }
}
