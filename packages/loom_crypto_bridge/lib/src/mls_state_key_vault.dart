import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'app_lock.dart';

/// Device-local wrapping key. Never export it with account recovery or linking.
/// The file lock prevents two application processes from creating different
/// wrapping keys for the same device's native state database.
class LoomMlsStateKeyVault {
  LoomMlsStateKeyVault({LoomSecretStorage? storage})
      : _storage = storage ?? LoomSecretStorage();
  final LoomSecretStorage _storage;
  static Future<void> _tail = Future.value();
  Future<List<int>> open({
    required String identityId,
    required String deviceId,
    required String lockPath,
    required bool hasNativeState,
  }) {
    final result = _tail.then((_) async {
      if (LoomAppLock.instance.locked) {
        throw StateError('Loom is locked');
      }
      final file = File(lockPath);
      await file.parent.create(recursive: true);
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        final name = 'loom.mls.state-key.v1.$identityId.$deviceId';
        final stored = await _storage.read(key: name);
        if (stored != null) {
          final key = base64Decode(stored);
          if (key.length != 32) {
            throw StateError('Damaged MLS wrapping key');
          }
          return key;
        }
        if (hasNativeState) {
          throw StateError(
            'MLS wrapping key is missing. Rejoin groups with a new authorized device.',
          );
        }
        final random = Random.secure();
        final key = List<int>.generate(32, (_) => random.nextInt(256));
        await _storage.write(key: name, value: base64Encode(key));
        return key;
      } finally {
        await handle.close();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
