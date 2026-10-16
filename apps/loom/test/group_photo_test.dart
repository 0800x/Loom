import 'dart:typed_data';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/groups/application/group_photo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'normalizes a large detailed photo to a bounded metadata-free square',
    () async {
      final input = img.Image(width: 800, height: 500);
      for (var y = 0; y < input.height; y++) {
        for (var x = 0; x < input.width; x++) {
          input.setPixelRgb(
            x,
            y,
            (x * 17 + y * 7) % 256,
            (x * 3 + y * 19) % 256,
            (x * 23 + y * 11) % 256,
          );
        }
      }
      final source = img.encodePng(input);
      final result = await normalizeGroupPhoto(source);
      LoomGroupProfile.validatePng(result);
      final decoded = img.decodePng(result)!;
      expect(decoded.width, 128);
      expect(decoded.height, 128);
      expect(result.length, lessThanOrEqualTo(LoomGroupProfile.maxBytes));
      expect(
        source.any((b) => b != 0),
        isTrue,
        reason: 'Caller owns source lifetime',
      );
    },
  );
  test('invalid input fails without creating a photo', () async {
    await expectLater(
      normalizeGroupPhoto(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
  });
}
