import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:test/test.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZbkAAAAASUVORK5CYII=',
);
void main() {
  test('profile supports a bounded PNG and explicit removal', () {
    final image = LoomGroupProfile.fromJson({
      'v': 1,
      'png': base64Encode(png),
    });
    expect(image.png, base64Encode(png));
    expect(LoomGroupProfile.fromJson({'v': 1, 'png': null}).png, isNull);
  });
  test(
    'rejects oversized, truncated, animated and oversized-dimension images',
    () {
      for (final bytes in [
        Uint8List(LoomGroupProfile.maxBytes + 1),
        png.sublist(0, png.length - 1),
        Uint8List.fromList(png)..[19] = 129,
        Uint8List.fromList(png)..setRange(37, 41, ascii.encode('acTL')),
      ]) {
        expect(
          () => LoomGroupProfile.fromJson({'v': 1, 'png': base64Encode(bytes)}),
          throwsFormatException,
        );
      }
      for (final value in [
        {'v': 2, 'png': null},
        {'v': 1},
        {'v': 1, 'png': 5},
        {'v': 1, 'png': 'invalid'},
      ]) {
        expect(() => LoomGroupProfile.fromJson(value), throwsFormatException);
      }
    },
  );
}
