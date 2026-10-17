import 'package:loom_calls/loom_calls.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = LoomCallDegradationPolicy();
  test('poor video degrades to audio', () {
    expect(
      policy.preferredKind(
        requested: LoomCallKind.video,
        quality: LoomCallQuality.poor,
        lowBandwidthMode: false,
      ),
      LoomCallKind.audio,
    );
  });
  test('good video remains video', () {
    expect(
      policy.preferredKind(
        requested: LoomCallKind.video,
        quality: LoomCallQuality.good,
        lowBandwidthMode: false,
      ),
      LoomCallKind.video,
    );
  });
}
