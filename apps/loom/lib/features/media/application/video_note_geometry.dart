import 'dart:math' as math;
import 'package:flutter/services.dart';

/// Upright display-space crop; the native encoder applies the same centered
/// cover crop after reading the source rotation metadata.
class LoomVideoNoteGeometry {
  static const aspectRatio = 4 / 3;
  static Size circularPreviewSize(Size available) {
    final diameter = math.max(1.0, math.min(320.0, available.shortestSide));
    return Size.square(diameter);
  }

  static Size previewSize(Size available) {
    final width = math.max(
      1.0,
      math.min(
        440.0,
        math.min(available.width, available.height * aspectRatio),
      ),
    );
    return Size(width, width / aspectRatio);
  }

  static Rect centerCrop(Size source) {
    final width = math.min(source.width, source.height * aspectRatio);
    final height = width / aspectRatio;
    return Rect.fromCenter(
      center: Offset(source.width / 2, source.height / 2),
      width: width,
      height: height,
    );
  }
}

Future<String> normalizeLoomVideoNote(String path, String output) async {
  final result = await const MethodChannel('video_compress')
      .invokeMapMethod<String, dynamic>('normalizeVideoNote', {
        'path': path,
        'output': output,
      });
  if (result?['path'] != output ||
      result?['width'] != 640 ||
      result?['height'] != 480 ||
      result?['rotation'] != 0) {
    throw StateError('video_note_geometry_invalid');
  }
  return output;
}
