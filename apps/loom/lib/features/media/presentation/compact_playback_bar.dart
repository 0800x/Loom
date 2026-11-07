import 'dart:async';

import 'package:flutter/material.dart';

import 'package:loom_design/loom_design.dart';

import '../../../app/loom_strings.dart';
import '../application/playback_controller.dart';
import 'playback_host.dart' show showLoomPlaybackDetails;

/// A slim, Telegram-style docked bar for the music player.
///
/// Deliberately flat: a solid elevated surface with a hairline border, one
/// line of track metadata, 38px transport buttons and a 2px progress hairline
/// along the bottom edge. It mounts inside the messenger shell (above the
/// bottom navigation and above the composer) instead of pushing the whole app
/// down from the top of the screen.
class LoomCompactPlaybackBar extends StatelessWidget {
  const LoomCompactPlaybackBar({super.key, this.margin = EdgeInsets.zero});

  /// Outer spacing applied only while the bar is visible, so the collapsed
  /// state occupies zero layout space.
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final playback = LoomPlaybackController.instance;
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    return AnimatedBuilder(
      animation: playback,
      builder: (context, _) {
        final visible =
            playback.visible && playback.music && !playback.expanded;
        return AnimatedSwitcher(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => SizeTransition(
            sizeFactor: animation,
            alignment: Alignment.bottomCenter,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: !visible
              ? const SizedBox.shrink(key: ValueKey('compact-player-hidden'))
              : Padding(
                  key: const ValueKey('compact-player-bar'),
                  padding: margin,
                  child: _CompactPlaybackBarBody(playback: playback),
                ),
        );
      },
    );
  }
}

class _CompactPlaybackBarBody extends StatelessWidget {
  const _CompactPlaybackBarBody({required this.playback});

  final LoomPlaybackController playback;

  Future<void> _expand(BuildContext context) async {
    await showLoomPlaybackDetails(context, origin: LoomOrigin.of(context));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    return Material(
      color: p.surfaceElevated,
      elevation: 2,
      shadowColor: p.shadow,
      borderRadius: BorderRadius.circular(14),
      // The progress hairline spans the full width along the bottom edge;
      // without clipping it would poke past the rounded bottom corners.
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grows with text scaling instead of clipping the titles.
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => unawaited(_expand(context)),
                  behavior: HitTestBehavior.opaque,
                  child: _Artwork(playback: playback),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () => unawaited(_expand(context)),
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          playback.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        if (playback.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 1),
                          Text(
                            playback.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: p.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: tr(
                    context,
                    playback.playing ? 'Pause' : 'Play',
                    playback.playing ? 'مکث' : 'پخش',
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: playback.loading ? null : playback.toggle,
                  icon: playback.loading
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : AnimatedSwitcher(
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 160),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(scale: animation, child: child),
                          child: Icon(
                            playback.playing
                                ? LoomIcons.pause_rounded
                                : LoomIcons.play_arrow_rounded,
                            key: ValueKey(playback.playing),
                            size: 22,
                          ),
                        ),
                ),
                IconButton(
                  tooltip: tr(context, 'Next track', 'آهنگ بعدی'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => playback.next(),
                  icon: const Icon(LoomIcons.skip_next_rounded, size: 20),
                ),
                IconButton(
                  tooltip: tr(context, 'Close player', 'بستن پخش‌کننده'),
                  visualDensity: VisualDensity.compact,
                  onPressed: playback.close,
                  icon: const Icon(LoomIcons.close_rounded, size: 20),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          // Progress hairline. Deliberately not animated: position ticks
          // arrive continuously and implicit animations never settle.
          ValueListenableBuilder<Duration>(
            valueListenable: playback.timeline,
            builder: (context, position, _) {
              final total = playback.duration.inMilliseconds;
              final fraction = total <= 0
                  ? 0.0
                  : (position.inMilliseconds / total).clamp(0.0, 1.0);
              return LinearProgressIndicator(
                value: fraction,
                minHeight: 2,
                color: p.primary.withAlphaFraction(.8),
                backgroundColor: p.primary.withAlphaFraction(.10),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.playback});

  final LoomPlaybackController playback;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final file = playback.artwork;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 32,
          height: 32,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: p.surfaceMuted,
          ),
          child: file == null
              ? Icon(
                  LoomIcons.music_note_rounded,
                  size: 16,
                  color: p.textSecondary,
                )
              : Image.file(
                  file,
                  fit: BoxFit.cover,
                  cacheWidth: 96,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Icon(
                    LoomIcons.music_note_rounded,
                    size: 16,
                    color: p.textSecondary,
                  ),
                ),
        ),
        if (playback.playing)
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: p.primary,
                border: Border.all(color: p.surfaceElevated, width: 1.4),
              ),
              child: const Icon(
                LoomIcons.graphic_eq_rounded,
                size: 8,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}
