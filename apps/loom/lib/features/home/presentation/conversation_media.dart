part of 'messenger_shell.dart';

// CARTO requires an operator-supplied public basemap key; default stays OSM.
const _loomCartoBasemapKey = String.fromEnvironment('LOOM_CARTO_BASEMAP_KEY');

Future<Duration?> _chooseLocation(
  BuildContext context,
  LatLng point, {
  required bool live,
}) => Navigator.push<Duration>(
  context,
  MaterialPageRoute(
    builder: (context) => Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr(
                        context,
                        live ? 'Live location' : 'Share location',
                        live ? 'موقعیت زنده' : 'اشتراک موقعیت',
                      ),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: tr(context, 'Close', 'بستن'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LoomIcons.close),
                  ),
                ],
              ),
            ),
            Expanded(child: _LocationMap(point: point)),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr(context, 'Your current location', 'موقعیت فعلی شما'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      live
                          ? tr(
                              context,
                              'Updates while Loom is open; stops on lock or leaving the app.',
                              'تا وقتی لوم باز است به‌روز می‌شود؛ با قفل یا خروج متوقف می‌شود.',
                            )
                          : tr(
                              context,
                              'Send a pin that your contact can open in Maps.',
                              'ارسال موقعیت قابل باز کردن در نقشه برای مخاطب',
                            ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    if (live)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(
                                context,
                                const Duration(minutes: 15),
                              ),
                              child: Text(
                                tr(context, '15 minutes', '۱۵ دقیقه'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => Navigator.pop(
                                context,
                                const Duration(hours: 1),
                              ),
                              child: Text(tr(context, '1 hour', '۱ ساعت')),
                            ),
                          ),
                        ],
                      )
                    else
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(context, Duration.zero),
                        icon: const Icon(LoomIcons.send_rounded),
                        label: Text(
                          tr(context, 'Send location', 'ارسال موقعیت'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

class _LocationMap extends StatefulWidget {
  const _LocationMap({required this.point, this.interactive = true});
  final bool interactive;
  final LatLng point;
  @override
  State<_LocationMap> createState() => _LocationMapState();
}

class _LocationMapState extends State<_LocationMap> {
  final _controller = MapController();
  bool _ready = false;
  bool _follow = true;
  bool _tilesFailed = false;
  @override
  void didUpdateWidget(covariant _LocationMap old) {
    super.didUpdateWidget(old);
    if (_ready && _follow && old.point != widget.point) {
      _controller.move(widget.point, _controller.camera.zoom);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: widget.point,
            initialZoom: 15,
            interactionOptions: InteractionOptions(
              flags: widget.interactive
                  ? InteractiveFlag.all & ~InteractiveFlag.rotate
                  : InteractiveFlag.none,
            ),
            onMapReady: () => _ready = true,
            onPositionChanged: (_, gesture) {
              if (gesture) {
                _follow = false;
              }
            },
          ),
          children: [
            ColorFiltered(
              colorFilter:
                  _loomCartoBasemapKey.isEmpty &&
                      Theme.of(context).brightness == Brightness.dark
                  ? const ColorFilter.matrix([
                      -.17008,
                      -.57216,
                      -.05776,
                      0,
                      204,
                      -.17008,
                      -.57216,
                      -.05776,
                      0,
                      204,
                      -.17008,
                      -.57216,
                      -.05776,
                      0,
                      204,
                      0,
                      0,
                      0,
                      1,
                      0,
                    ])
                  : const ColorFilter.mode(
                      Colors.transparent,
                      BlendMode.srcOver,
                    ),
              child: TileLayer(
                urlTemplate: _loomCartoBasemapKey.isEmpty
                    ? 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
                    : 'https://a.basemaps.cartocdn.com/${Theme.of(context).brightness == Brightness.dark ? 'dark_all' : 'rastertiles/voyager'}/{z}/{x}/{y}.png?key=${Uri.encodeComponent(_loomCartoBasemapKey)}',
                userAgentPackageName: 'Loom',
                errorTileCallback: (_, _, _) {
                  if (mounted && !_tilesFailed) {
                    setState(() => _tilesFailed = true);
                  }
                },
              ),
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: widget.point,
                  width: 56,
                  height: 56,
                  child: Container(
                    decoration: BoxDecoration(
                      color: context.loom.primary.withValues(alpha: .2),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(9),
                    child: Container(
                      decoration: BoxDecoration(
                        color: context.loom.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                      child: const Icon(
                        LoomIcons.person,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution(
                  _loomCartoBasemapKey.isEmpty
                      ? 'OpenStreetMap contributors'
                      : 'OpenStreetMap contributors · CARTO',
                  onTap: () => launchUrl(
                    Uri.parse('https://www.openstreetmap.org/copyright'),
                  ),
                ),
                if (_loomCartoBasemapKey.isNotEmpty)
                  TextSourceAttribution(
                    'CARTO',
                    onTap: () =>
                        launchUrl(Uri.parse('https://carto.com/attributions')),
                  ),
              ],
            ),
          ],
        ),
        if (_tilesFailed)
          Positioned(
            left: 8,
            right: 8,
            top: 8,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.loom.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    tr(
                      context,
                      'Map tiles unavailable · ${widget.point.latitude.toStringAsFixed(5)}, ${widget.point.longitude.toStringAsFixed(5)}',
                      'نقشه بارگیری نشد · ${widget.point.latitude.toStringAsFixed(5)}, ${widget.point.longitude.toStringAsFixed(5)}',
                    ),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.loom.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (widget.interactive)
          PositionedDirectional(
            top: 14,
            end: 14,
            child: Column(
              children: [
                _mapButton(
                  LoomIcons.add,
                  tr(context, 'Zoom in', 'بزرگ‌نمایی'),
                  () => _controller.move(
                    _controller.camera.center,
                    (_controller.camera.zoom + 1).clamp(3.0, 19.0),
                  ),
                ),
                const SizedBox(height: 8),
                _mapButton(
                  LoomIcons.remove,
                  tr(context, 'Zoom out', 'کوچک‌نمایی'),
                  () => _controller.move(
                    _controller.camera.center,
                    (_controller.camera.zoom - 1).clamp(3.0, 19.0),
                  ),
                ),
                const SizedBox(height: 8),
                _mapButton(
                  LoomIcons.my_location_rounded,
                  tr(context, 'Recenter', 'بازگشت به موقعیت'),
                  () {
                    _follow = true;
                    _controller.move(widget.point, 15);
                  },
                ),
              ],
            ),
          ),
      ],
    ),
  );
  Widget _mapButton(IconData icon, String tooltip, VoidCallback action) =>
      Material(
        color: context.loom.surface,
        shape: const CircleBorder(),
        elevation: 3,
        child: IconButton(
          tooltip: tooltip,
          onPressed: () {
            if (_ready) {
              action();
            }
          },
          icon: Icon(icon),
        ),
      );
}

class _RichMessageContent extends StatefulWidget {
  const _RichMessageContent({required this.message, required this.messaging});
  final LoomVisibleMessage message;
  final LoomMessagingSessionController? messaging;
  @override
  State<_RichMessageContent> createState() => _RichMessageContentState();
}

class _RichMessageContentState extends State<_RichMessageContent> {
  Uint8List? _bytes;
  bool _busy = false, _preparing = false, _failed = false;
  bool _viewerOpen = false;
  double? _progress;
  int _epoch = 0;
  Timer? _clock;
  String get _home {
    final address = widget.message.record.senderAddress;
    return address.substring(address.lastIndexOf(':') + 1);
  }

  String get _hero =>
      'media:${widget.message.record.conversationId}:${widget.message.record.clientId}';

  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_lockChanged);
    unawaited(_loadLocal());
    _updateLocationClock();
  }

  void _updateLocationClock() {
    final location = widget.message.content.location;
    final live =
        location?['session'] != null &&
        location?['stopped'] != true &&
        (location?['until'] as int? ?? 0) >
            DateTime.now().toUtc().millisecondsSinceEpoch;
    if (!live) {
      _clock?.cancel();
      _clock = null;
      return;
    }
    _clock ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final until = widget.message.content.location?['until'] as int? ?? 0;
      if (until <= DateTime.now().toUtc().millisecondsSinceEpoch) {
        _clock?.cancel();
        _clock = null;
      }
      if (TickerMode.valuesOf(context).enabled) setState(() {});
    });
  }

  void _clear() {
    _epoch++;
    _busy = false;
    _preparing = false;
    _progress = null;
    final bytes = _bytes;
    _bytes = null;
    if (bytes != null) {
      if (LoomAppLock.instance.locked) {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      } else {
        // Disposing one lazy chat row must not flush wallpaper and every
        // other media tile. Evict only this row's possible decode keys.
        final provider = MemoryImage(bytes);
        unawaited(provider.evict().then((_) {}));
        for (final width in const [360, 960]) {
          unawaited(ResizeImage(provider, width: width).evict().then((_) {}));
        }
      }
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _lockChanged() {
    if (LoomAppLock.instance.locked) {
      _clear();
    } else {
      unawaited(_loadLocal());
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _RichMessageContent old) {
    super.didUpdateWidget(old);
    _updateLocationClock();
    if (old.message.content.attachment?['url'] !=
        widget.message.content.attachment?['url']) {
      _clear();
      _failed = false;
      unawaited(_loadLocal());
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    LoomAppLock.instance.removeListener(_lockChanged);
    _clear();
    super.dispose();
  }

  bool _valid(int epoch) =>
      mounted && epoch == _epoch && !LoomAppLock.instance.locked;

  Future<void> _loadLocal() async {
    final media = widget.message.content.attachment;
    if (media == null ||
        media['kind'] == 'file' ||
        _busy ||
        LoomAppLock.instance.locked) {
      return;
    }
    final epoch = _epoch;
    _busy = true;
    _preparing = true;
    try {
      final bytes = await LoomEncryptedMedia.readCached(media, _home);
      if (!_valid(epoch)) {
        bytes?.fillRange(0, bytes.length, 0);
        return;
      }
      setState(() {
        _bytes = bytes;
        _busy = false;
        _preparing = false;
      });
      // Photos are real previews, including older received messages. Video/audio
      // transfers remain explicit; no audible playback starts from this path.
      if (bytes == null && media['kind'] == 'image') await _download();
    } catch (_) {
      if (_valid(epoch)) {
        setState(() {
          _busy = false;
          _preparing = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _download() async {
    if (_busy || LoomAppLock.instance.locked) return;
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _failed = false;
      _preparing = false;
      _progress = null;
    });
    try {
      final bytes = await LoomEncryptedMedia.download(
        widget.message.content.attachment!,
        _home,
        cancelled: () => !_valid(epoch),
        onProgress: (received, total) {
          final value = received / total;
          if (_valid(epoch) &&
              (_progress == null || value >= 1 || value - _progress! >= .05)) {
            setState(() => _progress = value);
          }
        },
        onPreparing: () {
          if (_valid(epoch)) setState(() => _preparing = true);
        },
      );
      if (!_valid(epoch)) {
        bytes.fillRange(0, bytes.length, 0);
        return;
      }
      setState(() => _bytes = bytes);
    } catch (_) {
      if (_valid(epoch)) setState(() => _failed = true);
    } finally {
      if (_valid(epoch)) {
        setState(() {
          _busy = false;
          _preparing = false;
        });
      }
    }
  }

  Future<void> _openMedia() async {
    final bytes = _bytes;
    if (_viewerOpen || bytes == null || LoomAppLock.instance.locked) return;
    _viewerOpen = true;
    final origin = LoomOrigin.of(context);
    Uint8List? copy;
    try {
      await LoomPlaybackController.pauseAll();
      if (!mounted || LoomAppLock.instance.locked) return;
      copy = Uint8List.fromList(bytes);
      final image = widget.message.content.attachment!['kind'] == 'image';
      final viewer = _MediaViewer(
        bytes: copy,
        heroTag: image ? _hero : null,
        video: !image,
      );
      if (image) {
        final route = MaterialPageRoute<void>(builder: (_) => viewer);
        await Navigator.push<void>(context, route);
        await route.completed;
      } else {
        await showLoomSurface<void>(
          context: context,
          origin: origin,
          identity: ('media-viewer', _hero),
          fullscreen: true,
          builder: (_) => viewer,
        );
      }
    } finally {
      copy?.fillRange(0, copy.length, 0);
      _viewerOpen = false;
    }
  }

  void _openLocation(LatLng point) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => _LocationViewer(
        point: point,
        message: widget.message,
        messaging: widget.messaging,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (LoomAppLock.instance.locked) return const SizedBox.shrink();
    final media = widget.message.content.attachment;
    if (media != null) {
      if (media['kind'] == 'file') {
        return LoomGroupAttachment(media: media, home: _home);
      }
      final mine =
          widget.message.record.senderAddress.toLowerCase() ==
          widget.messaging?.onboarding.receipt?.address.toLowerCase();
      final ratio = LoomMediaPreparation.displayAspectRatio(media);
      final duration = media['durationMs'] is int
          ? Duration(milliseconds: media['durationMs'] as int)
          : null;
      if (_bytes != null) {
        switch (media['kind']) {
          case 'audio':
            return _VoiceMessage(
              bytes: _bytes!,
              messageId:
                  '${widget.message.record.conversationId}:${widget.message.record.clientId}',
              mine: mine,
              duration: duration,
              title: media['music'] == true ? media['name'] as String? : null,
              music: media['music'] == true,
              contextLabel: widget.message.record.senderAddress,
              waveform:
                  (media['waveform'] as List?)
                      ?.map((v) => (v as num).toDouble())
                      .toList() ??
                  const [],
            );
          case 'image':
            return InkWell(
              onTap: _openMedia,
              child: Hero(
                tag: _hero,
                child: AspectRatio(
                  aspectRatio: media['sticker'] == true
                      ? ratio.clamp(.8, 1.25)
                      : ratio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      TickerMode(
                        enabled: !LoomAccessibility.fromContext(
                          context,
                        ).reduceMotion,
                        child: Image.memory(
                          _bytes!,
                          fit: media['sticker'] == true
                              ? BoxFit.contain
                              : BoxFit.cover,
                          cacheWidth: media['sticker'] == true ? 360 : 960,
                          errorBuilder: (_, _, _) => const Center(
                            child: Icon(LoomIcons.broken_image_outlined),
                          ),
                        ),
                      ),
                      if (media['animated'] == true)
                        PositionedDirectional(
                          top: 8,
                          start: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              child: Text(
                                'GIF',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          case 'video_note':
            return _RoundVideoMessage(
              bytes: _bytes!,
              onOpen: _openMedia,
              round: true,
              aspectRatio: ratio,
            );
          case 'video':
            return _RoundVideoMessage(
              bytes: _bytes!,
              onOpen: _openMedia,
              round: false,
              aspectRatio: ratio,
            );
        }
      }
      final foreground = context.loom.textPrimary;
      final action = IconButton(
        tooltip: tr(
          context,
          _failed ? 'Retry' : 'Download',
          _failed ? 'تلاش مجدد' : 'دریافت',
        ),
        onPressed: _busy ? null : () => unawaited(_download()),
        icon: _busy
            ? SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: foreground,
                  value: _preparing ? null : _progress,
                ),
              )
            : Icon(
                _failed
                    ? LoomIcons.refresh_rounded
                    : LoomIcons.download_rounded,
                color: foreground,
              ),
      );
      final label = _failed
          ? tr(
              context,
              'Could not prepare media · retry',
              'آماده‌سازی مدیا ناموفق بود؛ دوباره تلاش کنید',
            )
          : _preparing
          ? tr(context, 'Preparing…', 'آماده‌سازی…')
          : _busy
          ? tr(context, 'Downloading…', 'در حال دریافت…')
          : null;
      final isMusic = media['kind'] == 'audio' && media['music'] == true;
      final kindLabel = switch (media['kind']) {
        'audio' =>
          isMusic
              ? tr(context, 'Music', 'موسیقی')
              : tr(context, 'Voice message', 'پیام صوتی'),
        'video_note' => tr(context, 'Video message', 'پیام ویدیویی'),
        'video' => tr(context, 'Video', 'ویدیو'),
        _ =>
          media['sticker'] == true
              ? tr(context, 'Sticker', 'استیکر')
              : media['animated'] == true
              ? 'GIF'
              : tr(context, 'Photo', 'عکس'),
      };
      final fileName = media['name'] is String
          ? (media['name'] as String).trim()
          : '';
      final byteCount = media['bytes'] is num
          ? (media['bytes'] as num).toDouble()
          : 0.0;
      final sizeLabel = byteCount <= 0
          ? ''
          : byteCount < 1048576
          ? '${(byteCount / 1024).toStringAsFixed(0)} KiB'
          : '${(byteCount / 1048576).toStringAsFixed(1)} MiB';
      final details = [
        kindLabel,
        if (duration != null) mediaTime(duration),
        if (sizeLabel.isNotEmpty) sizeLabel,
      ].join(' · ');
      if (media['kind'] == 'audio') {
        final peaks =
            (media['waveform'] as List?)
                ?.map((v) => (v as num).toDouble())
                .toList() ??
            <double>[];
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: LoomSizing.audioRowMin),
          child: Row(
            children: [
              action,
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isMusic)
                      Text(
                        fileName.isEmpty ? kindLabel : fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.titleSmall?.copyWith(color: foreground),
                      )
                    else
                      SizedBox(
                        height: 30,
                        child: LoomWaveform(
                          waveform: peaks,
                          foreground: foreground,
                        ),
                      ),
                    Text(
                      label == null ? details : '$details · $label',
                      maxLines: 2,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: foreground),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }
      final placeholder = AspectRatio(
        aspectRatio: media['kind'] == 'video_note' ? 1 : ratio,
        child: ColoredBox(
          color: context.loom.surfaceMuted,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                action,
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    details,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.loom.textPrimary,
                    ),
                  ),
                ),
                if (fileName.isNotEmpty && media['kind'] != 'video_note')
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.loom.textSecondary,
                      ),
                    ),
                  ),
                if (label != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.loom.textPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      return media['kind'] == 'video_note'
          ? ClipOval(child: placeholder)
          : placeholder;
    }
    final location = widget.message.content.location;
    if (location == null) return const SizedBox.shrink();
    final live = location['session'] != null;
    final point = LatLng(
      (location['lat'] as num).toDouble(),
      (location['lon'] as num).toDouble(),
    );
    final own =
        widget.message.record.senderAddress.toLowerCase() ==
        widget.messaging?.onboarding.receipt?.address.toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => _openLocation(point),
          child: SizedBox(
            height: 190,
            child: IgnorePointer(
              child: _LocationMap(point: point, interactive: false),
            ),
          ),
        ),
        if (live)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 30),
            child: LoomLocationStatus(
              location: location,
              foreground: context.loom.textPrimary,
              onStop:
                  own &&
                      widget.messaging?.liveSessionId == location['session'] &&
                      widget.messaging?.liveConversationId ==
                          widget.message.record.conversationId
                  ? () => widget.messaging?.stopLiveLocation()
                  : null,
            ),
          ),
      ],
    );
  }
}

class _LocationViewer extends StatefulWidget {
  const _LocationViewer({
    required this.point,
    required this.message,
    required this.messaging,
  });
  final LatLng point;
  final LoomVisibleMessage message;
  final LoomMessagingSessionController? messaging;
  @override
  State<_LocationViewer> createState() => _LocationViewerState();
}

class _LocationViewerState extends State<_LocationViewer> {
  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_changed);
    widget.messaging?.addListener(_changed);
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    LoomAppLock.instance.removeListener(_changed);
    widget.messaging?.removeListener(_changed);
    super.dispose();
  }

  LatLng get _point {
    final session = widget.message.content.location?['session'];
    if (session != null) {
      for (final message
          in widget.messaging?.visibleMessagesFor(
                widget.message.record.conversationId,
              ) ??
              const <LoomVisibleMessage>[]) {
        final location = message.content.location;
        if (message.record.senderAddress ==
                widget.message.record.senderAddress &&
            location?['session'] == session) {
          return LatLng(
            (location!['lat'] as num).toDouble(),
            (location['lon'] as num).toDouble(),
          );
        }
      }
    }
    return widget.point;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: LoomGlassAppBar(title: Text(tr(context, 'Location', 'موقعیت'))),
    body: LoomAppLock.instance.locked
        ? const SizedBox.shrink()
        : _LocationMap(point: _point),
    bottomNavigationBar: LoomAppLock.instance.locked
        ? null
        : SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                icon: const Icon(LoomIcons.map_outlined),
                label: Text(tr(context, 'Open in maps', 'باز کردن در نقشه‌ها')),
                onPressed: () async {
                  try {
                    final point = _point;
                    await openLoomMaps(
                      context,
                      point.latitude,
                      point.longitude,
                    );
                  } catch (_) {
                    if (context.mounted) {
                      _showComingSoon(
                        context,
                        tr(
                          context,
                          'Could not open Maps.',
                          'باز کردن نقشه ممکن نشد.',
                        ),
                      );
                    }
                  }
                },
              ),
            ),
          ),
  );
}

class _LocalVideoPreview extends StatefulWidget {
  const _LocalVideoPreview({
    required this.file,
    this.round = false,
    this.active = true,
    super.key,
  });
  final File file;
  final bool round, active;
  @override
  State<_LocalVideoPreview> createState() => _LocalVideoPreviewState();
}

class _LocalVideoPreviewState extends State<_LocalVideoPreview>
    with WidgetsBindingObserver {
  VideoPlayerController? _player;
  bool _failed = false;
  Future<void> _pauseVideo() async {
    await _player?.pause();
  }

  @override
  void didUpdateWidget(covariant _LocalVideoPreview old) {
    super.didUpdateWidget(old);
    if (!widget.active) unawaited(_pauseVideo());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LoomAppLock.instance.addListener(_locked);
    unawaited(_load());
  }

  Future<void> _load() async {
    final player = VideoPlayerController.file(widget.file);
    _player = player;
    try {
      await player.initialize();
      if (!mounted || LoomAppLock.instance.locked) {
        return;
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

  void _locked() {
    if (LoomAppLock.instance.locked) {
      unawaited(_player?.pause());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_player?.pause());
    }
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null || !widget.active || LoomAppLock.instance.locked) {
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
        if (!mounted || !widget.active || LoomAppLock.instance.locked) return;
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
  void dispose() {
    LoomPlaybackController.instance.releaseVideo(_pauseVideo);
    LoomAppLock.instance.removeListener(_locked);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (_failed) {
      return const SizedBox(
        height: 140,
        child: Center(child: Icon(LoomIcons.movie_outlined, size: 56)),
      );
    }
    if (player == null || !player.value.isInitialized) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final preview = InkWell(
      onTap: _toggle,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: player,
        builder: (context, value, _) => Stack(
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
                  LoomIcons.play_circle_outline,
                  color: Colors.white,
                  size: 56,
                ),
              ),
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Text(
                '${value.duration.inSeconds}s',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Center(
      child: widget.round
          ? SizedBox.square(dimension: 220, child: ClipOval(child: preview))
          : SizedBox(
              height: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: preview,
              ),
            ),
    );
  }
}

class _MediaPreviewGuard extends StatefulWidget {
  const _MediaPreviewGuard({required this.child});
  final Widget child;
  @override
  State<_MediaPreviewGuard> createState() => _MediaPreviewGuardState();
}

class _MediaPreviewGuardState extends State<_MediaPreviewGuard> {
  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_locked);
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      if (mounted) setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.pop(context);
        }
      });
    }
  }

  @override
  void dispose() {
    LoomAppLock.instance.removeListener(_locked);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      LoomAppLock.instance.locked ? const SizedBox.expand() : widget.child;
}
