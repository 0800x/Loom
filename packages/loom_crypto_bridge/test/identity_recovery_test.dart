import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'generated recovery words reconstruct the same public identity',
    () async {
      final core = LoomIdentityCoreV1();
      final created = await core.createIdentity();
      expect(created.recovery.mnemonicWords, hasLength(24));

      final restored = await core.restoreIdentityFromWords(
        created.recovery.mnemonicWords,
      );
      expect(restored.identity.identityId, created.identity.identityId);
      expect(restored.identity.publicKey, created.identity.publicKey);
      expect(restored.identity.fingerprint, created.identity.fingerprint);
    },
  );
}
