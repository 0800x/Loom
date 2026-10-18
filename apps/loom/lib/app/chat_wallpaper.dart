import 'dart:async';

import 'wallpaper_parallax.dart';
import 'wallpaper_preferences.dart';
export 'wallpaper_preferences.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../features/messaging/application/media_preparation.dart';

/// Owns copied wallpaper assets; never persists raw chat IDs or source paths.
class LoomWallpaperStore extends ChangeNotifier {
  LoomWallpaperStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  static final instance = LoomWallpaperStore();
  final Future<Directory> Function() _directory;
  final _values = <String, LoomWallpaper>{};
  Directory? root;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  LoomWallpaper selection(String? key) =>
      _values[key ?? 'default'] ?? _values['default'] ?? const LoomWallpaper();
  bool hasOverride(String key) => _values.containsKey(key);
  static final Map<String, String> _chatKeys = {};
  static final Map<String, Future<String?>> _pendingKeys = {};
  static String? cachedChatKey(String? raw) => _chatKeys[raw];
  static Future<String?> chatKey(String? raw) {
    if (raw == null) return Future.value(null);
    final cached = _chatKeys[raw];
    if (cached != null) return Future.value(cached);
    return _pendingKeys.putIfAbsent(raw, () {
      final result = Sha256().hash(utf8.encode(raw)).then<String?>((hash) {
        final key = hash.bytes
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join();
        if (_chatKeys.length >= 128) _chatKeys.remove(_chatKeys.keys.first);
        _chatKeys[raw] = key;
        return key;
      });
      unawaited(
        result.then<void>((_) {
          _pendingKeys.remove(raw);
        }),
      );
      return result;
    });
  }

  ImageProvider<Object>? photoProvider(LoomWallpaper value) {
    final file = imageFile(value);
    return file == null ? null : ResizeImage(FileImage(file), width: 1080);
  }

  // Warm the global photo as soon as preferences load, before opening a chat.
  void _warmDefaultPhoto() {
    final provider = photoProvider(selection(null));
    if (provider == null) return;
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, _) {
        image.dispose();
        stream.removeListener(listener);
      },
      onError: (Object _, StackTrace? _) {
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
  }

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      root = await Directory(
        '${(await _directory()).path}/loom-wallpapers',
      ).create(recursive: true);
      final json = jsonDecode(
        await File('${root!.path}/preferences.json').readAsString(),
      );
      if (json is Map<String, dynamic>) {
        for (final entry in json.entries) {
          if ((entry.key == 'default' ||
                  RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key)) &&
              entry.value is Map<String, dynamic>) {
            try {
              _values[entry.key] = LoomWallpaper.fromJson(
                entry.value as Map<String, dynamic>,
              );
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      /* missing preferences retain defaults */
    }
    _warmDefaultPhoto();
    notifyListeners();
  }

  Future<void> set(String? key, LoomWallpaper? value) async {
    await load();
    if (key != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const FormatException('Invalid chat key');
    }
    final previous = _values[key ?? 'default'];
    if (value == null) {
      _values.remove(key ?? 'default');
    } else {
      _values[key ?? 'default'] = value;
    }
    notifyListeners();
    final data = jsonEncode(
      _values.map((key, value) => MapEntry(key, value.toJson())),
    );
    final write = _writes.catchError((Object _) {}).then((_) async {
      if (root == null) {
        throw const FileSystemException('Wallpaper storage unavailable');
      }
      final file = File('${root!.path}/preferences.json');
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    });
    _writes = write;
    await write;
    if (previous != null) await discardPhoto(previous);
  }

  File? imageFile(LoomWallpaper value) => value.image == null || root == null
      ? null
      : File('${root!.path}/${value.image}');
  Future<LoomWallpaper> importPhoto(File source) async {
    await load();
    if (root == null || await source.length() > 16 * 1024 * 1024) {
      throw const FormatException('Wallpaper must be smaller than 16 MiB');
    }
    final dimensions = await LoomMediaPreparation.dimensions(source, 'image');
    if ((dimensions['width'] as int) * (dimensions['height'] as int) >
        20 * 1000 * 1000) {
      throw const FormatException('Wallpaper exceeds 20 megapixels');
    }
    final prepared = await LoomMediaPreparation.prepare(source, 'image');
    final name = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    try {
      await prepared.file.copy('${root!.path}/$name.jpg');
      return LoomWallpaper(style: 'photo', image: '$name.jpg');
    } finally {
      await prepared.dispose();
    }
  }

  Future<void> discardPhoto(LoomWallpaper value) async {
    if (value.image == null ||
        _values.values.any((w) => w.image == value.image)) {
      return;
    }
    try {
      await imageFile(value)?.delete();
    } catch (_) {}
  }
}

class LoomWallpaperBackdrop extends StatefulWidget {
  const LoomWallpaperBackdrop({
    required this.child,
    this.chatId,
    this.selection,
    super.key,
  });
  final Widget child;
  final String? chatId;
  final LoomWallpaper? selection;
  @override
  State<LoomWallpaperBackdrop> createState() => _WallpaperBackdropState();
}

class _WallpaperBackdropState extends State<LoomWallpaperBackdrop> {
  String? _key;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    _key = LoomWallpaperStore.cachedChatKey(widget.chatId);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LoomWallpaperBackdrop old) {
    super.didUpdateWidget(old);
    if (old.chatId != widget.chatId) {
      _key = LoomWallpaperStore.cachedChatKey(widget.chatId);
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    final key = await LoomWallpaperStore.chatKey(widget.chatId);
    await LoomWallpaperStore.instance.load();
    if (!mounted || epoch != _epoch) return;
    final provider = LoomWallpaperStore.instance.photoProvider(
      widget.selection ?? LoomWallpaperStore.instance.selection(key),
    );
    if (provider != null) unawaited(precacheImage(provider, context));
    if (_key != key) setState(() => _key = key);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: LoomWallpaperStore.instance,
    child: widget.child,
    builder: (context, child) {
      final wallpaper =
          widget.selection ?? LoomWallpaperStore.instance.selection(_key);
      final dark = Theme.of(context).brightness == Brightness.dark;
      final accessible = LoomAccessibility.fromContext(context).highContrast;
      final palettes = <String, List<Color>>{
        'ocean': dark
            ? [const Color(0xff102c37), const Color(0xff162237)]
            : [const Color(0xffd6eef1), const Color(0xffe5e8fa)],
        'sage': dark
            ? [const Color(0xff1b3024), const Color(0xff142a2b)]
            : [const Color(0xffdeebd9), const Color(0xffcfe4de)],
        'dusk': dark
            ? [const Color(0xff322237), const Color(0xff1d233e)]
            : [const Color(0xfff1dfe6), const Color(0xffdddff1)],
      };
      for (final entry in <String, List<int>>{
        'sand': [0xffecdac0, 0xffcbb49b, 0xff332c25, 0xff211e1a],
        'aurora': [0xffa8e7db, 0xffc6b7eb, 0xff133d38, 0xff31224e],
        'rose': [0xfff4d0d8, 0xffead5bd, 0xff432631, 0xff302724],
        'midnight': [0xffc2d3eb, 0xffaab5d5, 0xff15233d, 0xff0c1224],
        'lavender': [0xffe4dbf7, 0xffd3cce8, 0xff302a43, 0xff242038],
        'ice': [0xffd6edf8, 0xffe5f3ef, 0xff17323e, 0xff142929],
        'ember': [0xfff0c7a4, 0xffedbbbd, 0xff412a21, 0xff352029],
        'forest': [0xffc4dccb, 0xffd8dec0, 0xff163127, 0xff242c1b],
      }.entries) {
        palettes[entry.key] = entry.value
            .skip(dark ? 2 : 0)
            .take(2)
            .map(Color.new)
            .toList();
      }
      final file = LoomWallpaperStore.instance.imageFile(wallpaper);
      Widget background = ColoredBox(color: context.loom.background);
      if (!accessible) {
        if (wallpaper.style == 'pattern') {
          background = const LoomChatBackdrop(child: SizedBox.expand());
        }
        if (palettes.containsKey(wallpaper.style)) {
          background = DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: palettes[wallpaper.style]!,
              ),
            ),
          );
        }
        if (wallpaper.style == 'photo' && file != null) {
          background = Image(
            image: LoomWallpaperStore.instance.photoProvider(wallpaper)!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                ColoredBox(color: context.loom.background),
          );
          if (wallpaper.blur) {
            background = ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: wallpaper.blurAmount,
                sigmaY: wallpaper.blurAmount,
              ),
              child: background,
            );
          }
        }
        if (wallpaper.style != 'pattern' && wallpaper.style != 'plain') {
          background = Stack(
            fit: StackFit.expand,
            children: [
              background,
              ColoredBox(color: Colors.black.withValues(alpha: wallpaper.dim)),
            ],
          );
        }
      }
      return Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: LoomWallpaperParallax(
                enabled: wallpaper.parallax && !accessible,
                child: background,
              ),
            ),
          ),
          child!,
        ],
      );
    },
  );
}
