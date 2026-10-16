import 'dart:typed_data';

import 'package:loom_identity/loom_identity.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  test('Ed25519 verifier accepts exact trusted account root version only', () async {
    final now = DateTime.utc(2026, 9, 6, 8);
    final accountId = LoomAccountId.generate();
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    final signature = await algorithm.sign(payload, keyPair: keyPair);
    final resolver = _RootResolver(
      LoomTrustedAccountRootKeyV2(
        accountId: accountId,
        accountKeyVersion: 4,
        ed25519PublicKey: Uint8List.fromList(publicKey.bytes),
        validFrom: now.subtract(const Duration(days: 1)),
        validUntil: now.add(const Duration(days: 30)),
      ),
    );
    final verifier = LoomEd25519AccountSignatureVerifierV2(
      rootResolver: resolver,
    );

    expect(
      await verifier.verifyAccountSignature(
        accountId: accountId,
        accountKeyVersion: 4,
        canonicalPayload: payload,
        signature: Uint8List.fromList(signature.bytes),
        now: now,
      ),
      isTrue,
    );
    expect(
      await verifier.verifyAccountSignature(
        accountId: accountId,
        accountKeyVersion: 3,
        canonicalPayload: payload,
        signature: Uint8List.fromList(signature.bytes),
        now: now,
      ),
      isFalse,
      reason: 'a directory cannot silently select a different root version',
    );
  });

  test('Ed25519 verifier rejects tampering and expired trust roots', () async {
    final now = DateTime.utc(2026, 9, 6, 8);
    final accountId = LoomAccountId.generate();
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final payload = Uint8List.fromList(<int>[9, 8, 7]);
    final signature = await algorithm.sign(payload, keyPair: keyPair);
    final expired = _RootResolver(
      LoomTrustedAccountRootKeyV2(
        accountId: accountId,
        accountKeyVersion: 1,
        ed25519PublicKey: Uint8List.fromList(publicKey.bytes),
        validFrom: now.subtract(const Duration(days: 30)),
        validUntil: now.subtract(const Duration(seconds: 1)),
      ),
    );
    final verifier = LoomEd25519AccountSignatureVerifierV2(
      rootResolver: expired,
    );

    expect(
      await verifier.verifyAccountSignature(
        accountId: accountId,
        accountKeyVersion: 1,
        canonicalPayload: payload,
        signature: Uint8List.fromList(signature.bytes),
        now: now,
      ),
      isFalse,
    );
  });
}

final class _RootResolver implements LoomTrustedAccountRootResolverV2 {
  const _RootResolver(this.root);
  final LoomTrustedAccountRootKeyV2 root;

  @override
  Future<LoomTrustedAccountRootKeyV2?> resolveTrustedAccountRoot({
    required LoomAccountId accountId,
    required int accountKeyVersion,
    required DateTime now,
  }) async {
    if (root.accountId != accountId ||
        root.accountKeyVersion != accountKeyVersion ||
        !root.isValidAt(now)) {
      return null;
    }
    return root;
  }
}
