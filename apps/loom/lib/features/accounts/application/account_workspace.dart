import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart'
    show LoomAccountScope;

/// Resolves the durable directory for the currently selected account.
///
/// Legacy single-account installations keep their original support directory.
/// New account slots receive isolated subdirectories.
abstract final class LoomAccountWorkspace {
  static Future<Directory> active() async {
    final support = await getApplicationSupportDirectory();
    final scope = LoomAccountScope.current;
    if (scope == null) return support;

    final id = scope.id;
    if (!RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id)) {
      throw StateError('Invalid active account workspace');
    }

    final directory = Directory(
      '${support.path}${Platform.pathSeparator}accounts${Platform.pathSeparator}$id',
    );
    await directory.create(recursive: true);
    return directory;
  }
}
