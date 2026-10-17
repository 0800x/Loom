import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Interactive device test: use an Android 11+ test device with a PIN and/or
// strong biometric enrolled. No native, storage or lifecycle mocks are used.
// Instructions: docs/app-lock-android-investigation.md.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real App Lock enable, background, unlock and disable', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    final lock = LoomAppLock.instance;
    final storage = LoomSecretStorage();
    const key = 'loom.test.app_lock.roundtrip';
    const value = 'synthetic credential / فارسی / 🔐';
    final instructions = ValueNotifier('Authenticate each OS prompt.');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<String>(
              valueListenable: instructions,
              builder: (_, text, _) => Text(text, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
    await lock.initialize();
    expect(lock.available, isTrue, reason: 'Enroll a device PIN first.');
    expect(
      lock.enabled,
      isFalse,
      reason: 'Use a fresh disposable app install.',
    );

    await storage.write(key: key, value: value);
    expect(await storage.read(key: key), value);
    expect(await lock.configure(true, 'Test: enable App Lock'), isTrue);
    expect(lock.locked, isFalse);
    expect(await storage.read(key: key), value);

    // This crosses the actual Flutter engine. Before the fix, the same
    // immutable response caused _open()'s cleanup to throw after decryption.
    const channel = MethodChannel('loom/app_lock');
    final wrapped = await channel.invokeMethod<Uint8List>('wrap', {
      'key': key,
      'value': Uint8List.fromList(utf8.encode(value)),
    });
    final opened = await channel.invokeMethod<Uint8List>('unwrap', {
      'key': key,
      'value': wrapped!,
    });
    expect(utf8.decode(opened!), value);
    expect(() => opened.fillRange(0, opened.length, 0), throwsUnsupportedError);

    // Real onStop/onResume, not binding.handleAppLifecycleStateChanged().
    // A pause alone is insufficient: wait for Android's stopped/paused state.
    final returned = Completer<void>();
    var backgrounded = false;
    final listener = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.paused) backgrounded = true;
        if (backgrounded && state == AppLifecycleState.resumed) {
          if (!returned.isCompleted) returned.complete();
        }
      },
    );
    instructions.value = 'Press Home, wait 2 seconds, then return to Loom.';
    await tester.pump();
    try {
      await returned.future.timeout(const Duration(seconds: 90));
    } finally {
      listener.dispose();
    }
    await lock.refreshStatus();
    expect(lock.locked, isTrue, reason: 'onStop must revoke the native key.');
    await expectLater(storage.read(key: key), throwsStateError);

    instructions.value =
        'CANCEL the next prompt. Authenticate the one after it.';
    await tester.pump();
    expect(await lock.unlock('Test: CANCEL this prompt'), isFalse);
    expect(lock.locked, isTrue);
    expect(await lock.unlock('Test: unlock App Lock'), isTrue);
    expect(await storage.read(key: key), value);
    await storage.write(key: key, value: '$value updated');
    expect(await storage.read(key: key), '$value updated');
    expect(await lock.configure(false, 'Test: disable App Lock'), isTrue);
    expect(lock.enabled, isFalse);
    expect(await storage.read(key: key), '$value updated');
    await storage.delete(key: key);
    instructions.value =
        'PASS: enable, immutable response, Home, unlock, disable.';
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    instructions.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
