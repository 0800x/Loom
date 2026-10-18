import 'package:flutter_test/flutter_test.dart';
import 'package:loom_next/features/messaging/application/media_preparation.dart';

void main() {
  test('portrait and landscape video keep their orientation in chat', () {
    expect(LoomMediaPreparation.displayAspectRatio({'width': 1080, 'height': 1920}), 9 / 16);
    expect(LoomMediaPreparation.displayAspectRatio({'width': 1920, 'height': 1080}), 16 / 9);
    expect(LoomMediaPreparation.displayAspectRatio({'width': 1080.0, 'height': 1920.0}), 9 / 16);
  });
  test('unknown and invalid dimensions cannot create invalid layout', () {
    for (final media in <Map<String, Object?>>[
      {}, {'width': 0, 'height': 0}, {'width': double.nan, 'height': 10},
      {'width': double.infinity, 'height': 10}, {'width': 10, 'height': -1},
    ]) {
      expect(LoomMediaPreparation.displayAspectRatio(media), 1.3);
    }
  });
}
