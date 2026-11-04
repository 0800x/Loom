import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

import 'package:media_kit/media_kit.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import 'app/loom_app.dart';
import 'features/accounts/application/account_registry.dart';
import 'features/connectivity/application/default_network_generation_monitor.dart';
import 'features/nodes/application/local_https_trust.dart';
import 'features/security/application/experimental_ratchet.dart';
import 'features/security/application/sqlcipher_loader.dart';

final LoomDefaultNetworkGenerationMonitor _defaultNetworkMonitor =
    LoomDefaultNetworkGenerationMonitor();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final rejected = await LoomLocalHttpsTrust.load();
    if (rejected > 0) {
      debugPrint('Invalid local HTTPS certificates were rejected.');
    }
  } catch (_) {
    debugPrint(
      'Local HTTPS certificate storage could not be loaded. No additional certificates were trusted.',
    );
  }
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/legal/LICENSE');
    final copyright = await rootBundle.loadString('assets/legal/COPYRIGHT');
    yield LicenseEntryWithLineBreaks(['Loom'], '$copyright\n$license');
    yield LicenseEntryWithLineBreaks([
      'Vazirmatn',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  MediaKit.ensureInitialized();
  VideoPlayerMediaKit.ensureInitialized(
    android: true,
    iOS: true,
    macOS: true,
    windows: true,
    linux: true,
  );
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  // Multi-account: resolve the active account slot (and its secure-storage
  // scope + workspace) BEFORE any vault, flag file or database is touched.
  try {
    LoomAccountScope.current = await LoomAccountRegistry.activeScope();
  } catch (_) {
    LoomAccountScope.current = null; // Legacy single-account mode.
  }
  // Load the user's explicit experimental-ratchet opt-in before any DTN v2
  // runtime is constructed, so the send gate reflects the real preference.
  await LoomExperimentalRatchet.load();
  // Route package:sqlite3 at the SQLCipher native library before any store
  // opens a database file; encryption stays a no-op until the user opts in.
  try {
    await LoomSqlCipherLoader.prepare();
  } catch (_) {
    // A failed override would surface later as a strict `PRAGMA cipher_version`
    // error instead of silently writing plaintext with a configured key.
  }
  // Database-at-rest encryption must be configured and migrated BEFORE the
  // first store opens the messaging database.
  _defaultNetworkMonitor.start();
  runApp(const LoomApp());
}
