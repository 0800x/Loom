import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:loom_design/loom_design.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/loom_strings.dart';

/// Opens Loom's local image editor and returns a new edited file on Save.
/// The selected source is never overwritten.
///
/// The editor follows the flat Telegram photo-editor language: a black
/// stage, circular tinted tool buttons on the bottom rail and one active
/// tool at a time (crop, adjust, rotate/flip).
Future<File?> showLoomImageEditor(
  BuildContext context, {
  required File source,
}) {
  return Navigator.of(context).push<File>(
    MaterialPageRoute<File>(
      fullscreenDialog: true,
      builder: (_) => _LoomImageEditor(source: source),
    ),
  );
}

enum _EditorTool { crop, adjust, transform }

class _LoomImageEditor extends StatefulWidget {
  const _LoomImageEditor({required this.source});

  final File source;

  @override
  State<_LoomImageEditor> createState() => _LoomImageEditorState();
}

class _LoomImageEditorState extends State<_LoomImageEditor> {
  img.Image? _image;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  _EditorTool _tool = _EditorTool.transform;

  // Crop state: rect in fitted-image display coordinates.
  Rect _crop = const Rect.fromLTWH(0, 0, 1, 1);
  double? _cropAspect;

  // Adjust state (applied live through a color matrix, baked at save).
  double _brightness = 0; // -1..1
  double _contrast = 0; // -1..1
  double _saturation = 0; // -1..1

  // Transform state baked into the decode preview via rotated/flipped copy.
  int _rotations = 0;
  bool _flip = false;
  bool _dirtyTransform = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final length = await widget.source.length();
      if (length <= 0 || length > 64 * 1024 * 1024) {
        throw const FormatException('Image size is not supported.');
      }
      final bytes = await widget.source.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw const FormatException('This image could not be decoded.');
      }
      final oriented = img.bakeOrientation(decoded);
      if (!mounted) return;
      setState(() {
        _image = oriented;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = tr(
          context,
          'Could not open this image.',
          'باز کردن این عکس ممکن نشد.',
        );
        _loading = false;
      });
    }
  }

  img.Image get _display {
    final base = _image!;
    if (!_dirtyTransform) return base;
    var current = base;
    if (_flip) current = img.flipHorizontal(current);
    for (var i = 0; i < _rotations % 4; i++) {
      current = img.copyRotate(current, angle: 90);
    }
    return current;
  }

  void _rotate() {
    if (_saving) return;
    setState(() {
      _rotations = (_rotations + 1) % 4;
      _dirtyTransform = true;
      _resetCrop();
    });
  }

  void _flipImage() {
    if (_saving) return;
    setState(() {
      _flip = !_flip;
      _dirtyTransform = true;
      _resetCrop();
    });
  }

  void _resetCrop() {
    _crop = const Rect.fromLTWH(0, 0, 1, 1);
    _cropAspect = null;
  }

  /// 4x5 color matrix combining brightness/contrast/saturation for the live
  /// preview; identical factors are baked into the exported file.
  ui.ColorFilter get _adjustFilter {
    final b = _brightness * 60;
    final c = 1 + _contrast;
    final s = 1 + _saturation;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    return ui.ColorFilter.matrix(<double>[
      c * (lr + (1 - lr) * s), c * (lg - lg * s), c * (lb - lb * s), 0, b, //
      c * (lr - lr * s), c * (lg + (1 - lg) * s), c * (lb - lb * s), 0, b, //
      c * (lr - lr * s), c * (lg - lg * s), c * (lb + (1 - lb) * s), 0, b, //
      0, 0, 0, 1, 0,
    ]);
  }

  bool get _adjustNeutral =>
      _brightness == 0 && _contrast == 0 && _saturation == 0;

  Future<void> _save() async {
    final base = _image;
    if (base == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      var current = _display;
      // Crop: display rect (0..1 of the transformed image) → pixels.
      if (_crop.left > 0 ||
          _crop.top > 0 ||
          _crop.right < 1 ||
          _crop.bottom < 1) {
        final x = (_crop.left * current.width).floor().clamp(0, current.width - 1);
        final y = (_crop.top * current.height).floor().clamp(0, current.height - 1);
        final w = (_crop.width * current.width)
            .ceil()
            .clamp(1, current.width - x);
        final h = (_crop.height * current.height)
            .ceil()
            .clamp(1, current.height - y);
        current = img.copyCrop(current, x: x, y: y, width: w, height: h);
      }
      if (!_adjustNeutral) {
        current = img.adjustColor(
          current,
          brightness: _brightness.clamp(-1, 1),
          contrast: _contrast.clamp(-1, 1),
          saturation: _saturation.clamp(-1, 1),
        );
      }
      final bytes = img.encodePng(current);
      final temporary = await getTemporaryDirectory();
      final output = File(
        '${temporary.path}/loom-edited-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await output.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      Navigator.of(context).pop(output);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = tr(
          context,
          'Could not save the edited image.',
          'ذخیرهٔ عکس ویرایش‌شده ممکن نشد.',
        );
      });
    }
  }

  void _setCrop(Rect rect, {double? aspect}) {
    final bounds = _cropBounds;
    var next = rect;
    if (aspect != null) {
      // Fit the requested aspect inside the bounds, centred on the gesture
      // centre when possible.
      final maxW = bounds.width, maxH = bounds.height;
      var w = maxW, h = w / aspect;
      if (h > maxH) {
        h = maxH;
        w = h * aspect;
      }
      final centre = next.center;
      var left = centre.dx - w / 2, top = centre.dy - h / 2;
      left = left.clamp(bounds.left, bounds.right - w);
      top = top.clamp(bounds.top, bounds.bottom - h);
      next = Rect.fromLTWH(left, top, w, h);
    } else {
      next = Rect.fromLTWH(
        next.left.clamp(bounds.left, bounds.right - 48),
        next.top.clamp(bounds.top, bounds.bottom - 48),
        math.max(48, math.min(next.width, bounds.width)),
        math.max(48, math.min(next.height, bounds.height)),
      );
      next = next.translate(
        (bounds.left - next.left).clamp(0, double.infinity) +
            (bounds.right - next.right).clamp(double.negativeInfinity, 0),
        (bounds.top - next.top).clamp(0, double.infinity) +
            (bounds.bottom - next.bottom).clamp(double.negativeInfinity, 0),
      );
    }
    _crop = next;
  }

  Rect get _cropBounds {
    final tool = _tool;
    if (tool != _EditorTool.crop) return Rect.zero;
    return Rect.fromLTWH(0, 0, _cropAreaWidth, _cropAreaHeight);
  }

  double get _cropAreaWidth => _displayKey.currentState?.displaySize.width ?? 1;
  double get _cropAreaHeight =>
      _displayKey.currentState?.displaySize.height ?? 1;

  final _displayKey = GlobalKey<_EditorImageState>();

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          switch (_tool) {
            _EditorTool.crop => tr(context, 'Crop', 'برش'),
            _EditorTool.adjust => tr(context, 'Adjust', 'تنظیمات'),
            _EditorTool.transform => tr(context, 'Edit image', 'ویرایش عکس'),
          },
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        leading: IconButton(
          tooltip: tr(context, 'Cancel', 'انصراف'),
          onPressed: _saving ? null : () => Navigator.maybePop(context),
          icon: const Icon(LoomIcons.close),
        ),
        actions: [
          if (_tool == _EditorTool.adjust && !_adjustNeutral)
            TextButton(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      _brightness = 0;
                      _contrast = 0;
                      _saturation = 0;
                    }),
              child: Text(
                tr(context, 'Reset', 'بازنشانی'),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          IconButton(
            tooltip: tr(context, 'Save', 'ذخیره'),
            onPressed: image == null || _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LoomIcons.check_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : image == null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error ?? tr(context, 'Image unavailable', 'عکس موجود نیست'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      )
                    : _EditorImage(
                        key: _displayKey,
                        image: _display,
                        tool: _tool,
                        crop: _crop,
                        aspect: _cropAspect,
                        filter: _tool == _EditorTool.adjust && !_adjustNeutral
                            ? _adjustFilter
                            : null,
                        onCropChanged: (rect) => setState(() => _setCrop(rect)),
                      ),
              ),
            ),
            if (_error != null && image != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.loom.critical),
                ),
              ),
            _buildToolRail(p),
            _buildToolPanel(p),
          ],
        ),
      ),
    );
  }

  Widget _buildToolRail(LoomPalette p) {
    Widget railButton(IconData icon, String label, bool active, VoidCallback tap) {
      return InkWell(
        onTap: _saving ? null : tap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: active ? p.primary : Colors.white),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: active ? p.primary : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          railButton(
            LoomIcons.crop_rounded,
            tr(context, 'Crop', 'برش'),
            _tool == _EditorTool.crop,
            () => setState(() {
              _tool = _EditorTool.crop;
              if (_cropAspect != null) _setCrop(_crop, aspect: _cropAspect);
            }),
          ),
          railButton(
            LoomIcons.tune_rounded,
            tr(context, 'Adjust', 'تنظیمات'),
            _tool == _EditorTool.adjust,
            () => setState(() => _tool = _EditorTool.adjust),
          ),
          railButton(
            LoomIcons.rotate_right_rounded,
            tr(context, 'Rotate', 'چرخش'),
            false,
            _rotate,
          ),
          railButton(
            LoomIcons.flip_rounded,
            tr(context, 'Flip', 'آینه'),
            false,
            _flipImage,
          ),
        ],
      ),
    );
  }

  Widget _buildToolPanel(LoomPalette p) {
    if (_tool == _EditorTool.crop) {
      const presets = <(String?, double?)>[
        (null, null), // free
        ('1:1', 1),
        ('4:3', 4 / 3),
        ('3:4', 3 / 4),
        ('16:9', 16 / 9),
      ];
      return SizedBox(
        height: 64,
        child: Center(
          child: ListView.separated(
            shrinkWrap: true,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            itemCount: presets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final (label, aspect) = presets[index];
              final active = _cropAspect == aspect;
              return Material(
                color: active
                    ? p.primary
                    : Colors.white.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => setState(() {
                    _cropAspect = aspect;
                    if (aspect != null) _setCrop(_crop, aspect: aspect);
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Center(
                      child: Text(
                        label ?? tr(context, 'Free', 'آزاد'),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: active ? Colors.white : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    }
    if (_tool == _EditorTool.adjust) {
      Widget slider(String label, double value, ValueChanged<double> on) {
        return Row(
          children: [
            SizedBox(
              width: 86,
              child: Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: Slider(
                  value: value,
                  min: -1,
                  max: 1,
                  onChanged: _saving ? null : on,
                ),
              ),
            ),
          ],
        );
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          children: [
            slider(
              tr(context, 'Brightness', 'روشنایی'),
              _brightness,
              (v) => setState(() => _brightness = v),
            ),
            slider(
              tr(context, 'Contrast', 'کنتراست'),
              _contrast,
              (v) => setState(() => _contrast = v),
            ),
            slider(
              tr(context, 'Saturation', 'اشباع رنگ'),
              _saturation,
              (v) => setState(() => _saturation = v),
            ),
          ],
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}

/// The fitted image plus the crop overlay gesture layer.
class _EditorImage extends StatefulWidget {
  const _EditorImage({
    required this.image,
    required this.tool,
    required this.crop,
    required this.aspect,
    required this.filter,
    required this.onCropChanged,
    super.key,
  });

  final img.Image image;
  final _EditorTool tool;
  final Rect crop;
  final double? aspect;
  final ui.ColorFilter? filter;
  final ValueChanged<Rect> onCropChanged;

  @override
  State<_EditorImage> createState() => _EditorImageState();
}

class _EditorImageState extends State<_EditorImage> {
  Size get displaySize => _fitted ?? Size.zero;
  Size? _fitted;
  Uint8List? _bytes;

  @override
  void didUpdateWidget(covariant _EditorImage old) {
    super.didUpdateWidget(old);
    if (!identical(old.image, widget.image)) {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes ??= img.encodePng(widget.image);
    return LayoutBuilder(
      builder: (context, bounds) {
        final fitted = fitWithin(
          Size(widget.image.width.toDouble(), widget.image.height.toDouble()),
          bounds.maxWidth,
          bounds.maxHeight,
        );
        _fitted = fitted;
        Widget image = Image.memory(
          bytes,
          width: fitted.width,
          height: fitted.height,
          fit: BoxFit.fill,
          gaplessPlayback: true,
        );
        if (widget.filter != null) {
          image = ColorFiltered(colorFilter: widget.filter!, child: image);
        }
        final stack = Stack(
          alignment: Alignment.center,
          children: [
            image,
            if (widget.tool == _EditorTool.crop)
              Positioned.fill(
                child: _CropLayer(
                  areaSize: fitted,
                  crop: widget.crop,
                  aspect: widget.aspect,
                  onChanged: widget.onCropChanged,
                ),
              ),
          ],
        );
        return SizedBox(
          width: fitted.width,
          height: fitted.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              widget.tool == _EditorTool.crop ? 0 : 8,
            ),
            child: stack,
          ),
        );
      },
    );
  }

  Size fitWithin(Size source, double maxW, double maxH) {
    final scale = math.min(maxW / source.width, maxH / source.height);
    return Size(source.width * scale, source.height * scale);
  }
}

/// Draggable crop rectangle with corner handles and dimmed outside area.
class _CropLayer extends StatelessWidget {
  const _CropLayer({
    required this.areaSize,
    required this.crop,
    required this.aspect,
    required this.onChanged,
  });

  final Size areaSize;
  final Rect crop;
  final double? aspect;
  final ValueChanged<Rect> onChanged;

  @override
  Widget build(BuildContext context) {
    final bounds = Rect.fromLTWH(0, 0, areaSize.width, areaSize.height);
    Widget layer = LayoutBuilder(
      builder: (context, _) => CustomPaint(
        painter: _CropMaskPainter(rect: crop, color: Colors.black54),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanUpdate: (details) {
            var next = crop.shift(details.delta);
            final left = next.left.clamp(bounds.left, bounds.right - next.width);
            final top = next.top.clamp(bounds.top, bounds.bottom - next.height);
            next = Rect.fromLTWH(left, top, next.width, next.height);
            onChanged(next);
          },
          onDoubleTap: () => onChanged(bounds),
          child: Container(color: Colors.transparent),
        ),
      ),
    );
    // Corner + edge handles drag with aspect awareness handled by the state.
    for (final handle in _CropHandlePosition.values) {
      layer = Stack(
        fit: StackFit.expand,
        children: [
          layer,
          Align(
            alignment: switch (handle) {
              _CropHandlePosition.topLeft => Alignment.topLeft,
              _CropHandlePosition.topRight => Alignment.topRight,
              _CropHandlePosition.bottomLeft => Alignment.bottomLeft,
              _CropHandlePosition.bottomRight => Alignment.bottomRight,
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (details) =>
                  _drag(handle, details.delta, bounds),
              child: Container(
                width: 56,
                height: 56,
                margin: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.transparent,
                ),
                alignment: switch (handle) {
                  _CropHandlePosition.topLeft => Alignment.topLeft,
                  _CropHandlePosition.topRight => Alignment.topRight,
                  _CropHandlePosition.bottomLeft => Alignment.bottomLeft,
                  _CropHandlePosition.bottomRight => Alignment.bottomRight,
                },
                // Corner bracket drawn as a box outline; the app's icon
                // contract is Amicons-only through LoomIcons.
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return layer;
  }

  void _drag(
    _CropHandlePosition handle,
    Offset delta,
    Rect bounds,
  ) {
    Rect next = switch (handle) {
      _CropHandlePosition.topLeft => Rect.fromLTRB(
        crop.left + delta.dx,
        crop.top + delta.dy,
        crop.right,
        crop.bottom,
      ),
      _CropHandlePosition.topRight => Rect.fromLTRB(
        crop.left,
        crop.top + delta.dy,
        crop.right + delta.dx,
        crop.bottom,
      ),
      _CropHandlePosition.bottomLeft => Rect.fromLTRB(
        crop.left + delta.dx,
        crop.top,
        crop.right,
        crop.bottom + delta.dy,
      ),
      _CropHandlePosition.bottomRight => Rect.fromLTRB(
        crop.left,
        crop.top,
        crop.right + delta.dx,
        crop.bottom + delta.dy,
      ),
    };
    // Enforce a minimum size and containment before handing over.
    if (next.width < 48) {
      next = next.width <= 0
          ? Rect.fromCenter(center: next.center, width: 48, height: next.height)
          : Rect.fromLTRB(next.left, next.top, next.left + 48, next.bottom);
    }
    if (next.height < 48) {
      next = Rect.fromLTRB(next.left, next.top, next.right, next.top + 48);
    }
    if (next.width > bounds.width) {
      next = Rect.fromLTRB(next.left, next.top, bounds.right, next.bottom);
    }
    if (next.height > bounds.height) {
      next = Rect.fromLTRB(next.left, next.top, next.right, bounds.bottom);
    }
    if (aspect != null) {
      // Keep the requested aspect by adjusting height around the anchor edge.
      final anchored = next.height / next.width;
      if ((anchored - aspect!).abs() > 0.001) {
        final targetHeight = next.width * aspect!;
        if (targetHeight <= bounds.height) {
          next = switch (handle) {
            _CropHandlePosition.topLeft ||
            _CropHandlePosition.topRight => Rect.fromLTRB(
              next.left,
              next.bottom - targetHeight,
              next.right,
              next.bottom,
            ),
            _ => Rect.fromLTRB(next.left, next.top, next.right, next.top + targetHeight),
          };
        } else {
          final targetWidth = next.height / aspect!;
          next = switch (handle) {
            _CropHandlePosition.topLeft ||
            _CropHandlePosition.bottomLeft => Rect.fromLTRB(
              next.right - targetWidth,
              next.top,
              next.right,
              next.bottom,
            ),
            _ => Rect.fromLTRB(next.left, next.top, next.left + targetWidth, next.bottom),
          };
        }
      }
    }
    // Keep inside bounds.
    final left = next.left.clamp(bounds.left, bounds.right - next.width);
    final top = next.top.clamp(bounds.top, bounds.bottom - next.height);
    next = Rect.fromLTWH(left, top, next.width, next.height);
    onChanged(next);
  }
}

enum _CropHandlePosition { topLeft, topRight, bottomLeft, bottomRight }

class _CropMaskPainter extends CustomPainter {
  _CropMaskPainter({required this.rect, required this.color});

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final inner = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      );
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      Paint()..color = color,
    );
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      stroke,
    );
    // Rule-of-thirds grid inside the crop rect.
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: .28)
      ..strokeWidth = .7;
    for (var i = 1; i < 3; i++) {
      final x = rect.left + rect.width * i / 3;
      final y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }
  }

  @override
  bool shouldRepaint(_CropMaskPainter old) => old.rect != rect;
}
