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
  bool _multiSelect = false;
  bool _singleSending = false;
  _GalleryItem? _previewItem;
  Future<File?>? _previewFile;
  final _edited = <String, File>{};
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
    if (!batch.toggle(item.id, item) && !batch.sending) _showLimitSnack();
  }

  void _showLimitSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr(context, 'Select up to 10 items', 'حداکثر ۱۰ مورد انتخاب کنید'),
        ),
      ),
    );
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
    draft.upload = batch
        .send(
          (item, withCaption) => send(item, withCaption ? caption : ''),
          authorized: widget.authorized,
        )
        .then((_) {
          if (!draft.disposed &&
              draft.batch.pending.isEmpty &&
              draft.batch.error == null) {
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
            onEdit: _replaceItemWithEdit,
          ),
        ),
      );
      if (send == true && mounted && widget.authorized()) await _send();
    } finally {
      _previewing = false;
    }
  }

  void _openPreview(_GalleryItem item) {
    if (batch.sending || _singleSending) return;
    setState(() {
      _previewItem = item;
      _previewFile = item.resolve();
    });
  }

  void _closePreview() {
    if (!mounted) return;
    setState(() {
      _previewItem = null;
      _previewFile = null;
    });
  }

  /// Swaps an edited file into the batch; returns the replacement item.
  Future<_GalleryItem?> _replaceItemWithEdit(_GalleryItem item) async {
    if (batch.sending || _singleSending) return null;
    final source = await item.resolve();
    if (!mounted || source == null) return null;
    final edited = await showLoomImageEditor(context, source: source);
    if (!mounted || edited == null) return null;
    final replacement = _GalleryItem(
      id: item.id,
      kind: item.kind,
      file: edited,
    );
    _edited[item.id] = edited;
    if (batch.pending.containsKey(item.id)) {
      batch.replace(item.id, replacement);
    }
    return replacement;
  }

  /// Swaps the previewed item's backing file with the editor output. Pending
  /// batch payloads are replaced in place so the selection order is kept.
  Future<void> _editPreview(_GalleryItem item) async {
    if (batch.sending || _singleSending) return;
    final replacement = await _replaceItemWithEdit(item);
    if (!mounted || replacement == null) return;
    setState(() {
      _previewItem = replacement;
      _previewFile = replacement.resolve();
    });
  }

  /// Confirm-send from the single preview: an isolated item is sent directly
  /// (pops 'sent'); anything batch-related keeps the handed-off upload flow.
  Future<void> _sendFromPreview(_GalleryItem item) async {
    if (batch.sending || _singleSending || !widget.authorized()) return;
    if (batch.pending.isNotEmpty) {
      if (!batch.pending.containsKey(item.id) && !batch.toggle(item.id, item)) {
        _showLimitSnack();
        return;
      }
      await _send();
      return;
    }
    final caption = widget.draft.caption.text;
    final send = widget.send;
    setState(() => _singleSending = true);
    var ok = false;
    try {
      ok = await send(item, caption);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      _handedOff = true;
      Navigator.pop(context, 'sent');
      return;
    }
    setState(() => _singleSending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr(
            context,
            'Could not send. Try again.',
            'ارسال نشد؛ دوباره تلاش کنید.',
          ),
        ),
      ),
    );
  }

  void _switchAlbum(AssetPathEntity album) {
    if (!mounted) return;
    ++_generation;
    setState(() {
      _album = album;
      _assets.clear();
      _page = 0;
      _more = true;
      _pageLoading = false;
    });
    unawaited(_nextPage());
  }

  Future<void> _showAlbumPicker() async {
    if (batch.sending || _albums.isEmpty) return;
    final albums = _albums;
    final current = _album;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LoomGlassSurface(
            radius: 24,
            padding: const EdgeInsets.all(6),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * .55,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: albums.length,
                itemBuilder: (context, index) {
                  final album = albums[index];
                  return _AlbumTile(
                    album: album,
                    label: album.isAll
                        ? tr(sheetContext, 'Recent', 'اخیر')
                        : album.name,
                    selected: current != null && album.id == current.id,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _switchAlbum(album);
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
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
    final previewItem = _previewItem;
    return PopScope(
      canPop: !batch.sending && previewItem == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted && _previewItem != null) _closePreview();
      },
      child: SizedBox.expand(
        child: SafeArea(
          top: false,
          child: previewItem != null
              ? _buildPreviewStage(previewItem)
              : Column(
                  children: [
                    _buildHeader(),
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
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: context.loom.critical),
                        ),
                      ),
                    if (MediaQuery.viewInsetsOf(context).bottom == 0)
                      _buildActionRow(),
                    _buildGrid(selected),
                    if (selected.isNotEmpty) _buildTray(selected),
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
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final p = context.loom;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: LoomGlassSurface(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          children: [
            IconButton(
              tooltip: tr(context, 'Close', 'بستن'),
              onPressed: batch.sending
                  ? null
                  : () => Navigator.pop(context, null),
              icon: const Icon(LoomIcons.close),
            ),
            Expanded(
              child: Text(
                tr(context, 'Send', 'ارسال'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (_mobile) Flexible(child: _buildAlbumChip(p)),
            IconButton(
              tooltip: tr(context, 'Multi-select', 'انتخاب چندتایی'),
              onPressed: batch.sending
                  ? null
                  : () => setState(() => _multiSelect = !_multiSelect),
              icon: Icon(
                LoomIcons.done_all,
                size: 22,
                color: _multiSelect ? p.primary : p.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumChip(LoomPalette p) {
    final album = _album;
    final label = album == null
        ? tr(context, 'Gallery', 'گالری')
        : album.isAll
        ? tr(context, 'Recent', 'اخیر')
        : album.name;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 4),
      child: Material(
        color: p.primary.withValues(alpha: .10),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: batch.sending || _albums.isEmpty ? null : _showAlbumPicker,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LoomIcons.photo_library_outlined,
                  size: 15,
                  color: p.primary,
                ),
                const SizedBox(width: 6),
                // Flexible (not a fixed max box): the chip may be squeezed by
                // the header row on narrow screens, and the label must
                // ellipsize instead of pushing the row past its budget.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  LoomIcons.keyboard_arrow_down_rounded,
                  size: 15,
                  color: p.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Every action lives in one uniform, horizontally scrollable row so all of
  /// them stay reachable on narrow screens.
  Widget _buildActionRow() {
    return SizedBox(
      height: 90,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            for (final tile in _actionTiles())
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: SizedBox(width: 78, height: 78, child: tile),
              ),
          ],
        ),
      ),
    );
  }

  List<_GalleryActionTile> _actionTiles() => [
    _GalleryActionTile(
      icon: LoomIcons.photo_library_outlined,
      label: tr(context, 'Gallery', 'گالری'),
      tooltip: tr(context, 'System picker', 'انتخابگر سیستم'),
      enabled: !batch.sending,
      onTap: _systemPicker,
    ),
    if (_mobile)
      _GalleryActionTile(
        icon: LoomIcons.camera_alt_outlined,
        label: tr(context, 'Camera', 'دوربین'),
        enabled: !batch.sending,
        onTap: () => Navigator.pop(context, 'camera'),
      ),
    _GalleryActionTile(
      icon: LoomIcons.videocam_outlined,
      label: tr(context, 'Video', 'ویدیو'),
      enabled: !batch.sending,
      onTap: () => Navigator.pop(context, 'video'),
    ),
    _GalleryActionTile(
      icon: LoomIcons.attach_file_rounded,
      label: tr(context, 'File', 'فایل'),
      enabled: !batch.sending,
      onTap: () => Navigator.pop(context, 'file'),
    ),
    _GalleryActionTile(
      icon: LoomIcons.music_note_outlined,
      label: tr(context, 'Music', 'موسیقی'),
      enabled: !batch.sending,
      onTap: () => Navigator.pop(context, 'music'),
    ),
    _GalleryActionTile(
      icon: LoomIcons.gif_box_outlined,
      label: 'GIF',
      enabled: !batch.sending,
      onTap: () => Navigator.pop(context, 'gif'),
    ),
    _GalleryActionTile(
      icon: LoomIcons.location_on_outlined,
      label: tr(context, 'Location', 'موقعیت'),
      enabled: !batch.sending,
      onTap: () => Navigator.pop(context, 'location'),
    ),
    _GalleryActionTile(
      icon: LoomIcons.share_location_outlined,
      label: tr(context, 'Live location', 'موقعیت زنده'),
      enabled: !batch.sending,
      onTap: () => Navigator.pop(context, 'live'),
    ),
    if (widget.canShareAddress)
      _GalleryActionTile(
        icon: LoomIcons.person_outline,
        label: tr(context, 'My address', 'نشانی من'),
        enabled: !batch.sending,
        onTap: () => Navigator.pop(context, 'contact'),
      ),
    _GalleryActionTile(
      icon: LoomIcons.content_paste,
      label: tr(context, 'Paste text', 'درج متن'),
      enabled: !batch.sending,
      onTap: () => Navigator.pop(context, 'paste'),
    ),
  ];

  Widget _buildGrid(List<String> selected) {
    if (_loading) {
      return const Expanded(child: Center(child: CircularProgressIndicator()));
    }
    return Expanded(
      child: LayoutBuilder(
        builder: (context, bounds) {
          final columns = bounds.maxWidth >= 560 ? 4 : 3;
          return NotificationListener<ScrollNotification>(
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
                  SliverToBoxAdapter(child: _buildEmptyState()),
                SliverGrid(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final asset = _assets[index];
                    return _GalleryThumb(
                      key: ValueKey(asset.id),
                      asset: asset,
                      file: _edited[asset.id],
                      number: selected.indexOf(asset.id) + 1,
                      multiSelect: _multiSelect,
                      enabled: !batch.sending,
                      onTap: () {
                        // Tap always toggles selection — opening the heavy
                        // file-backed preview on a plain tap would also
                        // resolve AssetEntity.file, which asserts on test
                        // hosts. Long-press is the preview gesture.
                        final item = _GalleryItem(
                          id: asset.id,
                          asset: asset,
                          kind: asset.type == AssetType.video
                              ? 'video'
                              : 'image',
                          file: _edited[asset.id],
                        );
                        _toggle(item);
                      },
                      onLongPress: () => _openPreview(
                        _GalleryItem(
                          id: asset.id,
                          asset: asset,
                          kind: asset.type == AssetType.video
                              ? 'video'
                              : 'image',
                          file: _edited[asset.id],
                        ),
                      ),
                    );
                  }, childCount: _assets.length),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                ),
                if (_pageLoading)
                  const SliverToBoxAdapter(child: LinearProgressIndicator()),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
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
            onPressed: batch.sending ? null : _systemPicker,
            icon: const Icon(LoomIcons.photo_library_outlined),
            label: Text(tr(context, 'Choose media', 'انتخاب مدیا')),
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
                tr(context, 'Photo access settings', 'تنظیمات دسترسی عکس'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTray(List<String> selected) {
    final entries = batch.pending.entries.toList(growable: false);
    return LoomReveal(
      offset: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: LoomGlassSurface(
          liveBackdrop: true,
          radius: 22,
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 50,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: _TrayThumb(
                        key: ValueKey(entry.key),
                        item: entry.value,
                        number: selected.indexOf(entry.key) + 1,
                        enabled: !batch.sending,
                        onRemove: () => batch.remove(entry.key),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _buildCaptionField()),
                  const SizedBox(width: 8),
                  _GallerySendFab(
                    count: selected.length,
                    busy: batch.sending,
                    enabled: !batch.sending && selected.isNotEmpty,
                    onTap: selected.length > 1 ? _previewSelection : _send,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCaptionField({bool dark = false}) {
    final p = context.loom;
    return TextField(
      controller: widget.draft.caption,
      enabled: !batch.sending && !_singleSending,
      minLines: 1,
      maxLines: 5,
      maxLength: 2000,
      style: dark ? const TextStyle(color: Colors.white) : null,
      cursorColor: dark ? Colors.white : null,
      decoration: InputDecoration(
        hintText: tr(context, 'Caption', 'برچسب'),
        hintStyle: dark ? const TextStyle(color: Colors.white54) : null,
        counterText: '',
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        filled: true,
        fillColor: dark
            ? Colors.white.withValues(alpha: .08)
            : p.surfaceMuted.withValues(alpha: .6),
        border: _pillBorder(dark ? Colors.white24 : Colors.transparent),
        enabledBorder: _pillBorder(dark ? Colors.white24 : Colors.transparent),
        focusedBorder: _pillBorder(dark ? Colors.white54 : p.primary),
      ),
    );
  }

  OutlineInputBorder _pillBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(26),
    borderSide: BorderSide(color: color),
  );

  /// Full-bleed single-asset stage shown in place of the grid. The pop
  /// contract stays intact: confirm-send pops 'sent'/'queued' via the same
  /// send flows, back returns to the grid, and dismissing pops null.
  Widget _buildPreviewStage(_GalleryItem item) {
    final isVideo = item.kind == 'video';
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: ColoredBox(
        color: Colors.black,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: tr(context, 'Back', 'بازگشت'),
                      onPressed: _closePreview,
                      icon: const Icon(
                        LoomIcons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        tr(context, 'Preview', 'پیش‌نمایش'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (!isVideo)
                      IconButton(
                        tooltip: tr(context, 'Edit', 'ویرایش'),
                        onPressed: _singleSending || batch.sending
                            ? null
                            : () => unawaited(_editPreview(item)),
                        icon: const Icon(
                          LoomIcons.tune_rounded,
                          color: Colors.white,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FutureBuilder<File?>(
                          future: _previewFile,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState !=
                                ConnectionState.done) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            final file = snapshot.data;
                            if (file == null || snapshot.hasError) {
                              return Center(
                                child: Text(
                                  tr(
                                    context,
                                    'This item is unavailable.',
                                    'این مورد در دسترس نیست.',
                                  ),
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              );
                            }
                            if (isVideo) {
                              return Center(
                                child: _LocalVideoPreview(
                                  key: ValueKey(file.path),
                                  file: file,
                                  active: true,
                                ),
                              );
                            }
                            return InteractiveViewer(
                              maxScale: 4,
                              child: Center(
                                child: Image.file(
                                  file,
                                  fit: BoxFit.contain,
                                  cacheWidth: 1080,
                                  errorBuilder: (_, _, _) => const Icon(
                                    LoomIcons.broken_image_outlined,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        if (isVideo && item.asset != null)
                          PositionedDirectional(
                            bottom: 8,
                            end: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                mediaTime(
                                  Duration(seconds: item.asset!.duration),
                                ),
                                textDirection: TextDirection.ltr,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(child: _buildCaptionField(dark: true)),
                    const SizedBox(width: 8),
                    _GallerySendFab(
                      count: batch.pending.length,
                      busy: _singleSending || batch.sending,
                      enabled: !_singleSending && !batch.sending,
                      onTap: () => unawaited(_sendFromPreview(item)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uniform 78px attachment action tile with a 22px icon and an 11px label.
class _GalleryActionTile extends StatelessWidget {
  const _GalleryActionTile({
    required this.icon,
    required this.label,
    required this.enabled,
    this.onTap,
    this.tooltip,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    Widget tile = LoomGlassSurface(
      blur: false,
      strength: LoomGlassStrength.weak,
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: enabled ? p.primary : p.textMuted),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 11,
                height: 1.15,
                color: enabled ? p.textSecondary : p.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
    if (tooltip != null) {
      tile = Tooltip(message: tooltip!, child: tile);
    }
    return Opacity(
      opacity: enabled ? 1 : .55,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: tile,
      ),
    );
  }
}

/// Visible tiles alone retain a bounded, downsampled thumbnail. No keep-alive
/// or full-resolution gallery byte cache is used.
class _GalleryThumb extends StatefulWidget {
  const _GalleryThumb({
    required this.asset,
    required this.number,
    required this.multiSelect,
    required this.onTap,
    required this.onLongPress,
    required this.enabled,
    this.file,
    super.key,
  });
  final AssetEntity asset;
  final int number;
  final bool multiSelect;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool enabled;
  final File? file;
  @override
  State<_GalleryThumb> createState() => _GalleryThumbState();
}

class _GalleryThumbState extends State<_GalleryThumb> {
  late final Future<Uint8List?> _thumbnail = widget.asset.thumbnailDataWithSize(
    const ThumbnailSize(256, 256),
    quality: 75,
  );
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final selected = widget.number > 0;
    final reduceMotion = LoomAccessibility.fromContext(context).reduceMotion;
    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.scale(scale: .97 + .03 * t, child: child),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: widget.enabled ? widget.onTap : null,
            onLongPress: widget.enabled ? widget.onLongPress : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildMedia(p),
                if (selected)
                  const ColoredBox(
                    color: Colors.black26,
                    child: Center(child: _GallerySelectionCheck()),
                  ),
                PositionedDirectional(
                  top: 5,
                  end: 5,
                  child: RepaintBoundary(
                    child: AnimatedContainer(
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 150),
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? p.primary : Colors.black38,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      alignment: Alignment.center,
                      child: selected
                          ? Text(
                              '${widget.number}',
                              style: TextStyle(
                                color: p.onPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : widget.multiSelect
                          ? null
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                if (widget.asset.type == AssetType.video)
                  PositionedDirectional(
                    bottom: 4,
                    end: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        mediaTime(Duration(seconds: widget.asset.duration)),
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMedia(LoomPalette p) {
    final file = widget.file;
    if (file != null) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: 256,
        errorBuilder: (_, _, _) => const Icon(LoomIcons.broken_image_outlined),
      );
    }
    return FutureBuilder<Uint8List?>(
      future: _thumbnail,
      builder: (context, snapshot) {
        if (snapshot.hasError ||
            snapshot.connectionState == ConnectionState.done &&
                snapshot.data == null) {
          return const Icon(LoomIcons.broken_image_outlined);
        }
        return snapshot.data == null
            ? ColoredBox(color: context.loom.surfaceMuted)
            : Image.memory(snapshot.data!, fit: BoxFit.cover, cacheWidth: 256);
      },
    );
  }
}

/// Dim + check marker painted on selected grid cells.
class _GallerySelectionCheck extends StatelessWidget {
  const _GallerySelectionCheck();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 6)],
      ),
      alignment: Alignment.center,
      child: const Icon(
        LoomIcons.check_rounded,
        size: 18,
        color: Colors.black87,
      ),
    );
  }
}

/// 56px circular primary send button with an optional count badge.
class _GallerySendFab extends StatelessWidget {
  const _GallerySendFab({
    required this.count,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });
  final int count;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Material(
              color: enabled ? p.primary : p.primary.withValues(alpha: .45),
              shape: const CircleBorder(),
              elevation: enabled ? 3 : 0,
              shadowColor: p.shadow,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: enabled && !busy ? onTap : null,
                child: Center(
                  child: busy
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: p.onPrimary,
                          ),
                        )
                      : Icon(
                          LoomIcons.arrow_upward,
                          size: 26,
                          color: p.onPrimary,
                        ),
                ),
              ),
            ),
          ),
          if (count > 1)
            PositionedDirectional(
              top: -2,
              end: -2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: p.primary, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$count',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: p.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 46px selected-item chip in the bottom tray; tapping it removes the item.
class _TrayThumb extends StatefulWidget {
  const _TrayThumb({
    required this.item,
    required this.number,
    required this.enabled,
    required this.onRemove,
    super.key,
  });
  final _GalleryItem item;
  final int number;
  final bool enabled;
  final VoidCallback onRemove;
  @override
  State<_TrayThumb> createState() => _TrayThumbState();
}

class _TrayThumbState extends State<_TrayThumb> {
  late final Future<Uint8List?>? _thumb = widget.item.asset
      ?.thumbnailDataWithSize(const ThumbnailSize(128, 128));
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return Opacity(
      opacity: widget.enabled ? 1 : .55,
      child: SizedBox(
        width: 46,
        height: 46,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildMedia(p),
              ),
            ),
            if (widget.number > 0)
              PositionedDirectional(
                bottom: 2,
                end: 2,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.primary,
                    border: Border.all(color: Colors.white, width: 1),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${widget.number}',
                    style: TextStyle(
                      color: p.onPrimary,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      height: 1,
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.enabled ? widget.onRemove : null,
                  borderRadius: BorderRadius.circular(12),
                  child: Align(
                    alignment: AlignmentDirectional.topEnd,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black54,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          LoomIcons.close,
                          size: 10,
                          color: Colors.white,
                        ),
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

  Widget _buildMedia(LoomPalette p) {
    final file = widget.item.file;
    if (file != null) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: 128,
        errorBuilder: (_, _, _) => ColoredBox(
          color: p.surfaceMuted,
          child: Icon(
            LoomIcons.broken_image_outlined,
            size: 16,
            color: p.textSecondary,
          ),
        ),
      );
    }
    return FutureBuilder<Uint8List?>(
      future: _thumb,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            cacheWidth: 128,
            gaplessPlayback: true,
          );
        }
        return ColoredBox(
          color: p.surfaceMuted,
          child: Icon(
            LoomIcons.broken_image_outlined,
            size: 16,
            color: p.textSecondary,
          ),
        );
      },
    );
  }
}

/// One album row inside the album picker bottom sheet.
class _AlbumTile extends StatefulWidget {
  const _AlbumTile({
    required this.album,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final AssetPathEntity album;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<_AlbumTile> {
  late final Future<Uint8List?> _thumb = _load();
  late final Future<int> _count = widget.album.assetCountAsync;
  Future<Uint8List?> _load() async {
    try {
      final first = await widget.album.getAssetListPaged(page: 0, size: 1);
      if (first.isEmpty) return null;
      return await first.first.thumbnailDataWithSize(
        const ThumbnailSize(128, 128),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 44,
                height: 44,
                child: FutureBuilder<Uint8List?>(
                  future: _thumb,
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    if (bytes != null) {
                      return Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        cacheWidth: 128,
                        gaplessPlayback: true,
                      );
                    }
                    return ColoredBox(
                      color: p.surfaceMuted,
                      child: Icon(
                        LoomIcons.photo_library_outlined,
                        size: 18,
                        color: p.textMuted,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            FutureBuilder<int>(
              future: _count,
              builder: (context, snapshot) => Text(
                '${snapshot.data ?? ''}',
                style: TextStyle(fontSize: 12, color: p.textMuted),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox.square(
              dimension: 20,
              child: widget.selected
                  ? Icon(LoomIcons.check_rounded, size: 20, color: p.primary)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bridge the platform-independent batch notifier into the chat widget tree.
class _MediaBatchProgress extends StatefulWidget {
  const _MediaBatchProgress({required this.batch, required this.builder});
  final MediaBatchController<_GalleryItem> batch;
  final WidgetBuilder builder;
  @override
  State<_MediaBatchProgress> createState() => _MediaBatchProgressState();
}

class _MediaBatchProgressState extends State<_MediaBatchProgress> {
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.batch.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _MediaBatchProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.batch != widget.batch) {
      oldWidget.batch.removeListener(_changed);
      widget.batch.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.batch.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
