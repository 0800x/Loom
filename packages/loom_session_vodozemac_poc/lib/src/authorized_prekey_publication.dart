import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';

import 'prekey_bundle.dart';
import 'prekey_lifecycle.dart';

/// Converts a durable PoC publication batch into the exact opaque objects sent
/// to `/api/v2/prekeys` after binding every provider bundle to the local Loom
/// device authorization key.
///
/// The delivery service stores [bundleBase64] opaquely. Recipients must decode
/// it with [decodeClaimedAuthorization] and run [LoomPrekeyAuthorizationVerifierV1]
/// before passing provider bytes to session establishment.
final class LoomVodozemacPocAuthorizedPrekeyPublication {
  const LoomVodozemacPocAuthorizedPrekeyPublication._();

  static Future<List<Map<String, Object?>>> authorizeBatchForServer({
    required LoomVodozemacPocPrekeyPublicationBatch batch,
    required LoomPrekeyAuthorizationSigner signer,
    required String localAccountId,
    required String localDeviceId,
    required int localDeviceKeyVersion,
    required DateTime notBefore,
  }) async {
    final start = notBefore.toUtc();
    final result = <Map<String, Object?>>[];
    for (final item in batch.items) {
      final kind = switch (item.keyKind) {
        LoomVodozemacPocPrekeyKind.oneTime => LoomAuthorizedPrekeyKind.oneTime,
        LoomVodozemacPocPrekeyKind.fallback =>
          LoomAuthorizedPrekeyKind.fallback,
      };
      final statement = LoomPrekeyAuthorizationStatement(
        accountId: localAccountId,
        deviceId: localDeviceId,
        deviceKeyVersion: localDeviceKeyVersion,
        providerProtocolVersion: LoomVodozemacPocPrekeyBundle.protocol,
        prekeyId: item.prekeyId,
        keyKind: kind,
        providerBundle: item.bundle,
        notBefore: start,
        expiresAt: item.expiresAt.toUtc(),
      );
      final authorization = await signer.authorize(
        statement: statement,
        providerBundle: item.bundle,
      );
      final wire = LoomAuthorizedPrekeyWireV1.encode(authorization);
      result.add(<String, Object?>{
        'prekeyId': item.prekeyId,
        'keyKind': item.keyKind.wireName,
        'bundleBase64': _base64UrlNoPadding(wire),
        'expiresAt': item.expiresAt.toUtc().toIso8601String(),
      });
    }
    return List<Map<String, Object?>>.unmodifiable(result);
  }

  static LoomAuthorizedPrekeyBundle decodeClaimedAuthorization(
    String bundleBase64,
  ) {
    if (bundleBase64.isEmpty ||
        bundleBase64.length > LoomAuthorizedPrekeyWireV1.maxWireBytes * 2 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(bundleBase64)) {
      throw const FormatException('Invalid claimed prekey authorization');
    }
    final padding = (4 - bundleBase64.length % 4) % 4;
    final padded = '$bundleBase64${List<String>.filled(padding, '=').join()}';
    final bytes = base64Url.decode(padded);
    return LoomAuthorizedPrekeyWireV1.decode(Uint8List.fromList(bytes));
  }

  static String _base64UrlNoPadding(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}
