import 'package:flutter_test/flutter_test.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

void main() {
  tearDown(() => LoomAccountScope.current = null);

  test('legacy installations retain their original key names', () {
    LoomAccountScope.current = null;

    expect(LoomAccountScope.scopedKey('loom.identity.v1'), 'loom.identity.v1');
  });

  test('account keys are namespaced by the active account ID', () {
    LoomAccountScope.current = const LoomAccountScope('account_123456');

    expect(
      LoomAccountScope.scopedKey('loom.identity.v1'),
      'loom.account.account_123456.loom.identity.v1',
    );
  });

  test('rejects malformed account scope identifiers', () {
    LoomAccountScope.current = const LoomAccountScope('../other-account');

    expect(
      () => LoomAccountScope.scopedKey('loom.identity.v1'),
      throwsStateError,
    );
  });
}
