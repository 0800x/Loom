import 'dart:typed_data';

import 'package:loom_session_vodozemac_poc/loom_session_vodozemac_poc.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 20);
  final prekeyId = 'vpk_${List<String>.filled(64, 'a').join()}';
  final batchId = 'vpb_${List<String>.filled(64, 'b').join()}';

  test('server payload carries device-authorized opaque prekey envelope',
      () async {
    final bundle = const LoomVodozemacPocPrekeyBundle(
      identityKey: 'identity-key',
      oneTimeKey: 'one-time-key',
      keyKind: LoomVodozemacPocPrekeyKind.oneTime,
    ).encode();
    final item = LoomVodozemacPocPrekeyPublicationItem(
      prekeyId: prekeyId,
      keyKind: LoomVodozemacPocPrekeyKind.oneTime,
      bundle: bundle,
      expiresAt: now.add(const Duration(days: 28)),
    );
    final batch = LoomVodozemacPocPrekeyPublicationBatch(
      batchId: batchId,
      items: <LoomVodozemacPocPrekeyPublicationItem>[item],
      createdAt: now,
    );

    final payloads = await LoomVodozemacPocAuthorizedPrekeyPublication
        .authorizeBatchForServer(
      batch: batch,
      signer: const _DeterministicSigner(),
      localAccountId: 'account-v2-0001',
      localDeviceId: 'device-0001',
      localDeviceKeyVersion: 1,
      notBefore: now,
    );

    expect(payloads, hasLength(1));
    expect(payloads.single['prekeyId'], item.prekeyId);
    expect(payloads.single['keyKind'], 'one_time');
    final claimed =
        LoomVodozemacPocAuthorizedPrekeyPublication.decodeClaimedAuthorization(
      payloads.single['bundleBase64']! as String,
    );
    expect(claimed.statement.accountId, 'account-v2-0001');
    expect(claimed.statement.deviceId, 'device-0001');
    expect(claimed.statement.prekeyId, item.prekeyId);
    expect(
      claimed.statement.providerProtocolVersion,
      LoomVodozemacPocPrekeyBundle.protocol,
    );
    expect(claimed.statement.keyKind, LoomAuthorizedPrekeyKind.oneTime);
    expect(claimed.providerBundle, orderedEquals(bundle));
  });
}

final class _DeterministicSigner implements LoomPrekeyAuthorizationSigner {
  const _DeterministicSigner();

  @override
  Future<LoomAuthorizedPrekeyBundle> authorize({
    required LoomPrekeyAuthorizationStatement statement,
    required Uint8List providerBundle,
  }) async =>
      LoomAuthorizedPrekeyBundle(
        statement: statement,
        providerBundle: providerBundle,
        deviceSignature: Uint8List.fromList(List<int>.filled(64, 7)),
      );
}
