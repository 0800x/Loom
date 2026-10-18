import 'package:loom_next/features/messaging/application/product_messaging_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy-only mode preserves existing product path', () async {
    var legacyCalls = 0;
    var v2Calls = 0;
    const dispatcher = LoomProductMessagingDispatcher(
      policy: LoomProductMessagingPolicy(),
    );

    final result = await dispatcher.dispatch<String>(
      legacy: () async {
        legacyCalls++;
        return 'legacy';
      },
      v2: (_) async {
        v2Calls++;
        return 'v2';
      },
    );
    expect(result, 'legacy');
    expect(legacyCalls, 1);
    expect(v2Calls, 0);
  });

  test(
    'v2-required mode fails closed and never invokes legacy fallback',
    () async {
      var legacyCalls = 0;
      const dispatcher = LoomProductMessagingDispatcher(
        policy: LoomProductMessagingPolicy(
          mode: LoomProductMessagingMode.v2Required,
        ),
      );

      await expectLater(
        dispatcher.dispatch<String>(
          legacy: () async {
            legacyCalls++;
            return 'legacy';
          },
          v2: (_) async => 'v2',
        ),
        throwsStateError,
      );
      expect(legacyCalls, 0);
    },
  );
}
