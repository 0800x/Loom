import 'package:audio_service/audio_service.dart';
import 'package:loom_next/features/media/application/music_system_publisher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('late metadata reaches system for the same music ID', () async {
    final handler = BaseAudioHandler();
    final publisher = LoomMusicSystemPublisher(handler);
    const first = MediaItem(id: 'track', title: 'Song', duration: Duration.zero);
    final loaded = first.copyWith(duration: const Duration(minutes: 4),
      artist: 'Artist', artUri: Uri.file('/private/cover.jpg'));
    // This is the regression: ID equality cannot detect new duration/artwork.
    expect(first == loaded, isTrue);
    publisher.publish(item: first, queue: [first], state: PlaybackState(
      processingState: AudioProcessingState.loading));
    publisher.publish(item: loaded, queue: [loaded], state: PlaybackState(
      processingState: AudioProcessingState.ready, playing: true, queueIndex: 0));
    expect(handler.mediaItem.value!.duration, const Duration(minutes: 4));
    expect(handler.mediaItem.value!.artist, 'Artist');
    expect(handler.mediaItem.value!.artUri, Uri.file('/private/cover.jpg'));
    expect(handler.queue.value.single.duration, const Duration(minutes: 4));
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.queueIndex, 0);
    await handler.mediaItem.close();
    await handler.queue.close();
    await handler.playbackState.close();
  });

  test('pause retains current item and stop clears system metadata and queue', () async {
    final handler = BaseAudioHandler();
    final publisher = LoomMusicSystemPublisher(handler);
    const item = MediaItem(id: 'track', title: 'Song');
    publisher.publish(item: item, queue: [item], state: PlaybackState(
      processingState: AudioProcessingState.ready, playing: true));
    publisher.publish(item: item, queue: [item], state: PlaybackState(
      processingState: AudioProcessingState.ready, playing: false,
      updatePosition: const Duration(seconds: 12)));
    expect(handler.mediaItem.value!.id, 'track');
    expect(handler.playbackState.value.updatePosition, const Duration(seconds: 12));
    publisher.publish(item: null, queue: [], state: PlaybackState(
      processingState: AudioProcessingState.idle));
    expect(handler.mediaItem.value, isNull);
    expect(handler.queue.value, isEmpty);
    expect(handler.playbackState.value.processingState, AudioProcessingState.idle);
    await handler.mediaItem.close();
    await handler.queue.close();
    await handler.playbackState.close();
  });
}
