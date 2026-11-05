part of 'messenger_shell.dart';

/// Fullscreen swipeable preview over the current gallery selection, in the
/// Telegram language: black stage, transparent top bar with counter, remove
/// and edit actions, a thumbnail strip to jump between items and a caption
/// pill with the round send button.
class _GallerySelectionPreview extends StatefulWidget {
  const _GallerySelectionPreview({
    required this.items,
    required this.caption,
    required this.authorized,
    required this.onEdit,
  });
  final List<_GalleryItem> items;
  final TextEditingController caption;
  final bool Function() authorized;

  /// Swaps an edited file into the batch; the preview rebuilds with the
  /// replacement item. Null keeps the item unchanged.
  final Future<_GalleryItem?> Function(_GalleryItem) onEdit;
  @override
  State<_GallerySelectionPreview> createState() =>
      _GallerySelectionPreviewState();
}

class _GallerySelectionPreviewState extends State<_GallerySelectionPreview> {
  final _files = <int, Future<File?>>{};
  late List<_GalleryItem> _items;
  int _page = 0;
  bool _editing = false;
  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _items = widget.items;
    LoomAppLock.instance.addListener(_locked);
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      if (mounted) Navigator.pop(context);
    }
  }

  void _removeCurrent() {
    if (_items.length <= 1) {
      Navigator.pop(context);
      return;
    }
    final index = _page.clamp(0, _items.length - 1);
    setState(() {
      _items = [..._items]..removeAt(index);
      _files.clear();
      _page = index.clamp(0, _items.length - 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _pageController.jumpToPage(_page);
      }
    });
  }

  Future<void> _editCurrent() async {
    if (_editing) return;
    final item = _items[_page.clamp(0, _items.length - 1)];
    if (item.kind == 'video') return;
    setState(() => _editing = true);
    try {
      final replacement = await widget.onEdit(item);
      if (replacement == null || !mounted) return;
      setState(() {
        _items = [
          for (final existing in _items)
            if (identical(existing, item)) replacement else existing,
        ];
        _files.remove(_page);
      });
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    LoomAppLock.instance.removeListener(_locked);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (LoomAppLock.instance.locked) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final item = _items[_page.clamp(0, _items.length - 1)];
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // Transparent flat top bar.
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: tr(context, 'Close', 'بستن'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(
                      LoomIcons.close,
                      color: Colors.white,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${_page + 1} / ${_items.length}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (item.kind != 'video')
                    IconButton(
                      tooltip: tr(context, 'Edit', 'ویرایش'),
                      onPressed: _editCurrent,
                      icon: const Icon(
                        LoomIcons.tune_rounded,
                        color: Colors.white,
                      ),
                    )
                  else
                    const SizedBox(width: 48),
                  IconButton(
                    tooltip: tr(
                      context,
                      'Remove from selection',
                      'حذف از انتخاب‌ها',
                    ),
                    onPressed: _removeCurrent,
                    icon: const Icon(
                      LoomIcons.delete_outline,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return FutureBuilder<File?>(
                    future: _files.putIfAbsent(
                      index,
                      () => item.resolve(),
                    ),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        );
                      }
                      final file = snapshot.data;
                      if (file == null || snapshot.hasError) {
                        return Center(
                          child: Text(
                            tr(
                              context,
                              'This item is unavailable. Remove it from your selection.',
                              'این مورد در دسترس نیست؛ آن را از انتخاب‌ها حذف کنید.',
                            ),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: item.kind == 'video'
                              ? _LocalVideoPreview(
                                  key: ValueKey(file.path),
                                  file: file,
                                  active: index == _page,
                                )
                              : InteractiveViewer(
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
                                ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            // Thumbnail strip: jump between the selected items.
            if (_items.length > 1)
              SizedBox(
                height: 54,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final thumb = _SelectionStripThumb(
                      key: ValueKey('strip-$index'),
                      item: _items[index],
                      selected: index == _page,
                      onTap: () {
                        _pageController.jumpToPage(index);
                      },
                    );
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: thumb,
                    );
                  },
                ),
              ),
            // Caption pill + round send button.
            LoomReveal(
              offset: 6,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: LoomComposerKeyboard(
                          controller: widget.caption,
                          enabled: widget.authorized(),
                          onSend: () => Navigator.pop(context, true),
                          child: TextField(
                            controller: widget.caption,
                            minLines: 1,
                            maxLines: 3,
                            maxLength: 2000,
                            style: const TextStyle(color: Colors.white),
                            cursorColor: Colors.white,
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: tr(
                                context,
                                'Caption for this selection',
                                'توضیح برای این انتخاب‌ها',
                              ),
                              hintStyle: const TextStyle(color: Colors.white54),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              filled: true,
                              fillColor: Colors.white.withValues(alpha: .08),
                              border: _previewPillBorder(Colors.white24),
                              enabledBorder: _previewPillBorder(
                                Colors.white24,
                              ),
                              focusedBorder: _previewPillBorder(
                                Colors.white54,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _GallerySendFab(
                        count: _items.length,
                        busy: _editing,
                        enabled: widget.authorized() && !_editing,
                        onTap: () => Navigator.pop(context, true),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  OutlineInputBorder _previewPillBorder(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(26),
    borderSide: BorderSide(color: color),
  );
}

/// 46px rounded thumb in the selection strip.
class _SelectionStripThumb extends StatefulWidget {
  const _SelectionStripThumb({
    required this.item,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final _GalleryItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SelectionStripThumb> createState() => _SelectionStripThumbState();
}

class _SelectionStripThumbState extends State<_SelectionStripThumb> {
  late final Future<Uint8List?>? _thumb = widget.item.asset
      ?.thumbnailDataWithSize(const ThumbnailSize(128, 128));
  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    Widget media;
    final file = widget.item.file;
    if (file != null) {
      media = Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: 128,
        errorBuilder: (_, _, _) => Icon(
          LoomIcons.broken_image_outlined,
          size: 16,
          color: p.textSecondary,
        ),
      );
    } else {
      media = FutureBuilder<Uint8List?>(
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
          return Icon(
            LoomIcons.broken_image_outlined,
            size: 16,
            color: p.textSecondary,
          );
        },
      );
    }
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 46,
        height: 46,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: widget.selected ? p.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: media,
      ),
    );
  }
}
