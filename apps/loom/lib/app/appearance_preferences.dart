import 'dart:convert';
import 'dart:io';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

class LoomAppearancePreferences {
  const LoomAppearancePreferences({
    required this.theme,
    required this.glass,
    required this.locale,
    this.accent,
    this.motion = LoomMotionPreference.system,
    this.chatDensity = LoomChatDensity.comfortable,
  });

  final LoomThemeMode theme;
  final LoomGlassQuality glass;
  final Locale locale;
  final int? accent;
  final LoomMotionPreference motion;
  final LoomChatDensity chatDensity;
}

/// Only non-sensitive presentation preferences belong in this file.
/// Drafts, identity secrets and message content are never written here.
class LoomAppearancePreferencesStore {
  LoomAppearancePreferencesStore({this.directory});
  final Directory? directory;
  Future<void> _writes = Future<void>.value();

  Future<File> _file() async {
    final supportDirectory =
        directory ?? await getApplicationSupportDirectory();
    return File('${supportDirectory.path}/loom-appearance.json');
  }

  Future<LoomAppearancePreferences?> load() async {
    try {
      final data = jsonDecode(await (await _file()).readAsString());
      if (data is! Map<String, dynamic>) return null;
      final theme = LoomThemeMode.values
          .where((value) => value.name == data['theme'])
          .firstOrNull;
      final glass = LoomGlassQuality.values
          .where((value) => value.name == data['glass'])
          .firstOrNull;
      final language = data['language'];
      if (theme == null ||
          glass == null ||
          (language != 'en' && language != 'fa')) {
        return null;
      }
      return LoomAppearancePreferences(
        theme: theme,
        glass: glass,
        locale: Locale(language as String),
        chatDensity:
            LoomChatDensity.values
                .where((v) => v.name == data['chatDensity'])
                .firstOrNull ??
            LoomChatDensity.comfortable,
        motion:
            LoomMotionPreference.values
                .where((v) => v.name == data['motion'])
                .firstOrNull ??
            LoomMotionPreference.system,
        accent:
            data['accent'] is int &&
                (data['accent'] as int) >= 0 &&
                (data['accent'] as int) <= 0xFFFFFFFF
            ? data['accent'] as int
            : null,
      );
    } catch (_) {
      // A missing or damaged preferences file must not block account startup.
      return null;
    }
  }

  Future<void> save(LoomAppearancePreferences value) {
    return _writes = _writes.then((_) async {
      try {
        final file = await _file();
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(
          jsonEncode({
            'theme': value.theme.name,
            'glass': value.glass.name,
            'language': value.locale.languageCode,
            'accent': value.accent,
            'motion': value.motion.name,
            'chatDensity': value.chatDensity.name,
          }),
          flush: true,
        );
        await temporary.rename(file.path);
      } catch (_) {
        // Keep the in-memory preference usable on read-only/full storage.
      }
    });
  }
}

/// Shared presentation control; the app owns persistence and theme rebuilding.
class LoomAppearanceScope extends InheritedWidget {
  const LoomAppearanceScope({
    required this.mode,
    required this.onChanged,
    this.accent,
    this.onAccentChanged,
    this.motion = LoomMotionPreference.system,
    this.onMotionChanged,
    this.chatDensity = LoomChatDensity.comfortable,
    this.onChatDensityChanged,
    required super.child,
    super.key,
  });
  final LoomThemeMode mode;
  final int? accent;
  final ValueChanged<int?>? onAccentChanged;
  final LoomMotionPreference motion;
  final ValueChanged<LoomMotionPreference>? onMotionChanged;
  final LoomChatDensity chatDensity;
  final ValueChanged<LoomChatDensity>? onChatDensityChanged;
  final ValueChanged<LoomThemeMode> onChanged;
  static LoomAppearanceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LoomAppearanceScope>();
  @override
  bool updateShouldNotify(LoomAppearanceScope oldWidget) =>
      oldWidget.motion != motion ||
      oldWidget.chatDensity != chatDensity ||
      oldWidget.mode != mode ||
      oldWidget.accent != accent ||
      oldWidget.onChanged != onChanged;
}
