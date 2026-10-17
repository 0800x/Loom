import 'dart:convert';
import 'dart:io';

import 'package:loom_design/loom_design.dart';
import 'package:loom_next/app/appearance_preferences.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late LoomAppearancePreferencesStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'loom-appearance-test-',
    );
    store = LoomAppearancePreferencesStore(directory: directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'legacy and unknown presentation options keep existing choices',
    () async {
      final file = File('${directory.path}/loom-appearance.json');
      final data = <String, Object?>{
        'theme': 'oled',
        'glass': 'high',
        'language': 'fa',
        'accent': 0xFF009688,
      };
      for (final options in [
        <String, Object?>{},
        {'motion': 'future', 'chatDensity': 'future'},
      ]) {
        await file.writeAsString(jsonEncode({...data, ...options}));
        final saved = (await store.load())!;
        expect(saved.theme, LoomThemeMode.oled);
        expect(saved.locale, const Locale('fa'));
        expect(saved.accent, 0xFF009688);
        expect(saved.motion, LoomMotionPreference.system);
        expect(saved.chatDensity, LoomChatDensity.comfortable);
      }
    },
  );

  test(
    'queued appearance changes survive restart with the last choice',
    () async {
      await Future.wait([
        store.save(
          const LoomAppearancePreferences(
            theme: LoomThemeMode.light,
            glass: LoomGlassQuality.high,
            locale: Locale('en'),
          ),
        ),
        store.save(
          const LoomAppearancePreferences(
            theme: LoomThemeMode.oled,
            glass: LoomGlassQuality.high,
            locale: Locale('fa'),
            accent: 0xFF009688,
            motion: LoomMotionPreference.reduced,
            chatDensity: LoomChatDensity.compact,
          ),
        ),
      ]);
      final restored = (await LoomAppearancePreferencesStore(
        directory: directory,
      ).load())!;
      expect(restored.theme, LoomThemeMode.oled);
      expect(restored.locale, const Locale('fa'));
      expect(restored.accent, 0xFF009688);
      expect(restored.motion, LoomMotionPreference.reduced);
      expect(restored.chatDensity, LoomChatDensity.compact);
      expect(
        await File('${directory.path}/loom-appearance.json.tmp').exists(),
        isFalse,
      );
    },
  );

  test('damaged preferences do not block subsequent saves', () async {
    await File(
      '${directory.path}/loom-appearance.json',
    ).writeAsString('{broken');
    expect(await store.load(), isNull);
    await store.save(
      const LoomAppearancePreferences(
        theme: LoomThemeMode.dark,
        glass: LoomGlassQuality.high,
        locale: Locale('en'),
        chatDensity: LoomChatDensity.compact,
      ),
    );
    expect((await store.load())!.chatDensity, LoomChatDensity.compact);
  });
}
