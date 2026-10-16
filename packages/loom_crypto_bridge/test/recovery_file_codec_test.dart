import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encrypted recovery file round trips generated words', () async {
    final core = LoomIdentityCoreV1();
    final pending = await core.createIdentity();
    final codec = LoomRecoveryFileCodec(memoryKiB: 1024, iterations: 1);
    final encrypted = await codec.encryptWords(
      words: pending.recovery.mnemonicWords,
      password: 'test-only-password-123',
    );
    final restored = await codec.decryptWords(
      fileBytes: encrypted,
      password: 'test-only-password-123',
    );
    expect(restored, pending.recovery.mnemonicWords);
  });

  test('encrypted recovery file rejects wrong password', () async {
    final core = LoomIdentityCoreV1();
    final pending = await core.createIdentity();
    final codec = LoomRecoveryFileCodec(memoryKiB: 1024, iterations: 1);
    final encrypted = await codec.encryptWords(
      words: pending.recovery.mnemonicWords,
      password: 'test-only-password-123',
    );
    expect(
      () => codec.decryptWords(
        fileBytes: encrypted,
        password: 'wrong-password-123',
      ),
      throwsFormatException,
    );
  });
}
