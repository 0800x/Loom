import 'package:loom_calls/loom_calls.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('outgoing ringing distinguishes calling from remote ringing', () {
    const initial = LoomCallSnapshot(
      lifecycle: LoomCallLifecycle.ringing,
      direction: LoomCallDirection.outgoing,
      callId: 'call-1',
      conversationId: 'conv-1',
      peerIdentityId: 'chn:peer',
      remoteRinging: false,
    );

    expect(initial.active, isTrue);
    expect(initial.remoteRinging, isFalse);

    final ringing = initial.copyWith(remoteRinging: true);
    expect(ringing.remoteRinging, isTrue);
    expect(ringing.callId, initial.callId);
  });

  test('connected/reconnecting remain active and ended is not active', () {
    final answered = DateTime.utc(2026, 9, 5, 10);
    final connected = LoomCallSnapshot(
      lifecycle: LoomCallLifecycle.connected,
      answeredAt: answered,
    );
    expect(connected.active, isTrue);

    expect(
      connected.copyWith(lifecycle: LoomCallLifecycle.reconnecting).active,
      isTrue,
    );
    expect(
      connected
          .copyWith(
            lifecycle: LoomCallLifecycle.ended,
            endedAt: answered.add(const Duration(minutes: 1)),
            endReason: LoomCallEndReason.remoteHangup,
          )
          .active,
      isFalse,
    );
  });

  test('mute camera speaker and remote video state copy independently', () {
    const state = LoomCallSnapshot(kind: LoomCallKind.video);
    final changed = state.copyWith(
      muted: true,
      cameraEnabled: true,
      speakerEnabled: true,
      remoteCameraEnabled: false,
      remoteVideoAvailable: false,
      quality: LoomCallQuality.constrained,
    );

    expect(changed.muted, isTrue);
    expect(changed.cameraEnabled, isTrue);
    expect(changed.speakerEnabled, isTrue);
    expect(changed.remoteCameraEnabled, isFalse);
    expect(changed.remoteVideoAvailable, isFalse);
    expect(changed.quality, LoomCallQuality.constrained);
  });
}
