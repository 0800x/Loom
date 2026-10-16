import 'package:loom_models/loom_models.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../../profile/application/avatar_photo.dart';

/// Strip metadata, center-crop, and limit both pixels and MLS plaintext size.
Future<Uint8List> normalizeGroupPhoto(Uint8List source) async {
  final normalized = await normalizeAvatarPhoto(source);
  try {
    return await compute(_compactPhoto, normalized);
  } finally {
    normalized.fillRange(0, normalized.length, 0);
  }
}

Uint8List _compactPhoto(Uint8List png) {
  final decoded = img.decodePng(png);
  if (decoded == null) throw const FormatException('Invalid group image');
  final resized = img.copyResize(
    decoded,
    width: LoomGroupProfile.maxDimension,
    height: LoomGroupProfile.maxDimension,
    interpolation: img.Interpolation.average,
  );
  final compact = img.quantize(resized, numberOfColors: 64);
  final result = img.encodePng(compact);
  LoomGroupProfile.validatePng(result);
  return result;
}
