part of 'messenger_shell.dart';

class _GalleryItem {
  const _GalleryItem({
    required this.id,
    required this.kind,
    this.asset,
    this.file,
  });
  final String id, kind;
  final AssetEntity? asset;
  final File? file;
  Future<File?> resolve() async => file ?? await asset?.file;
}

class _GalleryDraft {
  _GalleryDraft(String text) : caption = TextEditingController(text: text) {
    LoomAppLock.instance.addListener(_locked);
  }
  void _locked() {
    if (LoomAppLock.instance.locked) batch.stop();
  }
  final batch = MediaBatchController<_GalleryItem>();
  final TextEditingController caption;
  LoomVisibleMessage? reply;
  bool replyCaptured = false;
  Future<void>? upload;
  bool disposed = false;
  void dispose() {
    if (disposed) return;
    disposed = true;
    LoomAppLock.instance.removeListener(_locked);
    batch.dispose();
    caption.dispose();
  }
}

class _AttachmentGallery extends StatefulWidget {
  const _AttachmentGallery({
    required this.draft,
    required this.authorized,
    required this.send,
    required this.canShareAddress,
  });
  final _GalleryDraft draft;
  final bool Function() authorized;
  final Future<bool> Function(_GalleryItem, String) send;
  final bool canShareAddress;
  @override
  State<_AttachmentGallery> createState() => _AttachmentGalleryState();
}

class _AttachmentGalleryState extends State<_AttachmentGallery>
    with WidgetsBindingObserver {
  bool _handedOff = false;
  final _assets = <AssetEntity>[];
  final _galleryScroll = ScrollController();
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _album;
  PermissionState? _permission;
  bool _loading = true, _pageLoading = false, _more = true;
  bool _previewing = false;
  int _page = 0, _generation = 0;
  String? _error;
  Timer? _libraryRefresh;
  bool get _mobile => LoomMediaCapabilities.photoLibrary;
  MediaBatchController<_GalleryItem> get batch => widget.draft.batch;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_mobile) {
      PhotoManager.addChangeCallback(_libraryChanged);
      unawaited(PhotoManager.startChangeNotify());
    }
    batch.addListener(_changed);
    LoomAppLock.instance.addListener(_locked);
    unawaited(_loadLibrary());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      batch.stop();
      if (mounted) Navigator.pop(context);
    }
  }

  void _libraryChanged(MethodCall _) => _scheduleLibraryRefresh();

  void _scheduleLibraryRefresh() {
    _libraryRefresh?.cancel();
    _libraryRefresh = Timer(const Duration(milliseconds: 250), () {
      if (mounted && !batch.sending) unawaited(_loadLibrary());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _mobile) {
      _scheduleLibraryRefresh();
    }
  }

  Future<void> _loadLibrary() async {
    final generation = ++_generation;
    final previousAlbumId = _album?.id;
    _pageLoading = false;
    if (!_mobile) {
      setState(() => _loading = false);
      return;
    }
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!mounted || generation != _generation) return;
      _permission = permission;
      if (!permission.hasAccess) {
        setState(() => _loading = false);
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        filterOption: FilterOptionGroup(
          orders: const [
            OrderOption(type: OrderOptionType.updateDate, asc: false),
            OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _albums = albums;
        _album =
            albums.where((album) => album.id == previousAlbumId).firstOrNull ??
            albums.where((album) => album.isAll).firstOrNull ??
            albums.firstOrNull;
        _assets.clear();
        _page = 0;
        _more = true;
        _loading = false;
        _error = null;
      });
      await _nextPage();
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'gallery_unavailable';
        });
      }
    }
  }

  Future<void> _nextPage() async {
    final album = _album;
    final generation = _generation;
    if (album == null || _pageLoading || !_more) return;
    _pageLoading = true;
    try {
      final assets = await album.getAssetListPaged(page: _page, size: 60);
      if (!mounted || generation != _generation) return;
      setState(() {
        final known = _assets.map((asset) => asset.id).toSet();
        _assets.addAll(assets.where((asset) => known.add(asset.id)));
        _page++;
        _more = assets.length == 60;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'gallery_unavailable');
      }
    } finally {
      if (generation == _generation) _pageLoading = false;
    }
  }

  void _toggle(_GalleryItem item) {
    if (!batch.toggle(item.id, item) && !batch.sending) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(context, 'Select up to 10 items', 'حداکثر ۱۰ مورد انتخاب کنید'),
          ),
        ),
      );
    }
  }

  Future<void> _systemPicker() async {
    if (batch.sending) return;
    try {
      final List<XFile> files;
      if (_mobile) {
        files = await ImagePicker().pickMultipleMedia(limit: 10);
      } else {
        files = await openFiles(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Photos & videos',
              extensions: [
                'jpg',
                'jpeg',
                'png',
                'webp',
                'gif',
                'heic',
                'mp4',
                'mov',
                'mkv',
                'webm',
              ],
            ),
          ],
        );
      }
      if (!mounted || !widget.authorized()) return;
      for (final file in files) {
        final video = RegExp(
          r'\.(mp4|mov|mkv|webm|m4v)$',
          caseSensitive: false,
        ).hasMatch(file.path);
        final item = _GalleryItem(
          id: file.path,
          kind: video ? 'video' : 'image',
          file: File(file.path),
        );
        if (!batch.pending.containsKey(item.id)) _toggle(item);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'picker_unavailable');
    }
  }

  Future<void> _send() async {
    if (batch.sending || batch.pending.isEmpty || !widget.authorized()) return;
    final draft = widget.draft;
    final caption = draft.caption.text;
    final send = widget.send;
    draft.upload = batch.send(
      (item, withCaption) => send(item, withCaption ? caption : ''),
      authorized: widget.authorized,
    ).then((_) {
      if (!draft.disposed && draft.batch.pending.isEmpty && draft.batch.error == null) {
        draft.caption.clear();
        draft.reply = null;
        draft.replyCaptured = false;
      }
    });
    _handedOff = true;
    unawaited(draft.upload!);
    if (mounted) Navigator.pop(context, 'queued');
  }

  Future<void> _previewSelection() async {
    final items = batch.pending.values.toList(growable: false);
    if (items.isEmpty || batch.sending || _previewing) return;
    _previewing = true;
    try {
      final send = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => _GallerySelectionPreview(
            items: items,
            caption: widget.draft.caption,
            authorized: widget.authorized,
          ),
        ),
      );
      if (send == true && mounted && widget.authorized()) await _send();
    } finally {
      _previewing = false;
    }
  }

  @override
  void dispose() {
    ++_generation;
    _libraryRefresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_mobile) PhotoManager.removeChangeCallback(_libraryChanged);
    _galleryScroll.dispose();
    if (!_handedOff) batch.stop(); // the chat owns a handed-off upload
    batch.removeListener(_changed);
    LoomAppLock.instance.removeListener(_locked);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = batch.pending.keys.toList();
    final p = context.loom;
    return PopScope(
      canPop: !batch.sending,
      child: SizedBox.expand(
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: _albums.isEmpty
                        ? Text(
                            _mobile
                                ? tr(context, 'Gallery', 'گالری')
                                : tr(context, 'Choose files', 'انتخاب فایل‌ها'),
                          )
                        : DropdownButton<AssetPathEntity>(
                            isExpanded: true,
                            value: _album,
                            underline: const SizedBox.shrink(),
                            items: _albums
                                .map(
                                  (a) => DropdownMenuItem(
                                    value: a,
                                    child: Text(
                                      a.isAll
                                          ? tr(context, 'Recent', 'اخیر')
                                          : a.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: batch.sending
                                ? null
                                : (album) {
                                    ++_generation;
                                    setState(() {
                                      _album = album;
                                      _assets.clear();
                                      _page = 0;
                                      _more = true;
                                      _pageLoading = false;
                                    });
                                    unawaited(_nextPage());
                                  },
                          ),
                  ),
                  IconButton(
                    tooltip: tr(context, 'System picker', 'انتخابگر سیستم'),
                    onPressed: batch.sending ? null : _systemPicker,
                    icon: const Icon(LoomIcons.folder_open),
                  ),
                  IconButton(
                    tooltip: tr(context, 'Close', 'بستن'),
                    onPressed: batch.sending
                        ? null
                        : () => Navigator.pop(context),
                    icon: const Icon(LoomIcons.close),
                  ),
                ],
              ),
              if (_permission == PermissionState.limited)
                TextButton.icon(
                  onPressed: batch.sending
                      ? null
                      : () async {
                          await PhotoManager.presentLimited(
                            type: RequestType.common,
                          );
                          if (mounted) await _loadLibrary();
                        },
                  icon: const Icon(LoomIcons.photo_library_outlined),
                  label: Text(
                    tr(
                      context,
                      'Manage selected-photo access',
                      'مدیریت دسترسی عکس‌های انتخاب‌شده',
                    ),
                  ),
                ),
              if (_error != null || batch.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    tr(
                      context,
                      'Some items are unavailable or were not sent. Your remaining selection is kept.',
                      'بعضی موارد در دسترس نیستند یا ارسال نشدند؛ انتخاب‌های باقی‌مانده حفظ شده‌اند.',
                    ),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: p.critical),
                  ),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          if (notification.metrics.extentAfter < 400) {
                            unawaited(_nextPage());
                          }
                          return false;
                        },
                        child: CustomScrollView(
                          controller: _galleryScroll,
                          slivers: [
                            if (_assets.isEmpty)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                    children: [
                                      Text(
                                        tr(
                                          context,
                                          _permission?.hasAccess == false
                                              ? 'Gallery permission is denied.'
                                              : 'No photos or videos to show.',
                                          _permission?.hasAccess == false
                                              ? 'مجوز گالری داده نشده است.'
                                              : 'عکس یا ویدیویی موجود نیست.',
                                        ),
                                      ),
                                      FilledButton.icon(
                                        onPressed: batch.sending
                                            ? null
                                            : _systemPicker,
                                        icon: const Icon(
                                          LoomIcons.photo_library_outlined,
                                        ),
                                        label: Text(
                                          tr(
                                            context,
                                            'Choose media',
                                            'انتخاب مدیا',
                                          ),
                                        ),
                                      ),
                                      if (_mobile)
                                        TextButton(
                                          onPressed: () async {
                                            await PhotoManager.openSetting();
                                            if (mounted) {
                                              await _loadLibrary();
                                            }
                                          },
                                          child: Text(
                                            tr(
                                              context,
                                              'Photo access settings',
                                              'تنظیمات دسترسی عکس',
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            SliverGrid(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (_mobile && index == 0) {
                                    return InkWell(
                                      onTap: batch.sending
                                          ? null
                                          : () => Navigator.pop(
                                              context,
                                              'camera',
                                            ),
                                      child: LoomGlassSurface(
                                        blur: false,
                                        strength: LoomGlassStrength.weak,
                                        radius: 14,
                                        child: Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                LoomIcons.camera_alt_outlined,
                                                size: 32,
                                                color: p.primary,
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                tr(context, 'Camera', 'دوربین'),
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.labelMedium,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  final asset =
                                      _assets[index - (_mobile ? 1 : 0)];
                                  return _GalleryThumb(
                                    key: ValueKey(asset.id),
                                    asset: asset,
                                    number: selected.indexOf(asset.id) + 1,
                                    enabled: !batch.sending,
                                    onTap: () => _toggle(
                                      _GalleryItem(
                                        id: asset.id,
                                        asset: asset,
                                        kind: asset.type == AssetType.video
                                            ? 'video'
                                            : 'image',
                                      ),
                                    ),
                                  );
                                },
                                childCount: _assets.length + (_mobile ? 1 : 0),
                              ),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    crossAxisSpacing: 6,
                                    mainAxisSpacing: 6,
                                  ),
                            ),
                            if (_pageLoading)
                              const SliverToBoxAdapter(
                                child: LinearProgressIndicator(),
                              ),
                          ],
                        ),
                      ),
              ),
              if (selected.isNotEmpty) ...[
                TextButton.icon(
                  onPressed: batch.sending ? null : _previewSelection,
                  icon: const Icon(LoomIcons.preview_outlined),
                  label: Text(
                    tr(
                      context,
                      'Preview selection (${selected.length})',
                      'پیش‌نمایش انتخاب‌ها (${selected.length})',
                    ),
                  ),
                ),
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: batch.pending.entries
                        .map(
                          (entry) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: InputChip(
                              label: Text('${selected.indexOf(entry.key) + 1}'),
                              onDeleted: batch.sending
                                  ? null
                                  : () => batch.remove(entry.key),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: widget.draft.caption,
                          enabled: !batch.sending,
                          minLines: 1,
                          maxLines: 3,
                          maxLength: 2000,
                          decoration: InputDecoration(
                            hintText: tr(
                              context,
                              'Add a caption',
                              'افزودن توضیح',
                            ),
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: batch.sending ? null : _previewSelection,
                        icon: const Icon(LoomIcons.arrow_upward),
                        label: Text(
                          '${tr(context, 'Send', 'ارسال')} (${selected.length})',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (batch.sending)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    children: [
                      LinearProgressIndicator(
                        value: batch.total == 0
                            ? null
                            : batch.completed / batch.total,
                      ),
                      Text('${batch.completed} / ${batch.total}'),
                    ],
                  ),
                ),
              if (MediaQuery.viewInsetsOf(context).bottom == 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                  child: LayoutBuilder(
                    builder: (context, bounds) => LoomGlassSurface(
                      liveBackdrop: true,
                      radius: 24,
                      padding: const EdgeInsets.all(4),
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children:
                              <Widget>[
                                    _category(
                                      LoomIcons.photo_library_outlined,
                                      tr(context, 'Gallery', 'گالری'),
                                      null,
                                      selected: true,
                                    ),
                                    _category(
                                      LoomIcons.gif_box_outlined,
                                      'GIF',
                                      'gif',
                                    ),
                                    _category(
                                      LoomIcons.music_note_outlined,
                                      tr(context, 'Music', 'موسیقی'),
                                      'music',
                                    ),
                                    _category(
                                      LoomIcons.attach_file_rounded,
                                      tr(context, 'File', 'فایل'),
                                      'file',
                                    ),
                                    _category(
                                      LoomIcons.location_on_outlined,
                                      tr(context, 'Location', 'موقعیت'),
                                      'location',
                                    ),
                                    _category(
                                      LoomIcons.share_location_outlined,
                                      tr(
                                        context,
                                        'Live location',
                                        'موقعیت زنده',
                                      ),
                                      'live',
                                    ),
                                    if (widget.canShareAddress)
                                      _category(
                                        LoomIcons.person_outline,
                                        tr(context, 'My address', 'نشانی من'),
                                        'contact',
                                      ),
                                    _category(
                                      LoomIcons.content_paste,
                                      tr(context, 'Paste text', 'درج متن'),
                                      'paste',
                                    ),
                                  ]
                                  .map(
                                    (item) => SizedBox(
                                      width: (bounds.maxWidth - 24) / 4,
                                      height:
                                          40 +
                                          MediaQuery.textScalerOf(
                                                context,
                                              ).scale(12) *
                                              2.4,
                                      child: item,
                                    ),
                                  )
                                  .toList(),
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
  }

  Widget _category(
    IconData icon,
    String label,
    String? value, {
    bool selected = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: InkWell(
      onTap: value == null || batch.sending
          ? null
          : () => Navigator.pop(context, value),
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: LoomAccessibility.fromContext(context).reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: selected
              ? context.loom.primary.withValues(alpha: .12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: selected
                  ? context.loom.primary
                  : context.loom.textSecondary,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: selected
                    ? context.loom.primary
                    : context.loom.textSecondary,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Visible tiles alone retain a bounded, downsampled thumbnail. No keep-alive
/// or full-resolution gallery byte cache is used.
class _GalleryThumb extends StatefulWidget {
  const _GalleryThumb({
    required this.asset,
    required this.number,
    required this.onTap,
    required this.enabled,
    super.key,
  });
  final AssetEntity asset;
  final int number;
  final VoidCallback onTap;
  final bool enabled;
  @override
  State<_GalleryThumb> createState() => _GalleryThumbState();
}

class _GalleryThumbState extends State<_GalleryThumb> {
  late final Future<Uint8List?> _thumbnail = widget.asset.thumbnailDataWithSize(
    const ThumbnailSize(256, 256),
    quality: 75,
  );
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: widget.enabled ? widget.onTap : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _thumbnail,
              builder: (context, snapshot) {
                if (snapshot.hasError ||
                    snapshot.connectionState == ConnectionState.done &&
                        snapshot.data == null) {
                  return const Icon(LoomIcons.broken_image_outlined);
                }
                return snapshot.data == null
                    ? ColoredBox(color: context.loom.surfaceMuted)
                    : Image.memory(
                        snapshot.data!,
                        fit: BoxFit.cover,
                        cacheWidth: 256,
                      );
              },
            ),
            PositionedDirectional(
              top: 6,
              end: 6,
              child: AnimatedContainer(
                duration: LoomAccessibility.fromContext(context).reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.number > 0
                      ? context.loom.primary
                      : Colors.black38,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                alignment: Alignment.center,
                child: widget.number > 0
                    ? Text(
                        '${widget.number}',
                        style: TextStyle(
                          color: context.loom.onPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
            ),
            if (widget.asset.type == AssetType.video)
              PositionedDirectional(
                bottom: 4,
                end: 4,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.all(3),
                  child: Text(
                    mediaTime(Duration(seconds: widget.asset.duration)),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
