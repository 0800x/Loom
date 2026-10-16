part of 'messenger_shell.dart';

class _MediaViewer extends StatefulWidget {
  const _MediaViewer({required this.bytes, required this.video, this.heroTag});
  final String? heroTag;
  final Uint8List bytes;
  final bool video;
  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer>
    with WidgetsBindingObserver {
  VideoPlayerController? _player;
  File? _file;
  bool _failed = false;
  int _mediaEpoch = 0;
  final _transform = TransformationController();
  double _dismissDistance = 0;
  bool _immersive = false;
  double _videoGain = 1, _restoreGain = 1;
  bool get _desktop => defaultTargetPlatform == TargetPlatform.windows;

  void _fit() => _transform.value = Matrix4.identity();
  void _zoom(double factor) {
    final scale = _transform.value.getMaxScaleOnAxis();
    final target = (scale * factor).clamp(1.0, 5.0);
    if (target == 1) {
      _fit();
      return;
    }
    final center = MediaQuery.sizeOf(context).center(Offset.zero);
    _transform.value = _transform.value.clone()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(target / scale, target / scale, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  void _escape() {
    if (_immersive) {
      setState(() => _immersive = false);
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _toggleVideo() async {
    final player = _player;
    if (player == null ||
        !player.value.isInitialized ||
        LoomAppLock.instance.locked) {
      return;
    }
    if (player.value.isPlaying) {
      await player.pause();
    } else if (await LoomPlaybackController.instance.claimVideo(
          _pauseVideo,
        ) &&
        mounted &&
        !LoomAppLock.instance.locked) {
      await player.play();
    }
  }

  void _seekVideo(int seconds) {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;
    final target = (player.value.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.value.duration.inMilliseconds);
    unawaited(player.seekTo(Duration(milliseconds: target)));
  }

  Future<void> _setVideoGain(double value) async {
    setState(() {
      _videoGain = value.clamp(0.0, 1.0);
      if (_videoGain > 0) _restoreGain = _videoGain;
    });
    try {
      await _player?.setVolume(_videoGain);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'Volume change failed; try again.',
                'تغییر صدا ناموفق بود؛ دوباره تلاش کنید.',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _pauseVideo() async {
    await _player?.pause();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LoomAppLock.instance.addListener(_lockChanged);
    if (widget.video) {
      unawaited(_prepareVideo());
    }
  }

  void _lockChanged() {
    if (LoomAppLock.instance.locked) {
      _mediaEpoch++;
      widget.bytes.fillRange(0, widget.bytes.length, 0);
      unawaited(_disposeVideo());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _player?.pause();
    }
  }

  Future<void> _prepareVideo() async {
    final epoch = _mediaEpoch;
    Directory? folder;
    try {
      final temp = await getTemporaryDirectory();
      final root = await Directory(
        '${temp.path}/loom_media_view',
      ).create(recursive: true);
      folder = await root.createTemp('view_');
      if (!mounted || epoch != _mediaEpoch || LoomAppLock.instance.locked) {
        return;
      }
      final file = File('${folder.path}/video.mp4');
      _file = file;
      await file.writeAsBytes(widget.bytes, flush: true);
      if (!mounted || epoch != _mediaEpoch || LoomAppLock.instance.locked) {
        return;
      }
      final player = VideoPlayerController.file(file);
      _player = player;
      await player.initialize();
      if (!mounted || epoch != _mediaEpoch || LoomAppLock.instance.locked) {
        return;
      }
      setState(() {});
      if (!await LoomPlaybackController.instance.claimVideo(_pauseVideo)) {
        return;
      }
      if (!mounted || epoch != _mediaEpoch || LoomAppLock.instance.locked) {
        return;
      }
      await player.play();
    } catch (_) {
      if (mounted && epoch == _mediaEpoch) {
        setState(() => _failed = true);
      }
    } finally {
      if (!mounted ||
          epoch != _mediaEpoch ||
          LoomAppLock.instance.locked ||
          _failed) {
        await _disposeVideo();
        if (folder != null) {
          try {
            await folder.delete(recursive: true);
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _disposeVideo() async {
    LoomPlaybackController.instance.releaseVideo(_pauseVideo);
    final player = _player, file = _file;
    _player = null;
    _file = null;
    try {
      await player?.dispose();
    } finally {
      if (file != null) {
        try {
          await file.parent.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    _mediaEpoch++;
    _transform.dispose();
    WidgetsBinding.instance.removeObserver(this);
    LoomAppLock.instance.removeListener(_lockChanged);
    unawaited(_disposeVideo());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: _desktop
        ? {
            const SingleActivator(LogicalKeyboardKey.escape): _escape,
            const SingleActivator(LogicalKeyboardKey.keyF): () =>
                setState(() => _immersive = !_immersive),
            if (widget.video) ...{
              const SingleActivator(LogicalKeyboardKey.space): () =>
                  unawaited(_toggleVideo()),
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _seekVideo(-5),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _seekVideo(5),
            } else ...{
              const SingleActivator(LogicalKeyboardKey.equal): () =>
                  _zoom(1.25),
              const SingleActivator(
                LogicalKeyboardKey.equal,
                shift: true,
              ): () =>
                  _zoom(1.25),
              const SingleActivator(LogicalKeyboardKey.minus): () => _zoom(.8),
              const SingleActivator(LogicalKeyboardKey.digit0): _fit,
            },
          }
        : const {},
    child: Focus(autofocus: _desktop, child: _buildView(context)),
  );

  Widget _buildView(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: _immersive
        ? null
        : LoomGlassAppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            actions: [
              if (_desktop && !widget.video) ...[
                IconButton(
                  tooltip: tr(context, 'Zoom out', 'کوچک‌نمایی'),
                  onPressed: () => _zoom(.8),
                  icon: const Icon(LoomIcons.remove),
                ),
                IconButton(
                  tooltip: tr(context, 'Fit to window', 'اندازهٔ پنجره'),
                  onPressed: _fit,
                  icon: const Icon(LoomIcons.close_fullscreen_rounded),
                ),
                IconButton(
                  tooltip: tr(context, 'Zoom in', 'بزرگ‌نمایی'),
                  onPressed: () => _zoom(1.25),
                  icon: const Icon(LoomIcons.add),
                ),
              ],
              if (_desktop)
                IconButton(
                  tooltip: tr(
                    context,
                    'Fullscreen view (F)',
                    'نمای تمام‌صفحه (F)',
                  ),
                  onPressed: () => setState(() => _immersive = !_immersive),
                  icon: const Icon(LoomIcons.fullscreen_rounded),
                ),
            ],
            title: Text(
              tr(
                context,
                widget.video ? 'Video' : 'Photo',
                widget.video ? 'ویدیو' : 'عکس',
              ),
            ),
          ),
    body: LoomAppLock.instance.locked
        ? const SizedBox.shrink()
        : _failed
        ? Center(
            child: Text(
              tr(
                context,
                'Playback is unavailable on this device.',
                'پخش روی این دستگاه در دسترس نیست.',
              ),
              style: const TextStyle(color: Colors.white),
            ),
          )
        : widget.video
        ? _player?.value.isInitialized == true
              ? Center(
                  child: AspectRatio(
                    aspectRatio: _player!.value.aspectRatio,
                    child: VideoPlayer(_player!),
                  ),
                )
              : const Center(child: CircularProgressIndicator())
        : Center(
            child: GestureDetector(
              onVerticalDragStart: _desktop
                  ? null
                  : (_) => _dismissDistance = 0,
              onVerticalDragUpdate: _desktop
                  ? null
                  : (event) {
                      if (_transform.value.getMaxScaleOnAxis() <= 1.01) {
                        _dismissDistance += event.delta.dy;
                      }
                    },
              onVerticalDragEnd: _desktop
                  ? null
                  : (event) {
                      if (_transform.value.getMaxScaleOnAxis() <= 1.01 &&
                          (_dismissDistance.abs() > 100 ||
                              (event.primaryVelocity?.abs() ?? 0) > 700)) {
                        Navigator.maybePop(context);
                      }
                    },
              child: InteractiveViewer(
                transformationController: _transform,
                trackpadScrollCausesScale: _desktop,
                maxScale: 5,
                child: widget.heroTag == null
                    ? Image.memory(widget.bytes, fit: BoxFit.contain)
                    : Hero(
                        tag: widget.heroTag!,
                        child: Image.memory(widget.bytes, fit: BoxFit.contain),
                      ),
              ),
            ),
          ),
    bottomNavigationBar:
        !_immersive &&
            widget.video &&
            _player?.value.isInitialized == true &&
            !LoomAppLock.instance.locked
        ? SafeArea(
            top: false,
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: _player!,
              builder: (context, value, _) => ColoredBox(
                color: context.loom.surface,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Slider(
                        value: value.position.inMilliseconds.toDouble().clamp(
                          0,
                          value.duration.inMilliseconds.toDouble().clamp(
                            1,
                            double.infinity,
                          ),
                        ),
                        max: value.duration.inMilliseconds.toDouble().clamp(
                          1,
                          double.infinity,
                        ),
                        onChanged: (v) => unawaited(
                          _player!.seekTo(Duration(milliseconds: v.round())),
                        ),
                      ),
                      if (_desktop)
                        Row(
                          children: [
                            IconButton(
                              tooltip: tr(
                                context,
                                _videoGain == 0 ? 'Unmute' : 'Mute',
                                _videoGain == 0 ? 'وصل صدا' : 'بی‌صدا',
                              ),
                              onPressed: () => _setVideoGain(
                                _videoGain == 0 ? _restoreGain : 0,
                              ),
                              icon: Icon(
                                _videoGain == 0
                                    ? LoomIcons.volume_off_outlined
                                    : LoomIcons.volume_up_rounded,
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: _videoGain,
                                label: '${(_videoGain * 100).round()}%',
                                semanticFormatterCallback: (value) =>
                                    '${(value * 100).round()}%',
                                onChanged: _setVideoGain,
                              ),
                            ),
                            Text('${(_videoGain * 100).round()}%'),
                          ],
                        ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Text(
                            '${mediaTime(value.position)} / ${mediaTime(value.duration)}',
                          ),
                          IconButton(
                            tooltip: tr(
                              context,
                              'Back 10 seconds',
                              '۱۰ ثانیه عقب',
                            ),
                            onPressed: () => _player!.seekTo(
                              value.position > const Duration(seconds: 10)
                                  ? value.position - const Duration(seconds: 10)
                                  : Duration.zero,
                            ),
                            icon: const Icon(LoomIcons.replay_10),
                          ),
                          IconButton.filled(
                            tooltip: tr(
                              context,
                              value.isPlaying ? 'Pause' : 'Play',
                              value.isPlaying ? 'مکث' : 'پخش',
                            ),
                            onPressed: _toggleVideo,
                            icon: Icon(
                              value.isPlaying
                                  ? LoomIcons.pause
                                  : LoomIcons.play_arrow,
                            ),
                          ),
                          TextButton(
                            onPressed: () => _player!.setPlaybackSpeed(
                              value.playbackSpeed == 1
                                  ? 1.5
                                  : value.playbackSpeed == 1.5
                                  ? 2
                                  : 1,
                            ),
                            child: Text('${value.playbackSpeed}×'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        : null,
  );
}
