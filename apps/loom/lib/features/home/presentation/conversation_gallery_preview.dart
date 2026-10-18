part of 'messenger_shell.dart';

class _GallerySelectionPreview extends StatefulWidget {
  const _GallerySelectionPreview({
    required this.items,
    required this.caption,
    required this.authorized,
  });
  final List<_GalleryItem> items;
  final TextEditingController caption;
  final bool Function() authorized;
  @override
  State<_GallerySelectionPreview> createState() =>
      _GallerySelectionPreviewState();
}

class _GallerySelectionPreviewState extends State<_GallerySelectionPreview> {
  final _files = <int, Future<File?>>{};
  int _page = 0;
  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_locked);
  }

  void _locked() {
    if (LoomAppLock.instance.locked) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    LoomAppLock.instance.removeListener(_locked);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: LoomGlassAppBar(
      title: Text('${_page + 1} / ${widget.items.length}'),
    ),
    body: LoomAppLock.instance.locked
        ? const SizedBox.shrink()
        : Column(
            children: [
              Expanded(
                child: PageView.builder(
                  onPageChanged: (page) => setState(() => _page = page),
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) => FutureBuilder<File?>(
                    future: _files.putIfAbsent(
                      index,
                      () => widget.items[index].resolve(),
                    ),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
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
                          ),
                        );
                      }
                      return Center(
                        child: widget.items[index].kind == 'video'
                            ? _LocalVideoPreview(
                                key: ValueKey(file.path),
                                file: file,
                                active: index == _page,
                              )
                            : Image.file(
                                file,
                                fit: BoxFit.contain,
                                cacheWidth: 1080,
                                errorBuilder: (_, _, _) =>
                                    const Icon(LoomIcons.broken_image_outlined),
                              ),
                      );
                    },
                  ),
                ),
              ),
              LoomReveal(
                offset: 6,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LoomComposerKeyboard(
                          controller: widget.caption,
                          enabled: widget.authorized(),
                          onSend: () => Navigator.pop(context, true),
                          child: TextField(
                            controller: widget.caption,
                            minLines: 1,
                            maxLines: 3,
                            maxLength: 2000,
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: tr(
                                context,
                                'Caption for this selection',
                                'توضیح برای این انتخاب‌ها',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: widget.authorized()
                              ? () => Navigator.pop(context, true)
                              : null,
                          icon: const Icon(LoomIcons.send_rounded),
                          label: Text(
                            tr(
                              context,
                              'Send ${widget.items.length} items',
                              'ارسال ${widget.items.length} مورد',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}
