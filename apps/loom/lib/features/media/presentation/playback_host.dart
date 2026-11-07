import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;

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

String mediaTime(Duration v) {
  final h = v.inHours;
  final m = v.inMinutes.remainder(60);
  final s = v.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '${v.inMinutes}:$s';
}

/// Seek bar that owns its drag state: while the user drags, position ticks
/// from the player cannot snap the thumb back, and the decoder only receives
/// one seek per gesture (on release) instead of one per pixel.
class _SeekSlider extends StatefulWidget {
  const _SeekSlider({
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final bool enabled;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  double? _dragValue;

  @override
  void didUpdateWidget(covariant _SeekSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new track invalidates any in-flight drag value.
    if (oldWidget.duration != widget.duration) {
      _dragValue = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final double max = widget.duration.inMilliseconds.toDouble().clamp(
      1.0,
      double.infinity,
    );
    final double value =
        (_dragValue ?? widget.position.inMilliseconds.toDouble()).clamp(
          0.0,
          max,
        );
    return Slider(
      value: value,
      max: max,
      onChanged: widget.enabled ? (v) => setState(() => _dragValue = v) : null,
      onChangeEnd: widget.enabled
          ? (v) {
              widget.onSeek(Duration(milliseconds: v.round()));
              setState(() => _dragValue = null);
            }
          : null,
    );
  }
}

/// A soft circular header action for the fullscreen player's edge buttons.
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: onSurface.withValues(alpha: .09),
        shape: const CircleBorder(
          side: BorderSide(color: Colors.transparent),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(icon, size: 22, color: onSurface.withValues(alpha: .9)),
          ),
        ),
      ),
    );
  }
}

/// Pill-shaped seek bar for the fullscreen player. Owns its drag state like
/// [_SeekSlider]: the thumb cannot be snapped back by position ticks and the
/// decoder receives a single seek per gesture, on release.
class _PillSeekSlider extends StatefulWidget {
  const _PillSeekSlider({
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onSeek,
  });
  final Duration position;
  final Duration duration;
  final bool enabled;
  final ValueChanged<Duration> onSeek;
  @override
  State<_PillSeekSlider> createState() => _PillSeekSliderState();
}

class _PillSeekSliderState extends State<_PillSeekSlider> {
  double? _dragValue;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant _PillSeekSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) _dragValue = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final max = widget.duration.inMilliseconds.toDouble().clamp(
      1.0,
      double.infinity,
    );
    final value =
        (_dragValue ?? widget.position.inMilliseconds.toDouble()).clamp(
          0.0,
          max,
        );
    final fraction = (value / max).clamp(0.0, 1.0);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: 'Seek',
      value: mediaTime(Duration(milliseconds: value.round())),
      enabled: widget.enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: widget.enabled
            ? (details) => setState(() {
                _dragging = true;
                _dragValue = value;
              })
            : null,
        onHorizontalDragUpdate: widget.enabled
            ? (details) => setState(
                () => _dragValue = ((_dragValue ?? 0) +
                        details.delta.dx /
                            (context.size?.width ?? 1) *
                            max)
                    .clamp(0.0, max),
              )
            : null,
        onHorizontalDragEnd: widget.enabled
            ? (_) {
                widget.onSeek(
                  Duration(milliseconds: (_dragValue ?? 0).round()),
                );
                setState(() {
                  _dragging = false;
                  _dragValue = null;
                });
              }
            : null,
        onTapUp: widget.enabled
            ? (details) {
                final width = context.size?.width ?? 1;
                widget.onSeek(
                  Duration(
                    milliseconds:
                        (max * details.localPosition.dx / width).round(),
                  ),
                );
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: SizedBox(
            height: 14,
            child: LayoutBuilder(
              builder: (context, bounds) {
                final thumb = _dragging ? 18.0 : 13.0;
                final dx = (bounds.maxWidth - thumb) * fraction;
                return Stack(
                  alignment: AlignmentDirectional.centerStart,
                  clipBehavior: Clip.none,
                  children: [
                    // Inactive track.
                    Container(
                      height: 5,
                      decoration: BoxDecoration(
                        color: onSurface.withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    // Buffered/active fill.
                    FractionallySizedBox(
                      widthFactor: fraction == 0 ? 0.001 : fraction,
                      child: Container(
                        height: 5,
                        decoration: BoxDecoration(
                          color: p.primary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    // Thumb.
                    PositionedDirectional(
                      start: dx,
                      child: AnimatedContainer(
                        duration: _dragging
                            ? Duration.zero
                            : const Duration(milliseconds: 120),
                        width: thumb,
                        height: thumb,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: p.primary,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.surface,
                            width: 2.5,
                          ),
                          boxShadow: _dragging
                              ? [
                                  BoxShadow(
                                    color: p.primary.withValues(alpha: .4),
                                    blurRadius: 12,
                                  ),
                                ]
                              : [],
                        ),
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
}

/// Opens the fullscreen Now Playing surface. The compact docked bar morphs
/// from [origin] when one is provided, and the bars hide themselves while the
/// expanded surface is open (the controller exposes `expanded` for that).
Future<void> showLoomPlaybackDetails(BuildContext context, {Rect? origin}) async {
  final playback = LoomPlaybackController.instance;
  if (playback.expanded) return;
  playback.setExpanded(true);
  try {
    await showLoomSurface<void>(
      context: context,
      origin: origin,
      identity: 'music-player',
      fullscreen: true,
      builder: (_) => const _PlaybackDetails(),
    );
  } finally {
    playback.setExpanded(false);
  }
}

class LoomPlaybackHost extends StatelessWidget {
  const LoomPlaybackHost({
    required this.child,
    required this.navigatorKey,
    super.key,
  });
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  @override
  Widget build(BuildContext context) {
    // The compact player bar docks inside the messenger shell (above the
    // bottom navigation and the composer); the fullscreen surface opens over
    // the navigator. The host only provides the global overlay scaffolding.
    return Overlay.wrap(child: child);
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
        final playSize = music ? 36.0 : 44.0;
        final play = IconButton(
          tooltip: tr(
            context,
            active && p.playing ? 'Pause' : 'Play',
            active && p.playing ? 'مکث' : 'پخش',
          ),
          iconSize: music ? 20 : 24,
          style: IconButton.styleFrom(
            foregroundColor: music ? Colors.white : color,
            backgroundColor: music
                ? Colors.black.withValues(alpha: .38)
                : color.withValues(alpha: .12),
            minimumSize: Size.square(playSize),
            fixedSize: Size.square(playSize),
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
        // Playback tint animates inside the chat list: own repaint layer.
        return RepaintBoundary(
          child: AnimatedContainer(
            duration: _motionDuration(context, 240),
            curve: Curves.easeInOutCubicEmphasized,
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: music ? const EdgeInsets.all(10) : EdgeInsets.zero,
            decoration: music
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
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
                    dimension: 56,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (artworkBytes != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.memory(
                              artworkBytes!,
                              width: 56,
                              height: 56,
                              cacheWidth: 144,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const Icon(LoomIcons.music_note_rounded),
                            ),
                          )
                        else
                          _Cover(
                            file: track?.artwork,
                            size: 56,
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
                                  fontSize: 13.5,
                                ),
                              ),
                            if (music && (track?.artist ?? subtitle).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Text(
                                  track?.artist ?? subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: color.withValues(alpha: .75),
                                  ),
                                ),
                              ),
                            if (music) const SizedBox(height: 7),
                            seek,
                            const SizedBox(height: 3),
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

/// Tiny live equalizer shown on the mini-player cover while music plays —
/// the clearest at-a-glance "sound is coming out" signal, including from
/// inside a busy chat list.
class _EqualizerBadge extends StatefulWidget {
  const _EqualizerBadge({required this.reduceMotion});
  final bool reduceMotion;
  @override
  State<_EqualizerBadge> createState() => _EqualizerBadgeState();
}

class _EqualizerBadgeState extends State<_EqualizerBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.reduceMotion) _motion.repeat();
  }

  @override
  void didUpdateWidget(covariant _EqualizerBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion) {
      _motion.stop();
    } else if (!_motion.isAnimating) {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      color: context.loom.primary,
      shape: BoxShape.circle,
      border: Border.all(color: context.loom.surfaceElevated, width: 1.5),
    ),
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: _motion,
        builder: (context, _) =>
            CustomPaint(painter: _EqualizerPainter(progress: _motion.value)),
      ),
    ),
  );
}

class _EqualizerPainter extends CustomPainter {
  _EqualizerPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    const bars = 3;
    final midY = size.height / 2;
    final gap = size.width / (bars + 1);
    for (var i = 0; i < bars; i++) {
      final phase = progress * 2 * math.pi + i * .9;
      final wave = .5 + .5 * math.sin(phase);
      final half = 1.4 + 3.4 * wave;
      canvas.drawLine(
        Offset(gap * (i + 1), midY - half),
        Offset(gap * (i + 1), midY + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EqualizerPainter oldDelegate) =>
      oldDelegate.progress != progress;
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
      // Playing glow animates in-list; boundary sits inside the scaling chrome.
      child: RepaintBoundary(
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
        backgroundColor: Colors.transparent,
        // The surface route draws its own grabber dead-center at the top, so
        // the header keeps only edge actions: minimize (left) and queue
        // (right). No centered title competes with the pull-down handle.
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Ambient backdrop: the artwork blurred behind the controls, like
            // a Now-playing surface. Falls back to a soft tinted gradient
            // when the track has no embedded cover.
            if (p.artwork != null)
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                child: Transform.scale(
                  scale: 1.35,
                  child: Image.file(
                    p.artwork!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: 384,
                  ),
                ),
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      context.loom.primary.withValues(alpha: .22),
                      context.loom.surface,
                    ],
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    context.loom.surface.withValues(alpha: .25),
                    context.loom.surface.withValues(alpha: .82),
                  ],
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, bounds) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: bounds.maxHeight),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        24,
                        56,
                        24,
                        16,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              _HeaderAction(
                                tooltip: tr(context, 'Close', 'بستن'),
                                icon: LoomIcons.keyboard_arrow_down_rounded,
                                onTap: () => Navigator.of(context).maybePop(),
                              ),
                              const Spacer(),
                              if (p.music)
                                _HeaderAction(
                                  tooltip: tr(context, 'Queue', 'صف پخش'),
                                  icon: LoomIcons.queue_music_rounded,
                                  onTap: () => _queue(context, p),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _Cover(
                            file: p.artwork,
                            size: (bounds.maxHeight * .34)
                                .clamp(140, 300)
                                .toDouble(),
                            playing: p.playing,
                          ),
                          const SizedBox(height: 26),
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
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                                letterSpacing: -.2,
                              ),
                            ),
                          ),
                          if (p.subtitle.isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Text(
                              p.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.loom.textSecondary,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          if (p.error != null) ...[
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  LoomIcons.error_outline_rounded,
                                  size: 16,
                                  color: context.loom.critical,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    tr(
                                      context,
                                      'Playback unavailable. Choose another file.',
                                      'پخش ممکن نیست؛ فایل دیگری انتخاب کنید.',
                                    ),
                                    style: TextStyle(
                                      color: context.loom.critical,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 22),
                          _PillSeekSlider(
                            position: p.position,
                            duration: p.duration,
                            enabled: p.visible,
                            onSeek: p.seek,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                mediaTime(p.position),
                                textDirection: TextDirection.ltr,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      fontFeatures: [
                                        const FontFeature.tabularFigures(),
                                      ],
                                    ),
                              ),
                              Text(
                                mediaTime(p.duration),
                                textDirection: TextDirection.ltr,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      fontFeatures: [
                                        const FontFeature.tabularFigures(),
                                      ],
                                    ),
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
                                  iconSize: 22,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: p.toggleShuffle,
                                  icon: const Icon(LoomIcons.shuffle_rounded),
                                ),
                              IconButton(
                                tooltip: tr(context, 'Previous', 'قبلی'),
                                iconSize: 28,
                                visualDensity: VisualDensity.compact,
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
                                iconSize: 34,
                                style: IconButton.styleFrom(
                                  minimumSize: const Size.square(68),
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
                                iconSize: 28,
                                visualDensity: VisualDensity.compact,
                                onPressed: p.music
                                    ? () => p.next()
                                    : () => p.seek(
                                        p.position +
                                            const Duration(seconds: 10),
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
                                  iconSize: 22,
                                  visualDensity: VisualDensity.compact,
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
                          const SizedBox(height: 8),
                          if (p.music)
                            // Wrap: the two chips exceed 320px side by side.
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              children: [
                                TextButton.icon(
                                  onPressed: () => _queue(context, p),
                                  icon: const Icon(
                                    LoomIcons.queue_music_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    '${tr(context, 'Queue', 'صف پخش')} · ${p.queue.length}',
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () =>
                                      _queue(context, p, playlists: true),
                                  icon: const Icon(
                                    LoomIcons.playlist_play_rounded,
                                    size: 18,
                                  ),
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
          ],
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
