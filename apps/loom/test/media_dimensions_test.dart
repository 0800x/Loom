import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final legacy = <String, Object?>{
    'kind': 'image',
    'url': 'https://home.example/media',
    'key': 'key',
    'bytes': 1024,
  };
  LoomMessageContent decode(Map<String, Object?> media) =>
      LoomMessageContent.decode(
        LoomMessageContent(text: '', attachment: media).encode(),
      );
  test('existing media without dimensions remains readable', () {
    expect(decode(legacy).attachment!['kind'], 'image');
  });
  test(
    'photo dimensions and video duration round-trip inside encrypted content',
    () {
      final media = {
        ...legacy,
        'kind': 'video_note',
        'width': 720,
        'height': 1280,
        'durationMs': 1250,
      };
      expect(decode(media).attachment, media);
    },
  );
  test('invalid dimensions are rejected before layout or decode', () {
    for (final value in [0, -1, 60001, 1.5, '720']) {
      expect(() => decode({...legacy, 'width': value}), throwsFormatException);
    }
  });
}
