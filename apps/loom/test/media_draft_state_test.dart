import 'package:flutter_test/flutter_test.dart';
import 'support/media_draft_scenarios.dart';

void main() {
  for (final scenario in mediaDraftScenarios.entries) {
    test(scenario.key, scenario.value);
  }
}
