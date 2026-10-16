import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:test/test.dart';

void main() {
  test('registry schema version must be an integer', () {
    expect(
      () => LoomRegistryManifest.fromBytes(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'schemaVersion': '1',
            'generatedAt': DateTime.utc(2026).toIso8601String(),
            'nodes': <Object?>[],
          }),
        ),
      ),
      throwsFormatException,
    );
  });
}
