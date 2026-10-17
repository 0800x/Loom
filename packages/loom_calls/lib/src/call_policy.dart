import 'package:loom_models/loom_models.dart';

class LoomCallDegradationPolicy {
  const LoomCallDegradationPolicy();

  LoomCallKind preferredKind({
    required LoomCallKind requested,
    required LoomCallQuality quality,
    required bool lowBandwidthMode,
  }) {
    if (requested == LoomCallKind.video &&
        (lowBandwidthMode || quality == LoomCallQuality.poor)) {
      return LoomCallKind.audio;
    }
    return requested;
  }

  bool shouldOfferPushToTalk(LoomCallQuality quality) =>
      quality == LoomCallQuality.poor;
}
