import 'dart:convert';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// Model the native vault's authenticated lifetime. This exercises the shipping
// Dart migration and reads; it does not replace Android Keystore device tests.
class _NativeVault {
  final cipher = AesGcm.with256bits();
  final key = SecretKey(List<int>.generate(32, (index) => index));
  bool enabled = false;
  bool unlocked = false;
  bool handoffPending = false;
  int completedHandoffs = 0;
  bool cancelNextUnlock = false;
  bool corruptWrap = false;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'setDiagnostics':
        return null;
      case 'status':
        return {
          'available': true,
          'reason': 'ready',
          'enabled': enabled,
          'locked': enabled && !unlocked,
        };
      case 'enable':
        enabled = true;
        unlocked = true;
        handoffPending = true;
        return true;
      case 'unlock':
        if (cancelNextUnlock) {
          cancelNextUnlock = false;
          return false;
        }
        unlocked = true;
        handoffPending = true;
        return true;
      case 'completeAuthHandoff':
        handoffPending = false;
        completedHandoffs++;
        return null;
      case 'lock':
        handoffPending = false;
        unlocked = false;
        return null;
      case 'disable':
        if (!unlocked) {
          throw PlatformException(code: 'vault_locked');
        }
        enabled = false;
        unlocked = false;
        return null;
      case 'wrap':
      case 'unwrap':
        if (!unlocked) {
          throw PlatformException(code: 'vault_locked');
        }
        final args = call.arguments as Map;
        final value = args['value'] as Uint8List;
        final aad = utf8.encode(args['key'] as String);
        if (call.method == 'wrap') {
          final box = await cipher.encrypt(value, secretKey: key, aad: aad);
          final bytes = Uint8List.fromList(box.concatenation());
          if (corruptWrap) {
            bytes[bytes.length - 1] ^= 1;
          }
          return bytes;
        }
        final box = SecretBox.fromConcatenation(
          value,
          nonceLength: 12,
          macLength: 16,
        );
        return Uint8List.fromList(
          await cipher.decrypt(box, secretKey: key, aad: aad),
        );
      default:
        throw MissingPluginException(call.method);
    }
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('protected identity, session and refresh token survive lock and new readers', () async {
    const original = {
      'loom.identity.id.v1': 'chn:existing-account',
      'loom.session.metadata.v1':
          '{"account":"existing-account","device":"same-device"}',
      'loom.session.refresh.v1.node.device': 'existing-refresh-token',
    };
    FlutterSecureStorage.setMockInitialValues(Map.of(original));
    const raw = FlutterSecureStorage(
      aOptions: AndroidOptions(
        storageNamespace: 'loom',
        resetOnError: true,
        migrateOnAlgorithmChange: false,
        migrateWithBackup: false,
      ),
    );
    const channel = MethodChannel('loom/app_lock');
    final native = _NativeVault();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // setMockMethodCallHandler creates a mutable response envelope, unlike
    // PlatformMessageResponseDart::Complete in the actual Flutter engine.
    // Freeze the ENCODED envelope: freezing only the fake's Uint8List is
    // insufficient because StandardMethodCodec copies it during encoding.
    const codec = StandardMethodCodec();
    messenger.setMockMessageHandler(channel.name, (message) async {
      try {
        final result = await native.handle(codec.decodeMethodCall(message));
        return codec.encodeSuccessEnvelope(result).asUnmodifiableView();
      } on PlatformException catch (error) {
        return codec.encodeErrorEnvelope(code: error.code);
      } catch (_) {
        return codec.encodeErrorEnvelope(code: 'test_vault_failure');
      }
    });
    final lock = LoomAppLock.instance;
    await lock.initialize();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    lock.available = true;
    lock.enabled = false;
    lock.locked = false;
    addTearDown(() {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      messenger.setMockMessageHandler(channel.name, null);
      lock.enabled = false;
      lock.locked = false;
      lock.available = false;
      native.key.destroy();
    });

    expect(await lock.configure(true, 'Protect Loom'), isTrue);
    final protected = await raw.readAll();
    expect(protected.keys, unorderedEquals(original.keys));
    for (final entry in original.entries) {
      expect(protected[entry.key], startsWith('loom-protected-v1:'));
      expect(protected[entry.key], isNot(entry.value));
    }

    await lock.lock();
    final reopened = LoomSecretStorage();
    await expectLater(
      reopened.read(key: 'loom.identity.id.v1'),
      throwsStateError,
    );
    native.cancelNextUnlock = true;
    expect(await lock.unlock('Unlock'), isFalse);
    expect(lock.locked, isTrue);
    expect(await raw.readAll(), protected);

    // Android's PIN screen can return the crypto result before onResume.
    // Do not expose the session (or trigger Gate's background relock) yet.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final unlocking = lock.unlock('Unlock');
    await pumpEventQueue();
    expect(lock.authenticating, isTrue);
    expect(lock.locked, isTrue);
    expect(native.handoffPending, isTrue);
    expect(native.completedHandoffs, 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(await unlocking, isTrue);
    expect(native.handoffPending, isFalse);
    expect(native.completedHandoffs, 2);
    for (final entry in original.entries) {
      expect(await reopened.read(key: entry.key), entry.value);
    }
    // Unlock must not double-wrap existing values or replace the account.
    expect(await raw.readAll(), protected);
    expect(await lock.configure(false, 'Disable lock'), isTrue);
    expect(await raw.readAll(), original);

    // A concurrent default-store write queues behind the migration; it must
    // never re-enter the serial queue or persist an unprotected new value.
    final secrets = LoomSecretStorage();
    final enabling = lock.configure(true, 'Protect Loom');
    final queuedWrite = secrets.write(
      key: 'loom.test.after_enable',
      value: 'after-enable',
    );
    await Future.wait<void>([
      enabling.then((accepted) => expect(accepted, isTrue)),
      queuedWrite,
    ]);
    expect(
      await raw.read(key: 'loom.test.after_enable'),
      startsWith('loom-protected-v1:'),
    );
    expect(await secrets.read(key: 'loom.test.after_enable'), 'after-enable');
    await secrets.delete(key: 'loom.test.after_enable');
    expect(await lock.configure(false, 'Disable lock'), isTrue);

    native.corruptWrap = true;
    await expectLater(lock.configure(true, 'Protect again'), throwsA(anything));
    expect(
      await raw.readAll(),
      original,
      reason: 'verify before replacing credentials',
    );
    expect(lock.locked, isTrue);
    native.corruptWrap = false;
    expect(await lock.unlock('Resume protection'), isTrue);
    for (final entry in original.entries) {
      expect(await reopened.read(key: entry.key), entry.value);
    }
    expect(await lock.configure(false, 'Disable lock'), isTrue);
  });
}
