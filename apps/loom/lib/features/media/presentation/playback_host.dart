import 'dart:async';
import 'dart:io';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';
import '../application/playback_controller.dart';

part 'desktop_music_player.dart';

Duration _motionDuration(BuildContext context, int milliseconds) =>
    LoomAccessibility.fromContext(context).reduceMotion
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

String mediaTime(Duration v) =>
    '${v.inMinutes}:${(v.inSeconds % 60).toString().padLeft(2, '0')}';

class LoomPlaybackHost extends StatelessWidget {
  static final _miniPlayerKey = GlobalKey();
  const LoomPlaybackHost({
    required this.child,
    required this.navigatorKey,
    super.key,
  });
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  @override
  Widget build(BuildContext context) {
    final playback = LoomPlaybackController.instance;
    return AnimatedBuilder(
      animation: playback,
      builder: (context, _) => Overlay.wrap(
        child: Column(
          children: [
            AnimatedSwitcher(
              duration: LoomAccessibility.fromContext(context).reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              transitionBuilder: (child, animation) => SizeTransition(
                sizeFactor: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: !playback.visible || !playback.music || playback.expanded
                  ? const SizedBox.shrink()
                  : LoomGlassSurface(
                      liveBackdrop: true,
                      radius: 0,
                      child: Material(
                        color: Colors.transparent,
                        child: SafeArea(
                          bottom: false,
                          child: SizedBox(
                            key: _miniPlayerKey,
                            height: 60,
                            child: Row(
                              children: [
                                const SizedBox(width: 8),
                                if (playback.music)
                                  _Cover(
                                    file: playback.artwork,
                                    size: 42,
                                    playing: playback.playing,
                                  ),
                                IconButton(
                                  tooltip: tr(
                                    context,
                                    playback.playing ? 'Pause' : 'Play',
                                    playback.playing ? 'مکث' : 'پخش',
                                  ),
                                  onPressed: playback.loading
                                      ? null
                                      : playback.toggle,
                                  icon: playback.loading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Icon(
                                          playback.playing
                                              ? LoomIcons.pause_rounded
                                              : LoomIcons.play_arrow_rounded,
                                        ),
                                ),
                                Expanded(
                                  child: InkWell(
                                    onTap: () async {
                                      final navigator =
                                          navigatorKey.currentState;
                                      if (navigator == null) return;
                                      if (playback.expanded) return;
                                      final origin = LoomOrigin.of(
                                        _miniPlayerKey.currentContext,
                                      );
                                      playback.setExpanded(true);
                                      try {
                                        await showLoomSurface<void>(
                                          context: navigator.context,
                                          origin: origin,
                                          identity: 'music-player',
                                          fullscreen: true,
                                          builder: (_) =>
                                              const _PlaybackDetails(),
                                        );
                                      } finally {
                                        playback.setExpanded(false);
                                      }
                                    },
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          playback.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                        ValueListenableBuilder<Duration>(
                                          valueListenable: playback.timeline,
                                          builder: (context, _, _) => Text(
                                            playback.error != null
                                                ? tr(
                                                    context,
                                                    'Format unavailable on this device',
                                                    'فرمت روی این دستگاه پشتیبانی نمی‌شود',
                                                  )
                                                : '${playback.subtitle} · ${mediaTime(playback.position)} / ${mediaTime(playback.duration)}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (playback.music)
                                  IconButton(
                                    tooltip: tr(
                                      context,
                                      'Next track',
                                      'آهنگ بعدی',
                                    ),
                                    onPressed: () => playback.next(),
                                    icon: const Icon(
                                      LoomIcons.skip_next_rounded,
                                    ),
                                  )
                                else
                                  TextButton(
                                    onPressed: playback.changeSpeed,
                                    child: Text('${playback.speed}×'),
                                  ),
                                if (Platform.isWindows &&
                                    MediaQuery.sizeOf(context).width >= 600)
                                  SizedBox(
                                    width: 190,
                                    child: _PlaybackVolumeControl(
                                      playback: playback,
                                    ),
                                  ),
                                IconButton(
                                  tooltip: tr(
                                    context,
                                    'Close player',
                                    'بستن پخش‌کننده',
                                  ),
                                  onPressed: playback.close,
                                  icon: const Icon(LoomIcons.close_rounded),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop:
                    playback.visible && playback.music && !playback.expanded,
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackVolumeControl extends StatelessWidget {
  const _PlaybackVolumeControl({required this.playback});
  final LoomPlaybackController playback;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback.volume,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: playback.volume.muted
                  ? tr(context, 'Unmute', 'وصل صدا')
                  : tr(context, 'Mute', 'بی‌صدا'),
              onPressed: playback.volume.toggleMute,
              icon: Icon(
                playback.volume.muted
                    ? LoomIcons.volume_off_outlined
                    : LoomIcons.volume_up_rounded,
              ),
            ),
            Expanded(
              child: Slider(
                value: playback.volume.value,
                max: 100,
                label: '${playback.volume.value.round()}%',
                semanticFormatterCallback: (value) => '${value.round()}%',
                onChanged: (value) => unawaited(playback.volume.set(value)),
              ),
            ),
            SizedBox(
              width: 42,
              child: Text(
                '${playback.volume.value.round()}%',
                textDirection: TextDirection.ltr,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
        if (playback.volume.error != null)
          Text(
            tr(
              context,
              'Volume change failed; try again.',
              'تغییر صدا انجام نشد؛ دوباره تلاش کنید.',
            ),
          ),
      ],
    ),
  );
}

class LoomAudioTile extends StatelessWidget {
  const LoomAudioTile({
    required this.file,
    required this.title,
    this.subtitle = '',
    this.waveform = const [],
    this.sourceId,
    this.duration,
    this.foreground,
    this.music = false,
    this.compact = false,
    this.artworkBytes,
    super.key,
  });
  final File file;
  final String title, subtitle;
  final String? sourceId;
  final List<double> waveform;
  final Duration? duration;
  final Color? foreground;
  final bool music, compact;
  final Uint8List? artworkBytes;
  @override
  Widget build(BuildContext context) {
    final p = music && sourceId != null
        ? LoomPlaybackController.instance
        : LoomPlaybackController.voice;
    final color = foreground ?? context.loom.textPrimary;
    return LoomPlaybackProgressBuilder(
      controller: p,
      source: file,
      sourceId: sourceId,
      builder: (context) {
        final active = p.isSource(file, id: sourceId);
        final progress = active && p.duration.inMilliseconds > 0
            ? (p.position.inMilliseconds / p.duration.inMilliseconds).clamp(
                0.0,
                1.0,
              )
            : 0.0;
        final track = p.track(sourceId ?? '');
        final elapsed = active ? p.position : duration ?? Duration.zero;
        final play = IconButton(
          tooltip: tr(
            context,
            active && p.playing ? 'Pause' : 'Play',
            active && p.playing ? 'مکث' : 'پخش',
          ),
          style: IconButton.styleFrom(
            foregroundColor: music ? Colors.white : color,
            backgroundColor: music
                ? Colors.black.withValues(alpha: .35)
                : color.withValues(alpha: .12),
            minimumSize: const Size.square(44),
            fixedSize: const Size.square(44),
            shape: const CircleBorder(),
          ),
          onPressed: () async {
            if (active && p.error == null) {
              await p.toggle();
              return;
            }
            if (music && sourceId != null) {
              await p.registerMusic(file, sourceId!, title, subtitle);
              await p.playTrack(sourceId!);
              return;
            }
            await p.open(
              file,
              title: title,
              id: sourceId,
              subtitle: subtitle,
              waveform: waveform,
              music: music && sourceId != null,
            );
          },
          icon: active && p.loading
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              : LoomComposerMorph(
                  child: Icon(
                    active && p.playing
                        ? LoomIcons.pause_rounded
                        : LoomIcons.play_arrow_rounded,
                    key: ValueKey(active && p.playing),
                  ),
                ),
        );
        final seek = SizedBox(
          height: compact
              ? 24
              : music
              ? 20
              : 22,
          child: LayoutBuilder(
            builder: (context, bounds) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: active
                  ? (event) => p.seek(
                      Duration(
                        milliseconds:
                            (p.duration.inMilliseconds *
                                    (event.localPosition.dx / bounds.maxWidth)
                                        .clamp(0.0, 1.0))
                                .round(),
                      ),
                    )
                  : null,
              onHorizontalDragUpdate: active
                  ? (event) => p.seek(
                      Duration(
                        milliseconds:
                            (p.duration.inMilliseconds *
                                    (event.localPosition.dx / bounds.maxWidth)
                                        .clamp(0.0, 1.0))
                                .round(),
                      ),
                    )
                  : null,
              child: LoomWaveform(
                waveform: music ? const [] : waveform,
                progress: progress,
                foreground: color,
              ),
            ),
          ),
        );
        final time = Text(
          active && p.error != null
              ? tr(context, 'Retry playback', 'پخش دوباره')
              : active
              ? '${mediaTime(elapsed)} / ${mediaTime(p.duration)}'
              : duration != null
              ? mediaTime(elapsed)
              : '',
          textDirection: TextDirection.ltr,
          style: TextStyle(fontSize: 11, color: color.withValues(alpha: .85)),
        );
        return AnimatedContainer(
          duration: _motionDuration(context, 240),
          curve: Curves.easeInOutCubicEmphasized,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: music ? const EdgeInsets.all(12) : EdgeInsets.zero,
          decoration: music
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: LinearGradient(
                    begin: AlignmentDirectional.topStart,
                    end: AlignmentDirectional.bottomEnd,
                    colors: [
                      context.loom.primary.withValues(
                        alpha: active ? .16 : .08,
                      ),
                      context.loom.surfaceElevated,
                    ],
                  ),
                  border: Border.all(
                    color: context.loom.primary.withValues(alpha: .12),
                  ),
                )
              : null,
          child: Row(
            children: [
              if (music)
                SizedBox.square(
                  dimension: 52,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (artworkBytes != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            artworkBytes!,
                            width: 52,
                            height: 52,
                            cacheWidth: 128,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(LoomIcons.music_note_rounded),
                          ),
                        )
                      else
                        _Cover(
                          file: track?.artwork,
                          size: 52,
                          playing: active && p.playing,
                        ),
                      play,
                    ],
                  ),
                )
              else
                play,
              const SizedBox(width: 8),
              Expanded(
                child: compact
                    ? Row(
                        children: [
                          Expanded(child: seek),
                          const SizedBox(width: 6),
                          time,
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (music)
                            Text(
                              track?.title ?? title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          if (music && (track?.artist ?? subtitle).isNotEmpty)
                            Text(
                              track?.artist ?? subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: color.withValues(alpha: .8),
                              ),
                            ),
                          seek,
                          time,
                        ],
                      ),
              ),
              if (!music && !compact)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: color,
                    minimumSize: const Size(40, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  onPressed: active ? p.changeSpeed : null,
                  child: Text(
                    '${p.speed}×',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Shared truthful waveform: missing samples render a neutral seek track.
class LoomWaveform extends StatelessWidget {
  const LoomWaveform({
    this.waveform = const [],
    this.progress = 0,
    required this.foreground,
    super.key,
  });
  final List<double> waveform;
  final double progress;
  final Color foreground;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => CustomPaint(
      size: Size(bounds.maxWidth, bounds.maxHeight),
      painter: _WavePainter(
        waveform,
        progress,
        foreground,
        foreground.withValues(alpha: .32),
      ),
    ),
  );
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.peaks, this.progress, this.active, this.inactive);
  final List<double> peaks;
  final double progress;
  final Color active, inactive;
  @override
  void paint(Canvas canvas, Size size) {
    // No invented waveform for imported/legacy clips without captured peaks.
    if (peaks.isEmpty) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, size.height / 2 - 2, size.width, 4),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, Paint()..color = inactive);
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));
      canvas.drawRRect(rect, Paint()..color = active);
      canvas.restore();
      return;
    }
    // Render the measured envelope smoothly. Interpolation keeps short clips
    // dense without inventing random amplitudes or changing stored samples.
    final count = (size.width / 5).floor().clamp(1, 64).toInt();
    for (var i = 0; i < count; i++) {
      final position = count == 1 ? 0.0 : i * (peaks.length - 1) / (count - 1);
      final left = position.floor(), right = position.ceil();
      final fraction = position - left;
      final a = peaks[left].clamp(0.0, 1.0).toDouble();
      final b = peaks[right].clamp(0.0, 1.0).toDouble();
      final peak = a + (b - a) * fraction;
      final h = 3 + peak * (size.height - 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * size.width / count, (size.height - h) / 2, 3, h),
          const Radius.circular(2),
        ),
        Paint()..color = i / count <= progress ? active : inactive,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.peaks != peaks ||
      old.progress != progress ||
      old.active != active ||
      old.inactive != inactive;
}

class _Cover extends StatefulWidget {
  const _Cover({required this.file, required this.size, required this.playing});
  final File? file;
  final double size;
  final bool playing;
  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  void _update() {
    final animate =
        widget.playing &&
        widget.size > 100 &&
        !LoomAccessibility.fromContext(context).reduceMotion &&
        TickerMode.valuesOf(context).enabled;
    if (animate && !_motion.isAnimating) _motion.repeat(reverse: true);
    if (!animate) {
      _motion.stop();
      _motion.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(covariant _Cover old) {
    super.didUpdateWidget(old);
    _update();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  File? get file => widget.file;
  double get size => widget.size;
  bool get playing => widget.playing;
  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: Tween<double>(
      begin: 1,
      end: 1.035,
    ).animate(CurvedAnimation(parent: _motion, curve: Curves.easeInOut)),
    child: AnimatedScale(
      scale: playing ? 1 : .94,
      duration: LoomAccessibility.fromContext(context).reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: _motionDuration(context, 350),
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * .16),
          color: context.loom.surfaceElevated,
          boxShadow: playing && size > 100
              ? [
                  BoxShadow(
                    color: context.loom.primary.withValues(alpha: .2),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ]
              : [],
        ),
        child: AnimatedSwitcher(
          duration: _motionDuration(context, 240),
          child: file == null
              ? Icon(
                  LoomIcons.music_note_rounded,
                  size: size * .45,
                  key: const ValueKey('no-cover'),
                )
              : Image.file(
                  file!,
                  key: ValueKey(file!.path),
                  fit: BoxFit.cover,
                  width: size,
                  height: size,
                  cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  errorBuilder: (_, _, _) =>
                      Icon(LoomIcons.music_note_rounded, size: size * .45),
                ),
        ),
      ),
    ),
  );
}

class _PlaybackDetails extends StatelessWidget {
  const _PlaybackDetails();
  Future<void> _save(BuildContext context, LoomPlaybackController p) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'Save playlist', 'ذخیره پلی‌لیست')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
            hintText: tr(context, 'Playlist name', 'نام پلی‌لیست'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Cancel', 'لغو')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(tr(context, 'Save', 'ذخیره')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) {
      try {
        await p.savePlaylist(name);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  context,
                  'Playlist could not be saved',
                  'پلی‌لیست ذخیره نشد',
                ),
              ),
            ),
          );
        }
      }
    }
  }

  void _queue(
    BuildContext context,
    LoomPlaybackController p, {
    bool playlists = false,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: DefaultTabController(
          length: 2,
          initialIndex: playlists ? 1 : 0,
          child: ListenableBuilder(
            listenable: p,
            builder: (context, _) => Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(text: tr(context, 'Queue', 'صف پخش')),
                    Tab(text: tr(context, 'Playlists', 'پلی‌لیست‌ها')),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      ReorderableListView.builder(
                        itemCount: p.queue.length,
                        onReorderItem: p.reorderQueue,
                        itemBuilder: (context, index) {
                          final item = p.queue[index];
                          return ListTile(
                            key: ValueKey(item.id),
                            selected: item.id == p.sourceId,
                            leading: _Cover(
                              file: item.artwork,
                              size: 40,
                              playing: item.id == p.sourceId && p.playing,
                            ),
                            title: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(item.artist, maxLines: 1),
                            onTap: () => p.playTrack(item.id),
                            trailing: IconButton(
                              tooltip: tr(
                                context,
                                'Remove from queue',
                                'حذف از صف',
                              ),
                              onPressed: () => p.removeFromQueue(item.id),
                              icon: const Icon(LoomIcons.close_rounded),
                            ),
                          );
                        },
                      ),
                      p.playlists.isEmpty
                          ? Center(
                              child: Text(
                                tr(
                                  context,
                                  'Save the current queue as a playlist',
                                  'صف فعلی را به‌صورت پلی‌لیست ذخیره کنید',
                                ),
                              ),
                            )
                          : ListView(
                              children: p.playlists.entries.map((entry) {
                                final available = entry.value
                                    .where((id) => p.track(id) != null)
                                    .length;
                                return ListTile(
                                  leading: const Icon(
                                    LoomIcons.queue_music_rounded,
                                  ),
                                  title: Text(entry.key),
                                  subtitle: Text(
                                    tr(
                                      context,
                                      '$available / ${entry.value.length} loaded · open the chat to load tracks',
                                      '$available / ${entry.value.length} آماده · برای بارگذاری آهنگ‌ها چت را باز کنید',
                                    ),
                                  ),
                                  onTap: available > 0
                                      ? () => p.playPlaylist(entry.key)
                                      : null,
                                  trailing: IconButton(
                                    tooltip: tr(
                                      context,
                                      'Delete playlist',
                                      'حذف پلی‌لیست',
                                    ),
                                    onPressed: () =>
                                        p.deletePlaylist(entry.key),
                                    icon: const Icon(
                                      LoomIcons.delete_outline_rounded,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: TextButton.icon(
                    onPressed: () => _save(context, p),
                    icon: const Icon(LoomIcons.playlist_add_rounded),
                    label: Text(tr(context, 'Save playlist', 'ذخیره پلی‌لیست')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = LoomPlaybackController.instance;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return _DesktopMusicPlayer(
        playback: p,
        onQueue: () => _queue(context, p),
        onPlaylists: () => _queue(context, p, playlists: true),
        onSave: () => _save(context, p),
      );
    }
    return LoomPlaybackProgressBuilder(
      controller: p,
      builder: (context) => Scaffold(
        appBar: LoomGlassAppBar(
          title: Text(tr(context, 'Now playing', 'در حال پخش')),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, bounds) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: bounds.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Cover(
                        file: p.artwork,
                        size: (bounds.maxHeight * .34)
                            .clamp(100, 240)
                            .toDouble(),
                        playing: p.playing,
                      ),
                      const SizedBox(height: 20),
                      AnimatedSwitcher(
                        duration: _motionDuration(context, 220),
                        child: Text(
                          p.title,
                          key: ValueKey(p.title),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        p.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.loom.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 20),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                        ),
                        child: Slider(
                          value: p.position.inMilliseconds.toDouble().clamp(
                            0,
                            p.duration.inMilliseconds.toDouble().clamp(
                              1,
                              double.infinity,
                            ),
                          ),
                          max: p.duration.inMilliseconds.toDouble().clamp(
                            1,
                            double.infinity,
                          ),
                          onChanged: p.visible
                              ? (v) => p.seek(Duration(milliseconds: v.round()))
                              : null,
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            mediaTime(p.position),
                            textDirection: TextDirection.ltr,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          Text(
                            mediaTime(p.duration),
                            textDirection: TextDirection.ltr,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          if (p.music)
                            IconButton(
                              tooltip: tr(context, 'Shuffle', 'تصادفی'),
                              isSelected: p.shuffle,
                              onPressed: p.toggleShuffle,
                              icon: const Icon(LoomIcons.shuffle_rounded),
                            ),
                          IconButton(
                            tooltip: tr(context, 'Previous', 'قبلی'),
                            onPressed: p.music
                                ? p.previous
                                : () => p.seek(
                                    p.position > const Duration(seconds: 10)
                                        ? p.position -
                                              const Duration(seconds: 10)
                                        : Duration.zero,
                                  ),
                            icon: Icon(
                              p.music
                                  ? LoomIcons.skip_previous_rounded
                                  : LoomIcons.replay_10_rounded,
                            ),
                          ),
                          IconButton.filled(
                            key: const ValueKey('full-player-transport'),
                            iconSize: 36,
                            style: IconButton.styleFrom(
                              minimumSize: const Size.square(64),
                              foregroundColor: context.loom.onPrimary,
                            ),
                            tooltip: tr(
                              context,
                              p.playing ? 'Pause' : 'Play',
                              p.playing ? 'مکث' : 'پخش',
                            ),
                            onPressed: p.visible && !p.loading
                                ? p.toggle
                                : null,
                            icon: AnimatedSwitcher(
                              duration: _motionDuration(context, 180),
                              child: Icon(
                                p.playing
                                    ? LoomIcons.pause_rounded
                                    : LoomIcons.play_arrow_rounded,
                                key: ValueKey(p.playing),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: tr(context, 'Next', 'بعدی'),
                            onPressed: p.music
                                ? () => p.next()
                                : () => p.seek(
                                    p.position + const Duration(seconds: 10),
                                  ),
                            icon: Icon(
                              p.music
                                  ? LoomIcons.skip_next_rounded
                                  : LoomIcons.forward_10_rounded,
                            ),
                          ),
                          if (p.music)
                            IconButton(
                              tooltip: tr(context, 'Repeat', 'تکرار'),
                              isSelected: p.repeat != 0,
                              onPressed: p.cycleRepeat,
                              icon: Icon(
                                p.repeat == 2
                                    ? LoomIcons.repeat_one_rounded
                                    : LoomIcons.repeat_rounded,
                              ),
                            )
                          else
                            TextButton(
                              onPressed: p.changeSpeed,
                              child: Text('${p.speed}×'),
                            ),
                        ],
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: _PlaybackVolumeControl(playback: p),
                      ),
                      if (p.error != null)
                        Text(
                          tr(
                            context,
                            'Playback unavailable. Choose another file.',
                            'پخش ممکن نیست؛ فایل دیگری انتخاب کنید.',
                          ),
                        ),
                      const SizedBox(height: 20),
                      if (p.music)
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: () => _queue(context, p),
                              icon: const Icon(LoomIcons.queue_music_rounded),
                              label: Text(
                                '${tr(context, 'Queue', 'صف پخش')} · ${p.queue.length}',
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () =>
                                  _queue(context, p, playlists: true),
                              icon: const Icon(LoomIcons.playlist_play_rounded),
                              label: Text(
                                tr(context, 'Playlists', 'پلی‌لیست‌ها'),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reads embedded tags once for a local, unsent music file.
class LoomPlaybackProgressBuilder extends StatefulWidget {
  const LoomPlaybackProgressBuilder({
    required this.controller,
    required this.builder,
    this.source,
    this.sourceId,
    super.key,
  });
  final LoomPlaybackController controller;
  final WidgetBuilder builder;
  final File? source;
  final String? sourceId;
  @override
  State<LoomPlaybackProgressBuilder> createState() =>
      _LoomPlaybackProgressBuilderState();
}

class _LoomPlaybackProgressBuilderState
    extends State<LoomPlaybackProgressBuilder> {
  void _changed() {
    if (mounted) setState(() {});
  }

  void _progress() {
    final source = widget.source;
    if (source == null ||
        widget.controller.isSource(source, id: widget.sourceId)) {
      _changed();
    }
  }

  void _listen(LoomPlaybackController controller) {
    controller.addListener(_changed);
    controller.timeline.addListener(_progress);
  }

  void _unlisten(LoomPlaybackController controller) {
    controller.removeListener(_changed);
    controller.timeline.removeListener(_progress);
  }

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
  }

  @override
  void didUpdateWidget(covariant LoomPlaybackProgressBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _unlisten(oldWidget.controller);
      _listen(widget.controller);
    }
  }

  @override
  void dispose() {
    _unlisten(widget.controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
