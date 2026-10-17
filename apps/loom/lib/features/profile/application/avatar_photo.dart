import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Normalize a selected photo to a small, metadata-free square PNG.
Future<Uint8List> normalizeAvatarPhoto(Uint8List bytes) async {
  if (bytes.length > 8 * 1024 * 1024) {
    throw const AvatarPhotoTooLarge();
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? decoded;
  ui.Image? square;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width * descriptor.height > 40 * 1000 * 1000) {
      throw const AvatarPhotoTooLarge();
    }
    final scale = math.min(
      1.0,
      1024 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    decoded = (await codec.getNextFrame()).image;
    final side = math.min(decoded.width, decoded.height).toDouble();
    final outputSize = math.min(256, side.toInt());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      decoded,
      ui.Rect.fromLTWH(
        (decoded.width - side) / 2,
        (decoded.height - side) / 2,
        side,
        side,
      ),
      ui.Rect.fromLTWH(0, 0, outputSize.toDouble(), outputSize.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      square = await picture.toImage(outputSize, outputSize);
    } finally {
      picture.dispose();
    }
    final data = await square.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('Cannot encode avatar');
    }
    return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    square?.dispose();
    decoded?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

class AvatarPhotoTooLarge implements Exception {
  const AvatarPhotoTooLarge();
}
