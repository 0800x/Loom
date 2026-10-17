import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';

bool _isGif(Uint8List bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 71 &&
    bytes[1] == 73 &&
    bytes[2] == 70 &&
    bytes[3] == 56 &&
    (bytes[4] == 55 || bytes[4] == 57) &&
    bytes[5] == 97;

bool _isWebP(Uint8List bytes) =>
    bytes.length >= 12 &&
    String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
    String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';

class LoomPreparedMedia {
  const LoomPreparedMedia(this.file, {this.owned = false});
  final File file;
  final bool owned;
  Future<void> dispose() async {
    if (owned) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

Uint8List _encodePhoto(({Uint8List bytes, int width, int height}) data) =>
    image.encodeJpg(
      image.Image.fromBytes(
        width: data.width,
        height: data.height,
        bytes: data.bytes.buffer,
        bytesOffset: data.bytes.offsetInBytes,
        numChannels: 4,
        order: image.ChannelOrder.rgba,
      ),
      quality: 82,
    );

/// Compression precedes encryption. Never replace or delete the user's source.
class LoomMediaPreparation {
  static Future<bool> keyboardSticker(File source, String mime) async {
    if (mime == 'image/webp') return true;
    if (mime != 'image/png' || await source.length() > 4 * 1024 * 1024) {
      return false;
    }
    final bytes = await source.readAsBytes();
    ui.Codec? codec;
    ui.Image? frame;
    try {
      final info = await dimensions(source, 'image');
      if ((info['width'] as int) * (info['height'] as int) > 2 * 1024 * 1024) {
        return false;
      }
      codec = await ui.instantiateImageCodec(bytes);
      frame = (await codec.getNextFrame()).image;
      final pixels = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (pixels == null) return false;
      for (var i = 3; i < pixels.lengthInBytes; i += 4) {
        if (pixels.getUint8(i) < 250) return true;
      }
      return false;
    } finally {
      frame?.dispose();
      codec?.dispose();
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Future<Map<String, Object?>> dimensions(
    File source,
    String kind,
  ) async {
    if (kind == 'audio') return const {};
    if (kind == 'video' || kind == 'video_note') {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        final info = await VideoCompress.getMediaInfo(source.path);
        return {
          if (info.width != null && info.width! > 0) 'width': info.width,
          if (info.height != null && info.height! > 0) 'height': info.height,
          if (info.duration != null && info.duration! > 0)
            'durationMs': info.duration!.round(),
        };
      }
      return const {};
    }
    final bytes = await source.readAsBytes();
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 60 * 1000 * 1000) {
        throw const FormatException('Image exceeds 60 megapixels');
      }
      return {
        'width': descriptor.width,
        'height': descriptor.height,
        if (_isGif(bytes)) 'animated': true,
        if (_isGif(bytes)) 'mime': 'image/gif',
        if (_isWebP(bytes)) 'mime': 'image/webp',
      };
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Future<void> clearStaleNativeCache() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      await VideoCompress.deleteAllCache();
    }
  }

  static Future<LoomPreparedMedia> prepare(
    File source,
    String kind, {
    bool sticker = false,
    Future<Directory> Function()? temporaryDirectory,
  }) async {
    final length = await source.length();
    if (length <= 0 || length > 256 * 1024 * 1024) {
      throw const FormatException('Media source exceeds processing limit');
    }
    if (kind == 'audio') {
      return LoomPreparedMedia(source);
    }
    if (kind == 'video' || kind == 'video_note') {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        final info = await VideoCompress.compressVideo(
          source.path,
          quality: VideoQuality.MediumQuality,
          deleteOrigin: false,
          includeAudio: true,
          frameRate: 24,
        );
        final file = info?.file;
        if (file == null || info?.isCancel == true) {
          throw StateError('Video compression failed');
        }
        if ((await file.length() < length || kind == 'video_note') &&
            file.path != source.path) {
          final temp = await (temporaryDirectory ?? getTemporaryDirectory)();
          final root = await Directory(
            '${temp.path}/loom_media_prepare',
          ).create(recursive: true);
          final folder = await root.createTemp('video_');
          try {
            final copy = await file.copy('${folder.path}/video.mp4');
            return LoomPreparedMedia(copy, owned: true);
          } catch (_) {
            await folder.delete(recursive: true);
            rethrow;
          } finally {
            try {
              await file.delete();
            } catch (_) {}
          }
        }
        if (file.path != source.path) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }
      return LoomPreparedMedia(source);
    }
    final bytes = await source.readAsBytes();
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? frame;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 60 * 1000 * 1000) {
        throw const FormatException('Photo exceeds 60 megapixels');
      }
      if (_isGif(bytes) || sticker || _isWebP(bytes)) {
        if (length > 128 * 1024 * 1024) {
          throw const FormatException(
            'Image exceeds 128 MiB processing ceiling',
          );
        }
        // Keep the complete container: decoding/re-encoding a single frame
        // destroys animation. The descriptor above validates the image.
        return LoomPreparedMedia(source);
      }
      final scale = math.min(
        1.0,
        1920 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      frame = (await codec.getNextFrame()).image;
      final rgba = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) {
        throw StateError('Photo could not be decoded');
      }
      final jpeg = await compute(_encodePhoto, (
        bytes: rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
        width: frame.width,
        height: frame.height,
      ));
      final temp = await (temporaryDirectory ?? getTemporaryDirectory)();
      final folder = await Directory(
        '${temp.path}/loom_media_prepare',
      ).create(recursive: true);
      final unique = await folder.createTemp('photo_');
      final file = File('${unique.path}/photo.jpg');
      try {
        await file.writeAsBytes(jpeg, flush: true);
      } catch (_) {
        await unique.delete(recursive: true);
        rethrow;
      } finally {
        jpeg.fillRange(0, jpeg.length, 0);
      }
      return LoomPreparedMedia(file, owned: true);
    } finally {
      frame?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      bytes.fillRange(0, bytes.length, 0);
    }
  }
}
