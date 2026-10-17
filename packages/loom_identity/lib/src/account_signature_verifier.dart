import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'device_directory_v2.dart';
import 'ids.dart';

/// One locally trusted account-root signing key version.
///
/// Delivery/federation servers are not authoritative for this value. A concrete
/// resolver should obtain it from the authenticated account identity/recovery
/// layer and apply sticky key-rotation/recovery policy before returning it.
final class LoomTrustedAccountRootKeyV2 {
  LoomTrustedAccountRootKeyV2({
    required this.accountId,
    required this.accountKeyVersion,
    required Uint8List ed25519PublicKey,
    required this.validFrom,
    this.validUntil,
  }) : ed25519PublicKey = Uint8List.fromList(ed25519PublicKey) {
    if (accountKeyVersion < 1 || accountKeyVersion > 0x7fffffff ||
        this.ed25519PublicKey.length != 32) {
      throw const FormatException('Invalid trusted account root key');
    }
    final from = validFrom.toUtc();
    final until = validUntil?.toUtc();
    if (from.year < 2020 || from.year >= 2200 ||
        (until != null && !until.isAfter(from))) {
      throw const FormatException('Invalid account root validity window');
    }
  }

  final LoomAccountId accountId;
  final int accountKeyVersion;
  final Uint8List ed25519PublicKey;
  final DateTime validFrom;
  final DateTime? validUntil;

  bool isValidAt(DateTime now) {
    final current = now.toUtc();
    final until = validUntil?.toUtc();
    return !current.isBefore(validFrom.toUtc()) &&
        (until == null || current.isBefore(until));
  }
}

/// Resolves an exact account-root key version from the local authenticated
/// identity/recovery trust domain.
///
/// Implementations MUST return null for unknown, rolled-back, revoked or
/// superseded versions. In particular, an untrusted directory response must not
/// be able to introduce its own root key here.
abstract interface class LoomTrustedAccountRootResolverV2 {
  Future<LoomTrustedAccountRootKeyV2?> resolveTrustedAccountRoot({
    required LoomAccountId accountId,
    required int accountKeyVersion,
    required DateTime now,
  });
}

/// Production-shaped Ed25519 implementation of [LoomAccountSignatureVerifierV2].
///
/// Only the exact account/key-version tuple returned by [rootResolver] is used.
/// Directory objects cannot select a different public key after resolution.
final class LoomEd25519AccountSignatureVerifierV2
    implements LoomAccountSignatureVerifierV2 {
  LoomEd25519AccountSignatureVerifierV2({
    required this.rootResolver,
    Ed25519? algorithm,
  }) : _algorithm = algorithm ?? Ed25519();

  final LoomTrustedAccountRootResolverV2 rootResolver;
  final Ed25519 _algorithm;

  @override
  Future<bool> verifyAccountSignature({
    required LoomAccountId accountId,
    required int accountKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  }) async {
    if (accountKeyVersion < 1 ||
        canonicalPayload.isEmpty ||
        canonicalPayload.length > 1024 * 1024 ||
        signature.length != 64) {
      return false;
    }
    final trusted = await rootResolver.resolveTrustedAccountRoot(
      accountId: accountId,
      accountKeyVersion: accountKeyVersion,
      now: now.toUtc(),
    );
    if (trusted == null ||
        trusted.accountId != accountId ||
        trusted.accountKeyVersion != accountKeyVersion ||
        !trusted.isValidAt(now)) {
      return false;
    }

    final publicKey = SimplePublicKey(
      trusted.ed25519PublicKey,
      type: KeyPairType.ed25519,
    );
    try {
      return await _algorithm.verify(
        canonicalPayload,
        signature: Signature(signature, publicKey: publicKey),
      );
    } on ArgumentError {
      return false;
    } on StateError {
      return false;
    }
  }
}
