import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Non-sensitive notification preferences. Mirrors the appearance store's
/// plain-JSON contract: no secrets, drafts or message content live here.
class LoomNotificationPreferences {
  const LoomNotificationPreferences({this.stayConnected = false});

  /// Keep the messaging connection alive in an Android foreground service
  /// after the app is swiped away, so message notifications keep arriving.
  final bool stayConnected;

  LoomNotificationPreferences copyWith({bool? stayConnected}) =>
      LoomNotificationPreferences(
        stayConnected: stayConnected ?? this.stayConnected,
      );
}

class LoomNotificationPreferencesStore {
  LoomNotificationPreferencesStore({this.directory});
  final Directory? directory;

  Future<File> _file() async {
    final support = directory ?? await getApplicationSupportDirectory();
    return File('${support.path}/loom-notifications.json');
  }

  Future<LoomNotificationPreferences> load() async {
    try {
      final data = jsonDecode(await (await _file()).readAsString());
      if (data is! Map<String, dynamic>) {
        return const LoomNotificationPreferences();
      }
      return LoomNotificationPreferences(
        stayConnected: data['stayConnected'] == true,
      );
    } catch (_) {
      return const LoomNotificationPreferences();
    }
  }

  Future<void> save(LoomNotificationPreferences preferences) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode({'stayConnected': preferences.stayConnected}),
      flush: true,
    );
  }
}
