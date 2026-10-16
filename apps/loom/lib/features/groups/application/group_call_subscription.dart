import 'package:livekit_client/livekit_client.dart' as lk;

/// LiveKit silently ignores subscribe() while its SFU grant is false. A zero-
/// grant join must not leave a track permanently marked as already requested.
Future<void> syncLoomGroupTrack(
  lk.RemoteTrackPublication track,
  Set<String> requested, {
  required bool authorized,
}) async {
  if (!authorized || !track.subscriptionAllowed) {
    requested.remove(track.sid);
    if (track.subscribed) await track.unsubscribe();
    return;
  }
  if (!requested.add(track.sid)) return;
  try {
    await track.subscribe();
    if (!track.subscriptionAllowed) requested.remove(track.sid);
  } catch (_) {
    requested.remove(track.sid);
    rethrow;
  }
}
