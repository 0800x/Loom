import 'dart:async';
import 'dart:io';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/loom_strings.dart';
import '../../home/presentation/messenger_shell.dart';
import '../../media/application/playback_controller.dart';
import '../../media/presentation/playback_host.dart';
import '../../messaging/application/encrypted_media.dart';

class LoomGroupAttachment extends StatefulWidget {
  const LoomGroupAttachment({
    required this.media,
    required this.home,
    super.key,
  });
  final Map<String, Object?> media;
  final String home;
  @override
  State<LoomGroupAttachment> createState() => _LoomGroupAttachmentState();
}

class _LoomGroupAttachmentState extends State<LoomGroupAttachment> {
  Uint8List? _bytes;
  bool _loading = false, _failed = false, _opening = false;
  int _epoch = 0;

  /// Stable library identity for this attachment's audio, so replays reuse
  /// the cached library copy (tags, artwork, queue) instead of re-copying.
  late final String _audioId = 'group:${(
      widget.media['url'] ?? widget.media['name'] ?? 'audio'
  ).hashCode.toRadixString(36)}';
  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_locked);
    if (widget.media['kind'] == 'image') unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LoomGroupAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.home != widget.home ||
        oldWidget.media['url'] != widget.media['url'] ||
        oldWidget.media['key'] != widget.media['key']) {
      ++_epoch;
      _clear();
      _loading = false;
      _failed = false;
      if (widget.media['kind'] == 'image') unawaited(_load());
    }
  }

  void _clear() {
    final bytes = _bytes;
    _bytes = null;
    if (bytes != null) {
      unawaited(MemoryImage(bytes).evict());
      unawaited(ResizeImage(MemoryImage(bytes), width: 480).evict());
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _locked() {
    if (!LoomAppLock.instance.locked) return;
    ++_epoch;
    _clear();
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    ++_epoch;
    LoomAppLock.instance.removeListener(_locked);
    _clear();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _bytes != null || LoomAppLock.instance.locked) return;
    final epoch = _epoch;
    if (mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final bytes = await LoomEncryptedMedia.download(
        widget.media,
        widget.home,
        cancelled: () =>
            !mounted || epoch != _epoch || LoomAppLock.instance.locked,
      );
      if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) {
        bytes.fillRange(0, bytes.length, 0);
        return;
      }
      setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted && epoch == _epoch) setState(() => _failed = true);
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  Future<void> _open() async {
    if (_opening || LoomAppLock.instance.locked) return;
    _opening = true;
    try {
      await _openAttachment();
    } finally {
      _opening = false;
    }
  }

  Future<void> _openAttachment() async {
    await _load();
    final bytes = _bytes;
    if (!mounted || bytes == null || LoomAppLock.instance.locked) return;
    final epoch = _epoch;
    final kind = widget.media['kind'];
    try {
      if (kind == 'image' || kind == 'video' || kind == 'video_note') {
        final viewerBytes = Uint8List.fromList(bytes);
        try {
          await showLoomGroupMedia(
            context,
            viewerBytes,
            video: kind != 'image',
          );
        } finally {
          unawaited(MemoryImage(viewerBytes).evict());
          viewerBytes.fillRange(0, viewerBytes.length, 0);
        }
      } else if (kind == 'audio') {
        final directory = await getTemporaryDirectory();
        if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) {
          return;
        }
        final file = File(
          '${directory.path}/loom-group-audio-${DateTime.now().microsecondsSinceEpoch}',
        );
        try {
          await file.writeAsBytes(bytes, flush: true);
          if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) {
            return;
          }
          // Register into the music library (tags, artwork, queue) instead of
          // an anonymous playback session, so the player actually shows the
          // track it is playing.
          await LoomPlaybackController.instance.openMusicFile(
            file,
            title: widget.media['name'] as String? ?? 'Audio',
            id: _audioId,
          );
        } finally {
          if (await file.exists()) await file.delete();
        }
      } else {
        final rawName = widget.media['name'] as String? ?? 'attachment';
        final name = rawName.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
        if (defaultTargetPlatform == TargetPlatform.android) {
          final exported = Uint8List.fromList(bytes);
          try {
            await const MethodChannel(
              'loom/attachment_export',
            ).invokeMethod<bool>('save', {'name': name, 'bytes': exported});
          } finally {
            exported.fillRange(0, exported.length, 0);
          }
          return;
        }
        final destination = await getSaveLocation(suggestedName: name);
        if (destination == null ||
            !mounted ||
            epoch != _epoch ||
            LoomAppLock.instance.locked) {
          return;
        }
        await XFile.fromData(bytes, name: name).saveTo(destination.path);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'Unable to open attachment',
                'باز کردن فایل ممکن نیست',
              ),
            ),
          ),
        );
      }
    }
  }

  /// Toggle when this row's track is already the active music source;
  /// otherwise download (if needed) and start it.
  Future<void> _playOrToggle() async {
    final playback = LoomPlaybackController.instance;
    if (playback.sourceId == _audioId && playback.error == null) {
      await playback.toggle();
      return;
    }
    await _open();
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.media['kind'];
    final bytes = _bytes;
    if (kind == 'audio' || kind == 'voice') {
      return _AudioAttachmentCard(
        name: widget.media['name'] as String? ?? 'Audio',
        size: widget.media['bytes'] as int? ?? 0,
        audioId: _audioId,
        loading: _loading,
        failed: _failed,
        onTap: _loading ? null : () => unawaited(_playOrToggle()),
      );
    }
    return InkWell(
      onTap: _loading ? null : _open,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (kind == 'image')
              SizedBox(
                width: 240,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(LoomRadii.control),
                    child: bytes == null
                        ? ColoredBox(
                            color: context.loom.surfaceMuted,
                            child: Center(
                              child: Icon(
                                _failed
                                    ? LoomIcons.broken_image_outlined
                                    : LoomIcons.photo_library_outlined,
                              ),
                            ),
                          )
                        : Image.memory(
                            bytes,
                            cacheWidth: 480,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Center(
                              child: Icon(LoomIcons.broken_image_outlined),
                            ),
                          ),
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_loading)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    kind == 'image'
                        ? LoomIcons.photo_library_outlined
                        : kind == 'file'
                        ? LoomIcons.download_rounded
                        : LoomIcons.play_circle_outline,
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _failed
                        ? tr(
                            context,
                            'Retry download',
                            'تلاش دوباره برای دانلود',
                          )
                        : widget.media['name'] as String? ??
                              (kind == 'image'
                                  ? tr(context, 'Photo', 'تصویر')
                                  : kind == 'file'
                                  ? tr(context, 'File', 'فایل')
                                  : tr(context, 'Video', 'ویدیو')),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Text(
              '${((widget.media['bytes'] as int) / 1048576).toStringAsFixed(1)} MB',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Music-style card for audio attachments: tinted artwork tile, name, size
/// and a live progress track bound to the shared music controller.
class _AudioAttachmentCard extends StatelessWidget {
  const _AudioAttachmentCard({
    required this.name,
    required this.size,
    required this.audioId,
    required this.loading,
    required this.failed,
    required this.onTap,
  });

  final String name;
  final int size;
  final String audioId;
  final bool loading;
  final bool failed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return LoomPlaybackProgressBuilder(
      controller: LoomPlaybackController.instance,
      sourceId: audioId,
      builder: (context) {
        final playback = LoomPlaybackController.instance;
        final active = playback.sourceId == audioId;
        final progress = active && playback.duration.inMilliseconds > 0
            ? (playback.position.inMilliseconds /
                    playback.duration.inMilliseconds)
                .clamp(0.0, 1.0)
            : 0.0;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: [
                p.primary.withValues(alpha: active ? .16 : .09),
                p.surfaceElevated,
              ],
            ),
            border: Border.all(color: p.primary.withValues(alpha: .13)),
          ),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      p.primary.withValues(alpha: .30),
                      p.secondary.withValues(alpha: .22),
                    ],
                  ),
                ),
                child: Icon(
                  LoomIcons.music_note_rounded,
                  size: 24,
                  color: p.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      failed
                          ? tr(context, 'Tap to retry download', 'برای دانلود دوباره بزنید')
                          : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      size > 0
                          ? '${(size / 1048576).toStringAsFixed(1)} MB'
                          : tr(context, 'Audio', 'صوت'),
                      style: TextStyle(
                        fontSize: 11,
                        color: p.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 7),
                    SizedBox(
                      height: 4,
                      child: LoomWaveform(
                        waveform: const [],
                        progress: progress,
                        foreground: p.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _AudioCardPlayButton(
                active: active,
                playing: active && playback.playing,
                loading: loading || (active && playback.loading),
                failed: failed,
                onTap: onTap,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AudioCardPlayButton extends StatelessWidget {
  const _AudioCardPlayButton({
    required this.active,
    required this.playing,
    required this.loading,
    required this.failed,
    required this.onTap,
  });

  final bool active, playing, loading, failed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Tooltip(
      message: playing
          ? tr(context, 'Pause', 'مکث')
          : tr(context, 'Play', 'پخش'),
      child: Material(
        color: failed ? p.critical.withValues(alpha: .14) : p.primary,
        shape: const CircleBorder(
          side: BorderSide(color: Colors.transparent),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Center(
              child: loading
                  ? SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.onPrimary,
                      ),
                    )
                  : Icon(
                      failed
                          ? LoomIcons.refresh_rounded
                          : playing
                          ? LoomIcons.pause_rounded
                          : LoomIcons.play_arrow_rounded,
                      size: 22,
                      color: failed ? p.critical : p.onPrimary,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
