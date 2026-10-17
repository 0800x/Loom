import 'package:loom_sessions/loom_sessions.dart';
import 'package:test/test.dart';

void main() {
  test('state protection context accepts bounded opaque identifiers', () {
    expect(
      () => validateLoomStateProtectionContext(
        contextId: 'provider-state-device-0001',
        revision: 42,
      ),
      returnsNormally,
    );
  });

  test('state protection context rejects ambiguous or unbounded input', () {
    for (final value in <String>[
      ' short ',
      'bad\ncontext',
      'bad\rcontext',
      'bad\u0000context',
    ]) {
      expect(
        () => validateLoomStateProtectionContext(contextId: value, revision: 0),
        throwsFormatException,
      );
    }
    expect(
      () => validateLoomStateProtectionContext(
        contextId: 'provider-state-device-0001',
        revision: -1,
      ),
      throwsFormatException,
    );
    expect(
      () => validateLoomStateProtectionContext(
        contextId: 'provider-state-device-0001',
        revision: 0x8000000000000000,
      ),
      throwsFormatException,
    );
  });
}
