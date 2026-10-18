import 'dart:async';
import 'dart:io';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/loom_strings.dart';
import '../../../app/chat_wallpaper.dart';

class LoomWallpaperEditor extends StatefulWidget {
  const LoomWallpaperEditor({this.chatId, super.key});
  final String? chatId;
  @override
  State<LoomWallpaperEditor> createState() => _WallpaperEditorState();
}

class _WallpaperEditorState extends State<LoomWallpaperEditor> {
  final store = LoomWallpaperStore.instance;
  LoomWallpaper? _draft;
  String? _key;
  bool _busy = false;
  final _imported = <LoomWallpaper>[];
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final key = await LoomWallpaperStore.chatKey(widget.chatId);
    await store.load();
    if (mounted) {
      setState(() {
        _key = key;
        _draft = store.selection(key);
      });
    }
  }

  Future<void> _photo() async {
    setState(() => _busy = true);
    try {
      File? file;
      if (Platform.isAndroid || Platform.isIOS) {
        final image = await ImagePicker().pickImage(
          source: ImageSource.gallery,
        );
        if (image != null) file = File(image.path);
      } else {
        final image = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: 'Images',
              extensions: ['jpg', 'jpeg', 'png'],
            ),
          ],
        );
        if (image != null) file = File(image.path);
      }
      if (file == null) return;
      final wallpaper = await store.importPhoto(file);
      if (!mounted) {
        await store.discardPhoto(wallpaper);
        return;
      }
      _imported.add(wallpaper);
      setState(() => _draft = wallpaper);
    } catch (_) {
      if (mounted) _error();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _error() => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        tr(
          context,
          'Wallpaper could not be saved. Choose a JPG/PNG smaller than 16 MiB.',
          'ذخیرهٔ پس‌زمینه ممکن نشد؛ JPG یا PNG کوچک‌تر از ۱۶ مگابایت انتخاب کنید.',
        ),
      ),
    ),
  );
  Future<void> _apply({bool reset = false}) async {
    setState(() => _busy = true);
    try {
      await store.set(_key, reset ? null : _draft);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        _error();
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    for (final image in _imported) {
      unawaited(store.discardPhoto(image));
    }
    super.dispose();
  }

  Widget _preset(BuildContext context, LoomWallpaper draft, String style) {
    final label = switch (style) {
      'pattern' => tr(context, 'Pattern', 'الگو'),
      'plain' => tr(context, 'Plain', 'ساده'),
      'ocean' => tr(context, 'Ocean', 'اقیانوس'),
      'sage' => tr(context, 'Sage', 'سبز'),
      'dusk' => tr(context, 'Dusk', 'غروب'),
      'sand' => tr(context, 'Sand', 'شن'),
      'aurora' => tr(context, 'Aurora', 'شفق قطبی'),
      'rose' => tr(context, 'Rose', 'رز'),
      'midnight' => tr(context, 'Midnight', 'نیمه‌شب'),
      'lavender' => tr(context, 'Lavender', 'اسطوخودوس'),
      'ice' => tr(context, 'Ice', 'یخ'),
      'ember' => tr(context, 'Ember', 'اخگر'),
      _ => tr(context, 'Forest', 'جنگل'),
    };
    return Semantics(
      button: true,
      selected: draft.style == style,
      child: InkWell(
        onTap: _busy
            ? null
            : () => setState(
                () => _draft = LoomWallpaper(
                  style: style,
                  dim: draft.dim,
                  parallax: draft.parallax,
                ),
              ),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: draft.style == style
                  ? context.loom.primary
                  : context.loom.borderStrong,
              width: draft.style == style ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: LoomWallpaperBackdrop(
              selection: LoomWallpaper(style: style, dim: 0),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: context.loom.surfaceElevated,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    return Scaffold(
      appBar: LoomGlassAppBar(
        title: Text(
          tr(
            context,
            widget.chatId == null
                ? 'Chat wallpaper'
                : 'Wallpaper for this chat',
            widget.chatId == null ? 'پس‌زمینهٔ گفتگوها' : 'پس‌زمینهٔ این گفتگو',
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.chatId != null)
                TextButton(
                  onPressed: _busy || draft == null
                      ? null
                      : () => _apply(reset: true),
                  child: Text(tr(context, 'Use default', 'استفاده از پیش‌فرض')),
                ),
              FilledButton(
                onPressed: _busy || draft == null ? null : () => _apply(),
                child: Text(tr(context, 'Apply wallpaper', 'اعمال پس‌زمینه')),
              ),
            ],
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: draft == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 230),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: LoomWallpaperBackdrop(
                          selection: draft,
                          child: const LoomAppearancePreviewMessages(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      tr(context, 'Choose a background', 'انتخاب پس‌زمینه'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    GridView.count(
                      crossAxisCount: 3,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 1.25,
                      children: [
                        for (final style in LoomWallpaper.styles.where(
                          (s) => s != 'photo',
                        ))
                          _preset(context, draft, style),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _photo,
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(LoomIcons.add_photo_alternate_outlined),
                      label: Text(tr(context, 'Your photo', 'عکس شما')),
                    ),
                    if (draft.style != 'plain' && draft.style != 'pattern') ...[
                      const SizedBox(height: 20),
                      Text(tr(context, 'Dim background', 'تیرگی پس‌زمینه')),
                      Slider(
                        value: draft.dim,
                        max: .8,
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                () => _draft = draft.copyWith(dim: v),
                              ),
                      ),
                    ],
                    if (draft.style == 'photo') ...[
                      Text(tr(context, 'Photo blur', 'تاری عکس')),
                      Slider(
                        value: draft.blur ? draft.blurAmount : 0,
                        max: 24,
                        divisions: 24,
                        label: '${(draft.blur ? draft.blurAmount : 0).round()}',
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                () => _draft = draft.copyWith(blurAmount: v),
                              ),
                      ),
                    ],
                    if (Platform.isAndroid)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          tr(context, 'Wallpaper depth', 'عمق پس‌زمینه'),
                        ),
                        subtitle: Text(
                          tr(
                            context,
                            'Gently follows your phone tilt. Requires a motion sensor; respects Reduce motion.',
                            'با کج شدن گوشی آرام حرکت می‌کند؛ نیازمند سنسور حرکت است و با کاهش حرکت خاموش می‌شود.',
                          ),
                        ),
                        value: draft.parallax,
                        onChanged: _busy
                            ? null
                            : (v) => setState(
                                () => _draft = draft.copyWith(parallax: v),
                              ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      tr(
                        context,
                        widget.chatId == null
                            ? 'Used in chats without a custom wallpaper. Photos stay on this device.'
                            : 'Only this chat changes. Photos stay on this device.',
                        widget.chatId == null
                            ? 'برای گفتگوهای بدون پس‌زمینهٔ اختصاصی اعمال می‌شود. عکس روی همین دستگاه می‌ماند.'
                            : 'فقط همین گفتگو تغییر می‌کند. عکس روی همین دستگاه می‌ماند.',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class LoomAppearancePreviewMessages extends StatelessWidget {
  const LoomAppearancePreviewMessages({super.key});
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LoomMessageBubble(
            text: tr(context, 'Looks good.', 'چه پس‌زمینهٔ خوبی!'),
            time: '12:40',
            mine: false,
          ),
          const SizedBox(height: 8),
          LoomMessageBubble(
            text: tr(context, 'Your style.', 'سلیقهٔ خودت!'),
            time: '12:41',
            mine: true,
            delivery: LoomDeliveryState.read,
          ),
        ],
      ),
    ),
  );
}
