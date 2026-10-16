import 'dart:io';
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/messaging/application/media_preparation.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('detected message link invokes the external-open callback', (
    tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.light(),
        home: Scaffold(
          body: LoomMessageBubble(
            text: 'https://example.com',
            time: '12:00',
            mine: true,
            onActions: () {},
            onLinkTap: (uri) => opened = uri,
          ),
        ),
      ),
    );
    await tester.tap(find.text('https://example.com'));
    expect(opened, Uri.parse('https://example.com'));
    expect(tester.takeException(), isNull);
  });
  test('detects Persian embedded URLs, www and domains, trims punctuation', () {
    final links = loomDetectLinks(
      'ببین https://example.com/a(b). بعد www.example.ir، یا example.org/test؟',
    );
    expect(links.map((e) => e.uri.toString()), [
      'https://example.com/a(b)',
      'https://www.example.ir',
      'https://example.org/test',
    ]);
    expect(
      loomDetectLinks('(https://example.com/a)')[0].uri.toString(),
      'https://example.com/a',
    );
  });
  test('does not activate email, chat addresses or non-web schemes', () {
    expect(
      loomDetectLinks(
        'user@example.com @alice:loom.example.org javascript:example.com file://example.org https://user:pass@example.org',
      ),
      isEmpty,
    );
  });
  test(
    'keyboard transparent PNG remains transparent and survives message decoding',
    () async {
      final folder = await Directory.systemTemp.createTemp('sticker_test_');
      try {
        final pixels = image.Image(width: 16, height: 16, numChannels: 4);
        pixels.setPixelRgba(8, 8, 10, 20, 30, 255);
        final bytes = image.encodePng(pixels);
        final source = await File(
          '${folder.path}/sticker.png',
        ).writeAsBytes(bytes);
        expect(
          await LoomMediaPreparation.keyboardSticker(source, 'image/png'),
          true,
        );
        final prepared = await LoomMediaPreparation.prepare(
          source,
          'image',
          sticker: true,
        );
        expect(await prepared.file.readAsBytes(), bytes);
        await prepared.dispose();
        expect(await source.exists(), true);
        final message = LoomMessageContent(
          attachment: {
            'kind': 'image',
            'sticker': true,
            'mime': 'image/png',
            'url':
                'https://example.org/api/v1/attachments/att_${List.filled(64, 'a').join()}',
            'key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'bytes': bytes.length,
          },
        );
        expect(
          LoomMessageContent.decode(message.encode()).attachment!['sticker'],
          true,
        );
        final opaque = await File('${folder.path}/photo.png').writeAsBytes(
          image.encodePng(
            image.fill(
              image.Image(width: 16, height: 16, numChannels: 4),
              color: image.ColorRgba8(10, 20, 30, 255),
            ),
          ),
        );
        expect(
          await LoomMediaPreparation.keyboardSticker(opaque, 'image/png'),
          false,
        );
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );
}
