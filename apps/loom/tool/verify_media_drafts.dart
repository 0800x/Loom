import '../test/support/media_draft_scenarios.dart';

/// Runs the exact controller scenarios also registered with flutter_test,
/// without loading Flutter, a platform plugin, or a network dependency.
Future<void> main() async {
  for (final scenario in mediaDraftScenarios.entries) {
    await scenario.value();
    // This command-line verifier intentionally reports scenario results.
    // ignore: avoid_print
    print('PASS ${scenario.key}');
  }
}
