import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:loom_sessions/loom_sessions.dart';

import 'security_store.dart';

typedef LoomAccountToIdentityIdResolver =
    Future<String?> Function(String accountId);

/// Bridges Architecture-v2 prekey authorization to the existing public device
/// trust cache without pretending v2 AccountId is the same value as v1
/// identityId.
///
/// [resolveIdentityId] must come from the authenticated account/device directory
/// migration layer. The resolver returns a key only for a locally verified,
/// non-revoked device. The current v1 device bundle format has no independent
/// key-version field, so this migration adapter accepts only device key version
/// 1 until the v2 device-directory model persists explicit versions.
final class LoomSecurityStoreDeviceSigningKeyResolver
    implements LoomAuthorizedDeviceSigningKeyResolver {
  const LoomSecurityStoreDeviceSigningKeyResolver({
    required this.securityStore,
    required this.resolveIdentityId,
  });

  final LoomSecurityStore securityStore;
  final LoomAccountToIdentityIdResolver resolveIdentityId;

  @override
  Future<LoomAuthorizedDeviceSigningKey?> resolveAuthorizedSigningKey({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required DateTime now,
  }) async {
    if (accountId.trim() != accountId ||
        accountId.isEmpty ||
        deviceId.trim() != deviceId ||
        deviceId.isEmpty ||
        deviceKeyVersion != 1) {
      return null;
    }
    final identityId = await resolveIdentityId(accountId);
    if (identityId == null || identityId.trim().isEmpty) return null;

    final matching = securityStore
        .listDevices(identityId)
        .where((known) => known.bundle.deviceId == deviceId)
        .toList(growable: false);
    if (matching.length != 1) return null;

    final known = matching.single;
    if (known.trustState != LoomDeviceTrustState.verified ||
        known.verifiedAt == null ||
        known.bundle.bundleVersion != 1) {
      return null;
    }

    Uint8List signingKey;
    try {
      signingKey = Uint8List.fromList(
        base64Decode(known.bundle.signingPublicKey),
      );
    } on FormatException {
      return null;
    }
    if (signingKey.length != 32) return null;

    return LoomAuthorizedDeviceSigningKey(
      accountId: accountId,
      deviceId: deviceId,
      deviceKeyVersion: deviceKeyVersion,
      ed25519PublicKey: signingKey,
    );
  }
}
