import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'namespace cutover preserves the zero-entropy Ed25519 identity',
    () async {
      final core = LoomIdentityCoreV1();
      final pending = await core.restoreIdentityFromWords([
        ...List<String>.filled(23, 'abandon'),
        'art',
      ]);
      expect(
        pending.identity.publicKey,
        'O2onvM62pC1io6jQKm8Nc2UyFXcd4kOmOsBIoYtZ2ik=',
      );
      await core.commitPendingIdentity(pending);
      final restored = await core.readIdentity();
      expect(restored?.publicKey, pending.identity.publicKey);
      expect(restored?.identityId, pending.identity.identityId);
      expect(await core.exportRecoveryEntropy(), List<int>.filled(32, 0));
    },
  );

  test(
    'unsupported protected values fail without replacing stored material',
    () async {
      const key = 'loom.identity.ed25519.private.v1';
      const sealed = 'foreign-protected-v1:opaque-existing-material';
      FlutterSecureStorage.setMockInitialValues({key: sealed});
      final store = LoomSecretStorage();
      await expectLater(
        store.read(key: key),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'unsupported_vault_format',
          ),
        ),
      );
      expect(await const FlutterSecureStorage().read(key: key), sealed);
    },
  );

  test(
    'recovery rejects a foreign format before deriving a password key',
    () async {
      final codec = LoomRecoveryFileCodec(memoryKiB: 1024, iterations: 1);
      await expectLater(
        codec.decryptWords(
          fileBytes: utf8.encode(jsonEncode({'format': 'Foreign-Recovery-v1'})),
          password: 'test-only-password-123',
        ),
        throwsFormatException,
      );
      expect(LoomRecoveryFileCodec.format, 'Loom-Recovery-v1');
    },
  );
}
