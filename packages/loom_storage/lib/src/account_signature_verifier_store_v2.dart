import 'dart:typed_data';

import 'package:loom_identity/loom_identity.dart';

import 'account_root_store_v2.dart';

/// Concrete local verification composition used by product code: account-root
/// material comes only from [rootStore], while Ed25519 verification is provided
/// by the identity package's production-shaped verifier.
final class LoomStoredAccountSignatureVerifierV2
    implements LoomAccountSignatureVerifierV2 {
  LoomStoredAccountSignatureVerifierV2({required this.rootStore})
    : _delegate = LoomEd25519AccountSignatureVerifierV2(
        rootResolver: rootStore,
      );

  final LoomAccountRootStoreV2 rootStore;
  final LoomEd25519AccountSignatureVerifierV2 _delegate;

  @override
  Future<bool> verifyAccountSignature({
    required LoomAccountId accountId,
    required int accountKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  }) => _delegate.verifyAccountSignature(
    accountId: accountId,
    accountKeyVersion: accountKeyVersion,
    canonicalPayload: canonicalPayload,
    signature: signature,
    now: now,
  );
}
