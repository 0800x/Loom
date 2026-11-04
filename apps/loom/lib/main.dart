import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart';

import 'package:media_kit/media_kit.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'app/loom_app.dart';
import 'features/connectivity/application/default_network_generation_monitor.dart';
import 'features/nodes/application/local_https_trust.dart';

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
  _defaultNetworkMonitor.start();
  runApp(const LoomApp());
}
