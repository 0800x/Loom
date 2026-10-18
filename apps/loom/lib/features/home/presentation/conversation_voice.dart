part of 'messenger_shell.dart';

class _VoiceMessage extends StatefulWidget {
  const _VoiceMessage({
    required this.bytes,
    required this.messageId,
    this.duration,
    this.mine = false,
    this.title,
    this.music = false,
    this.contextLabel = '',
    this.waveform = const [],
  });
  final String messageId;
  final Duration? duration;
  final bool mine;
  final String? title;
  final bool music;
  final String contextLabel;
  final List<double> waveform;
  final Uint8List bytes;
  @override
  State<_VoiceMessage> createState() => _VoiceMessageState();
}

class _VoiceMessageState extends State<_VoiceMessage> {
  File? _file;
  Directory? _folder;
  bool _failed = false, _preparing = false;
  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_locked);
    unawaited(_prepare());
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      unawaited(_remove());
    }
  }

  Future<void> _prepare() async {
    if (_preparing || !mounted || LoomAppLock.instance.locked) return;
    _preparing = true;
    try {
      final temp = await getTemporaryDirectory();
      final root = await Directory(
        '${temp.path}/loom_media_view',
      ).create(recursive: true);
      final folder = await root.createTemp('voice_');
      _folder = folder;
      if (!mounted || LoomAppLock.instance.locked) {
        await _remove();
        return;
      }
      final file = File('${folder.path}/voice.m4a');
      await file.writeAsBytes(widget.bytes, flush: true);
      if (!mounted || LoomAppLock.instance.locked) {
        await _remove();
        return;
      }
      // Show the row before metadata extraction / playlist storage finishes.
      setState(() => _file = file);
      if (widget.music) {
        await LoomPlaybackController.instance.registerMusic(
          file,
          widget.messageId,
          widget.title ?? 'Music',
          widget.contextLabel,
        );
        if (!mounted || LoomAppLock.instance.locked) {
          await _remove();
          return;
        }
      }
    } catch (_) {
      await _remove();
      if (mounted) {
        setState(() => _failed = true);
      }
    } finally {
      _preparing = false;
    }
  }

  Future<void> _remove({bool notify = true}) async {
    final folder = _folder;
    _folder = null;
    _file = null;
    if (notify && mounted) {
      setState(() {});
    }
    try {
      await folder?.delete(recursive: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    LoomAppLock.instance.removeListener(_locked);
    unawaited(_remove(notify: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LoomAppLock.instance.locked
      ? const SizedBox.shrink()
      : ConstrainedBox(
          constraints: const BoxConstraints(minHeight: LoomSizing.audioRowMin),
          child: _file != null
              ? LoomAudioTile(
                  file: _file!,
                  music: widget.music,
                  sourceId: widget.messageId,
                  duration: widget.duration,
                  foreground: widget.mine ? context.loom.textPrimary : null,
                  title:
                      widget.title ?? tr(context, 'Voice message', 'پیام صوتی'),
                  subtitle: widget.music ? widget.contextLabel : '',
                  waveform: widget.waveform,
                )
              : _failed
              ? IconButton(
                  tooltip: tr(
                    context,
                    'Retry preparing audio',
                    'تلاش دوباره برای آماده‌سازی صدا',
                  ),
                  icon: const Icon(LoomIcons.refresh_rounded),
                  onPressed: () {
                    setState(() => _failed = false);
                    unawaited(_prepare());
                  },
                )
              : Row(
                  children: [
                    const SizedBox.square(
                      dimension: LoomIconSize.standard,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: LoomSpacing.sm),
                    Expanded(
                      child: Text(
                        tr(
                          context,
                          'Preparing audio…',
                          'در حال آماده‌سازی صدا…',
                        ),
                      ),
                    ),
                  ],
                ),
        );
}

class _RoundVideoMessage extends StatefulWidget {
  const _RoundVideoMessage({
    required this.bytes,
    this.onOpen,
    this.round = true,
    this.aspectRatio = 1.3,
  });
  final Uint8List bytes;
  final VoidCallback? onOpen;
  final bool round;
  final double aspectRatio;
  @override
  State<_RoundVideoMessage> createState() => _RoundVideoMessageState();
}

class _RoundVideoMessageState extends State<_RoundVideoMessage>
    with WidgetsBindingObserver {
  VideoPlayerController? _player;
  Directory? _folder;
  bool _ready = false, _failed = false;
  ScrollPosition? _scrollPosition;
  Future<void> _pauseVideo() async {
    await _player?.pause();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition != position) {
      _scrollPosition?.removeListener(_checkVisibility);
      _scrollPosition = position;
      _scrollPosition?.addListener(_checkVisibility);
    }
    if (!TickerMode.valuesOf(context).enabled) unawaited(_pauseVideo());
  }

  void _checkVisibility() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (!rect.overlaps(Offset.zero & MediaQuery.sizeOf(context))) {
      unawaited(_pauseVideo());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LoomAppLock.instance.addListener(_locked);
    unawaited(_prepare());
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      unawaited(_cleanup());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_player?.pause());
    }
  }

  Future<void> _prepare() async {
    try {
      final temp = await getTemporaryDirectory();
      final root = await Directory(
        '${temp.path}/loom_media_view',
      ).create(recursive: true);
      final folder = await root.createTemp('round_');
      _folder = folder;
      if (!mounted || LoomAppLock.instance.locked) {
        await _cleanup();
        return;
      }
      final file = File('${folder.path}/video.mp4');
      await file.writeAsBytes(widget.bytes, flush: true);
      if (!mounted || LoomAppLock.instance.locked) {
        await _cleanup();
        return;
      }
      final player = VideoPlayerController.file(file);
      _player = player;
      await player.initialize();
      if (!mounted || LoomAppLock.instance.locked) {
        await _cleanup();
        return;
      }
      setState(() => _ready = true);
    } catch (_) {
      await _cleanup();
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  Future<void> _cleanup() async {
    LoomPlaybackController.instance.releaseVideo(_pauseVideo);
    final player = _player, folder = _folder;
    _player = null;
    _folder = null;
    _ready = false;
    try {
      await player?.dispose();
    } catch (_) {}
    try {
      await folder?.delete(recursive: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_checkVisibility);
    LoomAppLock.instance.removeListener(_locked);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_cleanup());
    super.dispose();
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null || LoomAppLock.instance.locked) {
      return;
    }
    try {
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        if (player.value.position >= player.value.duration) {
          await player.seekTo(Duration.zero);
        }
        if (!await LoomPlaybackController.instance.claimVideo(_pauseVideo)) {
          return;
        }
        if (!mounted || LoomAppLock.instance.locked) return;
        await player.play();
      }
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (LoomAppLock.instance.locked) {
      return const SizedBox.shrink();
    }
    if (_failed) {
      return Column(
        children: [
          Text(
            tr(
              context,
              'Inline video playback unavailable on this device',
              'پخش ویدیو در چت روی این دستگاه ممکن نیست',
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              setState(() => _failed = false);
              await _cleanup();
              if (mounted && !LoomAppLock.instance.locked) await _prepare();
            },
            icon: const Icon(LoomIcons.refresh_rounded),
            label: Text(tr(context, 'Retry playback', 'تلاش دوباره برای پخش')),
          ),
          TextButton.icon(
            onPressed: widget.onOpen,
            icon: const Icon(LoomIcons.open_in_new),
            label: Text(tr(context, 'Open video', 'باز کردن ویدیو')),
          ),
        ],
      );
    }
    final player = _player;
    final frame = AspectRatio(
      aspectRatio: widget.round ? 1 : widget.aspectRatio,
      child: Material(
        color: Colors.black,
        child: InkWell(
          onTap: _ready ? _toggle : null,
          child: !_ready || player == null
              ? const Center(child: CircularProgressIndicator())
              : ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: player,
                  builder: (context, value, _) {
                    final progress = value.duration.inMilliseconds == 0
                        ? 0.0
                        : (value.position.inMilliseconds /
                                  value.duration.inMilliseconds)
                              .clamp(0.0, 1.0)
                              .toDouble();
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: value.size.width,
                            height: value.size.height,
                            child: VideoPlayer(player),
                          ),
                        ),
                        if (!value.isPlaying)
                          const Center(
                            child: Icon(
                              LoomIcons.play_circle_filled_rounded,
                              color: Colors.white,
                              size: 54,
                            ),
                          ),
                        Positioned(
                          bottom: widget.round ? 28 : 12,
                          left: widget.round ? 40 : 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .45),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              mediaTime(
                                value.isPlaying
                                    ? value.position
                                    : value.duration,
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        if (!widget.round && widget.onOpen != null)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: IconButton(
                              tooltip: tr(context, 'Fullscreen', 'تمام‌صفحه'),
                              onPressed: () {
                                unawaited(_pauseVideo());
                                widget.onOpen!();
                              },
                              icon: const Icon(
                                LoomIcons.fullscreen_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        if (widget.round)
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _VideoProgressRing(
                                progress,
                                context.loom.primary,
                              ),
                            ),
                          )
                        else
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 2,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
    return widget.round
        ? ClipOval(child: frame)
        : ClipRRect(borderRadius: BorderRadius.circular(16), child: frame);
  }
}

class _VideoProgressRing extends CustomPainter {
  const _VideoProgressRing(this.progress, this.color);
  final double progress;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.white24;
    canvas.drawOval(rect, paint);
    paint.color = color;
    canvas.drawArc(
      rect,
      -1.57079632679,
      6.28318530718 * progress,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _VideoProgressRing old) =>
      old.progress != progress || old.color != color;
}
