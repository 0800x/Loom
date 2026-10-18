import 'package:flutter_test/flutter_test.dart';
import 'package:loom_next/app/wallpaper_preferences.dart';

void main() {
  test(
    'legacy blur switch migrates without changing dim or enabling motion',
    () {
      final value = LoomWallpaper.fromJson({
        'style': 'photo',
        'image': '${'a' * 32}.jpg',
        'dim': .3,
        'blur': true,
      });
      expect(value.blurAmount, 6);
      expect(value.parallax, false);
      expect(value.dim, .3);
      final changed = value.copyWith(blurAmount: 18, parallax: true);
      final restored = LoomWallpaper.fromJson(changed.toJson());
      expect(restored.blurAmount, 18);
      expect(restored.parallax, true);
      expect(restored.dim, .3);
      expect(restored.image, value.image);
      expect(restored.copyWith(blurAmount: 0).blur, false);
    },
  );
  test('wallpaper import rejects invalid intensity and motion values', () {
    for (final amount in [-1, 25, double.nan, double.infinity, '6']) {
      expect(
        () => LoomWallpaper.fromJson({
          ...const LoomWallpaper().toJson(),
          'blurAmount': amount,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => LoomWallpaper.fromJson({
        ...const LoomWallpaper().toJson(),
        'parallax': 'true',
      }),
      throwsFormatException,
    );
    for (final style in LoomWallpaper.styles.where((v) => v != 'photo')) {
      expect(
        LoomWallpaper.fromJson(LoomWallpaper(style: style).toJson()).style,
        style,
      );
    }
  });
}
