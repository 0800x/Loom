import 'package:loom_sessions/loom_sessions.dart';
import 'package:test/test.dart';

void main() {
  test(
    'private prekey survives claim delay plus DTN lifetime and safety margin',
    () {
      const policy = LoomPrekeyRetirementPolicy();
      final expires = DateTime.utc(2026, 9, 10);
      final safe = policy.earliestSafeRetirement(expires);
      expect(safe, DateTime.utc(2026, 9, 20));
      expect(
        policy.mayForgetPrivateMaterial(
          serverExpiresAt: expires,
          now: DateTime.utc(2026, 9, 19, 23, 59),
        ),
        isFalse,
      );
      expect(
        policy.mayForgetPrivateMaterial(serverExpiresAt: expires, now: safe),
        isTrue,
      );
    },
  );
}
