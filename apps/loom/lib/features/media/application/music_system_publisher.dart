import 'package:audio_service/audio_service.dart';

/// MediaItem equality compares IDs only. A late duration/cover/tag update for
/// the same track must still be published to the Android/iOS media session.
class LoomMusicSystemPublisher {
  LoomMusicSystemPublisher(this.handler);
  final BaseAudioHandler handler;
  MediaItem? _item;
  List<MediaItem> _queue = const [];
  bool _published = false;

  void publish({
    required MediaItem? item,
    required List<MediaItem> queue,
    required PlaybackState state,
  }) {
    if (!_published || !_sameMetadata(item, _item)) {
      _item = item;
      handler.mediaItem.add(item);
    }
    if (!_published ||
        queue.length != _queue.length ||
        List.generate(
          queue.length,
          (i) => i,
        ).any((i) => !_sameMetadata(queue[i], _queue[i]))) {
      _queue = List.unmodifiable(queue);
      handler.queue.add(_queue);
    }
    _published = true;
    handler.playbackState.add(state);
  }

  static bool _sameMetadata(MediaItem? a, MediaItem? b) =>
      a?.id == b?.id &&
      a?.title == b?.title &&
      a?.artist == b?.artist &&
      a?.album == b?.album &&
      a?.duration == b?.duration &&
      a?.artUri == b?.artUri &&
      a?.playable == b?.playable;
}
