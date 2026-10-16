part of 'playback_host.dart';

class _DesktopMusicPlayer extends StatelessWidget {
  const _DesktopMusicPlayer({
    required this.playback,
    required this.onQueue,
    required this.onPlaylists,
    required this.onSave,
  });
  final LoomPlaybackController playback;
  final VoidCallback onQueue, onPlaylists, onSave;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback,
    builder: (context, _) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () =>
            unawaited(playback.toggle()),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => unawaited(
          playback.seek(playback.position - const Duration(seconds: 5)),
        ),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => unawaited(
          playback.seek(playback.position + const Duration(seconds: 5)),
        ),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            unawaited(playback.volume.set(playback.volume.value + 5)),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            unawaited(playback.volume.set(playback.volume.value - 5)),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: LoomGlassAppBar(
            title: Text(tr(context, 'Music player', 'پخش‌کنندهٔ موسیقی')),
          ),
          body: LayoutBuilder(
            builder: (context, bounds) {
              final controls = Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Cover(
                      file: playback.artwork,
                      size: bounds.maxWidth >= 760 ? 220 : 140,
                      playing: playback.playing,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      playback.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      playback.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    ValueListenableBuilder<Duration>(
                      valueListenable: playback.timeline,
                      builder: (context, position, _) => Column(
                        children: [
                          Slider(
                            value: position.inMilliseconds.toDouble().clamp(
                              0,
                              playback.duration.inMilliseconds.toDouble().clamp(
                                1,
                                double.infinity,
                              ),
                            ),
                            max: playback.duration.inMilliseconds
                                .toDouble()
                                .clamp(1, double.infinity),
                            onChanged: playback.visible && !playback.loading
                                ? (value) => unawaited(
                                    playback.seek(
                                      Duration(milliseconds: value.round()),
                                    ),
                                  )
                                : null,
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                mediaTime(position),
                                textDirection: TextDirection.ltr,
                              ),
                              Text(
                                mediaTime(playback.duration),
                                textDirection: TextDirection.ltr,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          tooltip: tr(context, 'Shuffle', 'تصادفی'),
                          isSelected: playback.shuffle,
                          onPressed: playback.toggleShuffle,
                          icon: const Icon(LoomIcons.shuffle_rounded),
                        ),
                        IconButton(
                          tooltip: tr(context, 'Previous', 'قبلی'),
                          onPressed: playback.previous,
                          icon: const Icon(LoomIcons.skip_previous_rounded),
                        ),
                        IconButton.filled(
                          key: const ValueKey('full-player-transport'),
                          tooltip: tr(
                            context,
                            playback.playing ? 'Pause' : 'Play',
                            playback.playing ? 'مکث' : 'پخش',
                          ),
                          onPressed: playback.visible && !playback.loading
                              ? playback.toggle
                              : null,
                          iconSize: 36,
                          icon: Icon(
                            playback.playing
                                ? LoomIcons.pause_rounded
                                : LoomIcons.play_arrow_rounded,
                          ),
                        ),
                        IconButton(
                          tooltip: tr(context, 'Next', 'بعدی'),
                          onPressed: () => playback.next(),
                          icon: const Icon(LoomIcons.skip_next_rounded),
                        ),
                        IconButton(
                          tooltip: tr(context, 'Repeat', 'تکرار'),
                          isSelected: playback.repeat != 0,
                          onPressed: playback.cycleRepeat,
                          icon: Icon(
                            playback.repeat == 2
                                ? LoomIcons.repeat_one_rounded
                                : LoomIcons.repeat_rounded,
                          ),
                        ),
                      ],
                    ),
                    _PlaybackVolumeControl(playback: playback),
                    if (playback.error != null)
                      Text(
                        tr(
                          context,
                          'Playback unavailable. Choose another file.',
                          'پخش ممکن نیست؛ فایل دیگری انتخاب کنید.',
                        ),
                      ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: onQueue,
                          icon: const Icon(LoomIcons.queue_music_rounded),
                          label: Text(tr(context, 'Queue', 'صف پخش')),
                        ),
                        TextButton.icon(
                          onPressed: onPlaylists,
                          icon: const Icon(LoomIcons.playlist_play_rounded),
                          label: Text(tr(context, 'Playlists', 'پلی‌لیست‌ها')),
                        ),
                        TextButton.icon(
                          onPressed: onSave,
                          icon: const Icon(LoomIcons.playlist_add_rounded),
                          label: Text(
                            tr(context, 'Save playlist', 'ذخیره پلی‌لیست'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
              if (bounds.maxWidth < 760) {
                return SingleChildScrollView(child: controls);
              }
              return Row(
                children: [
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: controls,
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: (bounds.maxWidth * .3).clamp(240, 360),
                    child: Column(
                      children: [
                        ListTile(
                          title: Text(tr(context, 'Up next', 'در ادامه')),
                          subtitle: Text('${playback.queue.length}'),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: playback.queue.length,
                            itemBuilder: (context, index) {
                              final track = playback.queue[index];
                              return ListTile(
                                selected: track.id == playback.sourceId,
                                leading: _Cover(
                                  file: track.artwork,
                                  size: 40,
                                  playing: false,
                                ),
                                title: Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => playback.playTrack(track.id),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class LoomMusicPreview extends StatefulWidget {
  const LoomMusicPreview({required this.file, super.key});
  final File file;
  @override
  State<LoomMusicPreview> createState() => _LoomMusicPreviewState();
}

class _LoomMusicPreviewState extends State<LoomMusicPreview> {
  late final _tags = LoomPlaybackController.inspectMusic(widget.file);
  @override
  void dispose() {
    final playback = LoomPlaybackController.voice;
    if (playback.isSource(widget.file)) unawaited(playback.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<(String?, String?, Uint8List?)>(
        future: _tags,
        builder: (context, snapshot) => LoomAudioTile(
          file: widget.file,
          title: snapshot.data?.$1 ?? widget.file.uri.pathSegments.last,
          subtitle: snapshot.data?.$2 ?? '',
          artworkBytes: snapshot.data?.$3,
          music: true,
        ),
      );
}

/// Position ticks rebuild the active audio row only. State changes (play/pause,
/// source selection, metadata) still reach every row so controls remain correct.
