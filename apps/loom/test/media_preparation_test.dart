import 'dart:io';

import 'package:loom_next/features/messaging/application/media_preparation.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'photo preparation preserves aspect ratio, color and the original file',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'loom_photo_test_',
      );
      try {
        final input = image.fill(
          image.Image(width: 3000, height: 1500),
          color: image.ColorRgb8(20, 100, 200),
        );
        final original = image.encodePng(input);
        final source = await File('${folder.path}/source.png')
            .writeAsBytes(original);
        final prepared = await LoomMediaPreparation.prepare(
          source,
          'image',
          temporaryDirectory: () async => folder,
        );
        final result = image.decodeJpg(await prepared.file.readAsBytes())!;
        expect(result.width, 1920);
        expect(result.height, 960);
        expect(result.getPixel(960, 480).b, closeTo(200, 10));
        expect(await source.readAsBytes(), original);
        final output = prepared.file;
        await prepared.dispose();
        expect(await output.exists(), isFalse);
        expect(await source.exists(), isTrue);
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'oversized source is rejected before decoding and remains intact',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'loom_limit_test_',
      );
      try {
        final source = File('${folder.path}/large.png');
        final handle = await source.open(mode: FileMode.write);
        await handle.truncate(256 * 1024 * 1024 + 1);
        await handle.close();
        await expectLater(
          LoomMediaPreparation.prepare(source, 'image'),
          throwsFormatException,
        );
        expect(await source.exists(), isTrue);
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );
  test('animated GIF retains every frame and original bytes regardless of extension', () async {
    final folder = await Directory.systemTemp.createTemp('loom_gif_test_');
    try {
      final encoder = image.GifEncoder();
      encoder.addFrame(
        image.fill(
          image.Image(width: 8, height: 8),
          color: image.ColorRgb8(255, 0, 0),
        ),
        duration: 10,
      );
      encoder.addFrame(
        image.fill(
          image.Image(width: 8, height: 8),
          color: image.ColorRgb8(0, 0, 255),
        ),
        duration: 10,
      );
      final bytes = encoder.finish()!;
      final source = await File('${folder.path}/keyboard.bin')
          .writeAsBytes(bytes);
      final prepared = await LoomMediaPreparation.prepare(
        source,
        'image',
        temporaryDirectory: () async => folder,
      );
      expect(prepared.owned, false);
      expect(await prepared.file.readAsBytes(), bytes);
      expect(image.decodeGif(await prepared.file.readAsBytes())!.numFrames, 2);
      final metadata = await LoomMediaPreparation.dimensions(
        prepared.file,
        'image',
      );
      expect(metadata['animated'], true);
      expect(metadata['mime'], 'image/gif');
      expect(metadata['width'], 8);
      await prepared.dispose();
      expect(await source.exists(), true);
    } finally {
      await folder.delete(recursive: true);
    }
  });
  test('invalid GIF container is rejected without modifying source', () async {
    final folder = await Directory.systemTemp.createTemp('loom_invalid_gif_');
    try {
      final source = await File('${folder.path}/invalid.gif')
          .writeAsString('GIF89a-broken');
      await expectLater(
        LoomMediaPreparation.prepare(source, 'image'),
        throwsA(anything),
      );
      expect(await source.readAsString(), 'GIF89a-broken');
    } finally {
      await folder.delete(recursive: true);
    }
  });
  for (final kind in ['audio', 'video_note']) {
    test(
      '$kind survives rich content decoding with the encrypted file capability',
      () {
        final message = LoomMessageContent(
          attachment: {
            'kind': kind,
            'url':
                'https://sender.test/api/v1/attachments/att_${List.filled(64, 'a').join()}',
            'key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'bytes': 120,
          },
        );
        final decoded = LoomMessageContent.decode(message.encode());
        expect(decoded.attachment!['kind'], kind);
        expect(decoded.attachment!['key'], message.attachment!['key']);
        expect(decoded.preview, kind == 'audio' ? '🎤' : '🎬');
      },
    );
  }
}
