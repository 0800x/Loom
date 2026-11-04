import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:loom_design/loom_design.dart';
import 'package:path_provider/path_provider.dart';

/// Opens Loom's local image editor and returns a new edited file on Save.
/// The selected source is never overwritten.
Future<File?> showLoomImageEditor(
  BuildContext context, {
  required File source,
}) {
  return Navigator.of(context).push<File>(
    MaterialPageRoute<File>(
      builder: (_) => _LoomImageEditor(source: source),
    ),
  );
}

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
        _error = 'Could not open this image.';
        _loading = false;
      });
    }
  }

  void _rotate() {
    final current = _image;
    if (current == null || _saving) return;
    setState(() => _image = img.copyRotate(current, angle: 90));
  }

  void _flip() {
    final current = _image;
    if (current == null || _saving) return;
    setState(() => _image = img.flipHorizontal(current));
  }

  Future<void> _save() async {
    final current = _image;
    if (current == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
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
        _error = 'Could not save the edited image.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit image'),
        leading: IconButton(
          tooltip: 'Cancel editing',
          onPressed: _saving ? null : () => Navigator.maybePop(context),
          icon: const Icon(LoomIcons.close),
        ),
        actions: [
          TextButton.icon(
            onPressed: image == null || _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LoomIcons.check),
            label: const Text('Save'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : image == null
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(_error ?? 'Image unavailable'),
                          )
                        : InteractiveViewer(
                            minScale: .5,
                            maxScale: 5,
                            child: Image.memory(
                              img.encodePng(image),
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          ),
              ),
            ),
            if (_error != null && image != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: image == null || _saving ? null : _rotate,
                    icon: const Icon(LoomIcons.rotate_right_rounded),
                    label: const Text('Rotate'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: image == null || _saving ? null : _flip,
                    icon: const Icon(LoomIcons.flip_rounded),
                    label: const Text('Flip'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
