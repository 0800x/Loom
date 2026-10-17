import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Loom is pre-release: use one explicit namespace/config and avoid plugin
// migration machinery entirely. App Lock performs its own authenticated
// wrapping, so flutter_secure_storage remains a stable non-biometric backing
// store. Keystore failures preserve the backing data and surface an error.
const _loomPlatformStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    storageNamespace: 'loom',
    resetOnError: false,
    migrateOnAlgorithmChange: false,
    migrateWithBackup: false,
  ),
);

/// Android's auth-per-use Keystore key releases a native vault key, not a bool
/// granting access to unprotected credentials. Unsupported platforms retain
/// their existing secure storage and do not advertise biometric protection.
class LoomAppLock extends ChangeNotifier {
  LoomAppLock._();
  static final instance = LoomAppLock._();
  static const _channel = MethodChannel('loom/app_lock');
  static const _raw = _loomPlatformStorage;
  static const _prefix = 'loom-protected-v1:';
  static const _tracing = bool.fromEnvironment('LOOM_APP_LOCK_TRACE');

  static void _requireSupportedEnvelope(String value) {
    if (RegExp(r'^[a-z][a-z0-9_-]*-protected-v[0-9]+:').hasMatch(value) &&
        !value.startsWith(_prefix)) {
      throw PlatformException(
        code: 'unsupported_vault_format',
        message:
            'This protected store uses an incompatible format. Export it with the original application before upgrading.',
      );
    }
  }

  // Never pass keys, values, exception messages or stack traces here.
  void _trace(String stage, [Object? error]) {
    if (_tracing) {
      debugPrint(
        'LoomAppLock stage=$stage'
        '${error == null ? '' : ' error_class=${error.runtimeType}'}',
      );
    }
  }

  Future<T> _atStage<T>(String stage, Future<T> Function() operation) async {
    _trace(stage);
    try {
      return await operation();
    } catch (error) {
      _trace('${stage}_failed', error);
      rethrow;
    }
  }

  Future<void>? _initializing;
  Future<void> _tail = Future.value();
  bool initialized = false;
  bool available = false;
  bool enabled = false;
  bool locked = false;
  bool authenticating = false;
  bool changing = false;
  String availabilityReason = 'unsupported_platform';

  Future<void> refreshStatus() async {
    await initialize();
    if (Platform.isAndroid && !authenticating) {
      await _refresh();
    }
  }

  Future<void> openDeviceSecuritySettings() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openDeviceSecuritySettings');
    }
  }

  Future<void> initialize() => _initializing ??= _initialize().catchError((
        Object error,
        StackTrace stack,
      ) {
        _initializing = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _initialize() async {
    if (Platform.isAndroid) {
      if (_tracing) {
        await _channel.invokeMethod<void>('setDiagnostics', {'enabled': true});
      }
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'locked') {
          _setLocked();
        }
      });
      await _refresh();
    }
    initialized = true;
    notifyListeners();
  }

  Future<void> _refresh() async {
    final status = await _channel.invokeMapMethod<String, Object?>('status');
    if (status == null) {
      throw StateError('App lock state unavailable');
    }
    available = status['available'] == true;
    availabilityReason =
        status['reason'] as String? ?? 'authenticator_unavailable';
    enabled = status['enabled'] == true;
    locked = status['locked'] == true;
    notifyListeners();
  }

  void _setLocked() {
    if (!enabled || locked) {
      return;
    }
    locked = true;
    notifyListeners();
  }

  Future<void> lock() async {
    if (!enabled || authenticating) {
      return;
    }
    _setLocked();
    await _channel.invokeMethod<void>('lock');
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<bool> _authenticateNative(String method, String title) async {
    bool accepted;
    try {
      accepted = await _atStage(
            '${method}_native_start',
            () => _channel.invokeMethod<bool>(method, {'title': title}),
          ) ==
          true;
    } on MissingPluginException {
      throw PlatformException(
        code: 'app_lock_native_bridge_missing',
        message: 'The installed Android bridge does not match this Dart build.',
      );
    }
    if (!accepted) {
      return false;
    }
    try {
      await _waitForForeground();
      _trace('activity_resumed');
      // Native keeps the released vault key alive across the biometric
      // Activity handoff until Flutter confirms that it is resumed again.
      try {
        await _channel.invokeMethod<void>('completeAuthHandoff');
        _trace('handoff_complete');
      } on MissingPluginException {
        throw PlatformException(
          code: 'app_lock_native_bridge_missing',
          message:
              'The installed Android bridge does not match this Dart build.',
        );
      }
      return true;
    } catch (_) {
      // Fail closed if Flutter never completes the foreground handoff.
      try {
        await _channel.invokeMethod<void>('lock');
      } on MissingPluginException {
        // The original bridge mismatch is more useful than a cleanup failure.
      }
      rethrow;
    }
  }

  Future<bool> unlock(String title) async {
    await initialize();
    if (!enabled) {
      return true;
    }
    if (authenticating) {
      return false;
    }
    authenticating = true;
    notifyListeners();
    try {
      if (!await _authenticateNative('unlock', title)) {
        return false;
      }
      await _serial(() async {
        try {
          await _protectExisting();
          locked = false;
        } catch (_) {
          locked = true;
          await _channel.invokeMethod<void>('lock');
          rethrow;
        }
      });
      return true;
    } finally {
      authenticating = false;
      await _refresh();
    }
  }

  Future<bool> configure(bool value, String title) async {
    await initialize();
    if (changing || authenticating || (!available && value)) {
      return false;
    }
    changing = true;
    authenticating = true;
    notifyListeners();
    try {
      return await _serial(() async {
        try {
          if (value) {
            if (!await _authenticateNative('enable', title)) {
              return false;
            }
            enabled = true;
            await _protectExisting();
            locked = false;
          } else {
            if (!await _authenticateNative('unlock', title)) {
              return false;
            }
            final values = await _readAllRaw();
            for (final entry in values.entries) {
              if (!entry.key.startsWith('loom.') ||
                  !entry.value.startsWith(_prefix)) {
                continue;
              }
              final plaintext = await _open(entry.key, entry.value);
              await _writeRaw(entry.key, plaintext);
            }
            // Remove the capsule only after every credential is safely back in
            // platform secure storage. Interrupted migration resumes on unlock.
            await _channel.invokeMethod<void>('disable');
            enabled = false;
            locked = false;
          }
          return true;
        } catch (_) {
          if (enabled) {
            locked = true;
            await _channel.invokeMethod<void>('lock');
          }
          rethrow;
        }
      });
    } finally {
      changing = false;
      authenticating = false;
      await _refresh();
    }
  }

  Future<Map<String, String>> _readAllRaw() async {
    _trace('secure_read_all_start');
    try {
      final values = await _raw.readAll();
      for (final value in values.values) {
        _requireSupportedEnvelope(value);
      }
      _trace('secure_read_all_ok');
      return values;
    } catch (error) {
      _trace('secure_read_all_failed', error);
      throw PlatformException(
        code: 'secure_storage_read_failed',
        message: 'Loom could not read the Android credential store.',
      );
    }
  }

  Future<void> _writeRaw(String key, String value) async {
    try {
      await _raw.write(key: key, value: value);
    } catch (error) {
      _trace('secure_write_failed', error);
      throw PlatformException(
        code: 'secure_storage_write_failed',
        message: 'Loom could not update the Android credential store.',
      );
    }
  }

  Future<void> _protectExisting() async {
    final values = await _readAllRaw();
    final protected = <String, String>{};

    // Finish every native wrap + verification before mutating secure storage.
    // A crypto failure therefore cannot leave a half-migrated credential set.
    var index = 0;
    for (final entry in values.entries) {
      if (!entry.key.startsWith('loom.') || entry.value.startsWith(_prefix)) {
        continue;
      }
      final sealed = await _atStage(
        'wrap:$index',
        () => _seal(entry.key, entry.value),
      );
      final opened = await _atStage(
        'verify:$index',
        () => _open(entry.key, sealed),
      );
      if (opened != entry.value) {
        throw PlatformException(code: 'vault_verification_failed');
      }
      protected[entry.key] = sealed;
      index++;
    }

    index = 0;
    for (final entry in protected.entries) {
      _trace('secure_write:$index');
      await _writeRaw(entry.key, entry.value);
      index++;
    }
    _trace('migration_complete');
  }

  Future<void> _waitForForeground() async {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      return;
    }
    // Device-PIN authentication can complete while Android still reports the
    // Activity paused. Keep `authenticating` true until its return transition
    // finishes, otherwise AppLockGate immediately locks the released key again.
    final resumed = Completer<void>();
    final listener = AppLifecycleListener(
      onStateChange: (next) {
        if (next == AppLifecycleState.resumed && !resumed.isCompleted) {
          resumed.complete();
        }
      },
    );
    try {
      await resumed.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          throw PlatformException(code: 'vault_not_foreground');
        },
      );
    } finally {
      listener.dispose();
    }
  }

  Future<String> _seal(String key, String value) async {
    final bytes = Uint8List.fromList(utf8.encode(value));
    try {
      final wrapped = await _channel.invokeMethod<Uint8List>('wrap', {
        'key': key,
        'value': bytes,
      });
      if (wrapped == null) {
        throw StateError('Vault did not protect the value');
      }
      return '$_prefix${base64Encode(wrapped)}';
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<String> _open(String key, String value) async {
    final response = await _channel.invokeMethod<Uint8List>('unwrap', {
      'key': key,
      'value': base64Decode(value.substring(_prefix.length)),
    });
    if (response == null) {
      throw StateError('Vault did not unlock the value');
    }
    // Engine channel responses are read-only views. Wiping that view throws
    // UnsupportedError in finally, discarding a SUCCESSFUL decrypt/UTF-8 return.
    // Only erase memory we own. The engine response and returned Dart String
    // remain GC-managed; this does not promise complete plaintext zeroization.
    final bytes = Uint8List.fromList(response);
    try {
      return utf8.decode(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }
}

/// Existing secure-storage injection stays intact in package tests. All default
/// identity, device and session stores use this boundary in the shipping app.
class LoomSecretStorage {
  LoomSecretStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? _loomPlatformStorage;
  final FlutterSecureStorage _storage;
  final _lock = LoomAppLock.instance;

  Future<String?> read({required String key}) async {
    await _lock.initialize();
    return _lock._serial(() async {
      if (_lock.locked) {
        throw StateError('Loom is locked');
      }
      final value = await _storage.read(key: key);
      if (_lock.locked) {
        throw StateError('Loom is locked');
      }
      if (value == null) {
        return null;
      }
      LoomAppLock._requireSupportedEnvelope(value);
      if (value.startsWith(LoomAppLock._prefix)) {
        final opened = await _lock._open(key, value);
        if (_lock.locked) {
          throw StateError('Loom is locked');
        }
        return opened;
      }
      return value;
    });
  }

  Future<void> write({required String key, required String? value}) async {
    await _lock.initialize();
    return _lock._serial(() async {
      if (_lock.locked) {
        throw StateError('Loom is locked');
      }
      await _storage.write(
        key: key,
        value: value == null || !_lock.enabled
            ? value
            : await _lock._seal(key, value),
      );
    });
  }

  Future<void> delete({required String key}) async {
    await _lock.initialize();
    return _lock._serial(() async {
      if (_lock.locked) {
        throw StateError('Loom is locked');
      }
      await _storage.delete(key: key);
    });
  }
}
