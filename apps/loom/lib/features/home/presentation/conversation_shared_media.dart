part of 'messenger_shell.dart';

class LoomConversationMediaScreen extends StatelessWidget {
  const LoomConversationMediaScreen({
    required this.conversationId,
    super.key,
  });
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final messaging = LoomMessagingSessionScope.of(context);
    final messages = messaging
        .visibleMessagesFor(conversationId)
        .where((m) => m.content.attachment != null)
        .toList()
        .reversed
        .toList();
    bool visual(LoomVisibleMessage m) => [
      'image',
      'video',
      'video_note',
    ].contains(m.content.attachment?['kind']);
    final media = messages.where(visual).toList();
    final files = messages.where((m) => !visual(m)).toList();
    Widget empty() => Center(
      child: Text(
        tr(
          context,
          'No shared media yet',
          'هنوز رسانه‌ای به اشتراک گذاشته نشده',
        ),
      ),
    );
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: context.loom.background,
        appBar: LoomGlassAppBar(
          title: Text(tr(context, 'Shared media', 'رسانه‌های مشترک')),
          bottom: TabBar(
            tabs: [
              Tab(text: tr(context, 'Photos & videos', 'عکس و ویدیو')),
              Tab(text: tr(context, 'Files & music', 'فایل و موسیقی')),
            ],
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: TabBarView(
              children: [
                media.isEmpty
                    ? empty()
                    : LayoutBuilder(
                        builder: (context, constraints) => GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: math.max(
                                  2,
                                  (constraints.maxWidth / 160).floor(),
                                ),
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemCount: media.length,
                          itemBuilder: (context, index) =>
                              _SharedMediaThumbnail(message: media[index]),
                        ),
                      ),
                files.isEmpty
                    ? empty()
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: files.length,
                        separatorBuilder: (_, _) => const Divider(height: 24),
                        itemBuilder: (context, index) => _RichMessageContent(
                          message: files[index],
                          messaging: messaging,
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Only one decrypted source is processed at once. A visible grid tile
/// retains only its downsampled thumbnail, never a full-resolution blob.
Future<void> _thumbnailQueue = Future<void>.value();

class _SharedMediaThumbnail extends StatefulWidget {
  const _SharedMediaThumbnail({required this.message});
  final LoomVisibleMessage message;
  @override
  State<_SharedMediaThumbnail> createState() => _SharedMediaThumbnailState();
}

class _SharedMediaThumbnailState extends State<_SharedMediaThumbnail> {
  Uint8List? _thumbnail;
  bool _failed = false, _opening = false;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_locked);
    _queue();
  }

  String get _home {
    final address = widget.message.record.senderAddress;
    return address.substring(address.lastIndexOf(':') + 1);
  }

  void _queue() {
    final epoch = _epoch;
    _thumbnailQueue = _thumbnailQueue.catchError((Object _) {}).then((_) async {
      if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) return;
      Uint8List? clear, thumbnail;
      Directory? folder;
      try {
        final media = widget.message.content.attachment!;
        clear = await LoomEncryptedMedia.download(media, _home);
        if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) {
          return;
        }
        if (media['kind'] == 'image') {
          final codec = await ui.instantiateImageCodec(
            clear,
            targetWidth: 256,
            targetHeight: 256,
            allowUpscaling: false,
          );
          try {
            final frame = await codec.getNextFrame();
            try {
              final data = await frame.image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              thumbnail = data?.buffer.asUint8List(
                data.offsetInBytes,
                data.lengthInBytes,
              );
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }
        } else if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
          folder = await (await getTemporaryDirectory()).createTemp(
            'loom_thumb_',
          );
          final file = await File('${folder.path}/video.mp4')
              .writeAsBytes(clear, flush: true);
          thumbnail = await VideoCompress.getByteThumbnail(
            file.path,
            quality: 65,
          );
        }
        if (!mounted || epoch != _epoch || LoomAppLock.instance.locked) {
          thumbnail?.fillRange(0, thumbnail.length, 0);
          return;
        }
        setState(() {
          _thumbnail = thumbnail;
          _failed = thumbnail == null;
        });
      } catch (_) {
        if (mounted && epoch == _epoch) setState(() => _failed = true);
      } finally {
        clear?.fillRange(0, clear.length, 0);
        try {
          await folder?.delete(recursive: true);
        } catch (_) {}
      }
    });
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      ++_epoch;
      _thumbnail?.fillRange(0, _thumbnail!.length, 0);
      _thumbnail = null;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      if (mounted) setState(() {});
    }
  }

  Future<void> _open() async {
    if (_opening || LoomAppLock.instance.locked) return;
    setState(() => _opening = true);
    Uint8List? clear;
    try {
      final media = widget.message.content.attachment!;
      clear = await LoomEncryptedMedia.download(media, _home);
      if (!mounted || LoomAppLock.instance.locked) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              _MediaViewer(bytes: clear!, video: media['kind'] != 'image'),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      clear?.fillRange(0, clear.length, 0);
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    ++_epoch;
    LoomAppLock.instance.removeListener(_locked);
    _thumbnail?.fillRange(0, _thumbnail!.length, 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (LoomAppLock.instance.locked) return const SizedBox.shrink();
    return InkWell(
      onTap: _open,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_thumbnail != null)
            Image.memory(_thumbnail!, fit: BoxFit.cover, cacheWidth: 256)
          else
            ColoredBox(
              color: context.loom.surfaceMuted,
              child: Center(
                child: _failed
                    ? IconButton(
                        tooltip: tr(
                          context,
                          'Retry thumbnail',
                          'تلاش مجدد برای پیش‌نمایش',
                        ),
                        onPressed: () {
                          setState(() => _failed = false);
                          _queue();
                        },
                        icon: const Icon(LoomIcons.refresh),
                      )
                    : const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),
            ),
          if (widget.message.content.attachment?['kind'] != 'image')
            const Center(
              child: Icon(
                LoomIcons.play_circle_outline,
                color: Colors.white,
                size: 32,
                shadows: [Shadow(color: Colors.black, blurRadius: 6)],
              ),
            ),
          if (_opening) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
