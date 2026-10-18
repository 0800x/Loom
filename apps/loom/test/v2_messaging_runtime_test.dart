import 'dart:io';

import 'package:loom_identity/loom_identity.dart';
import 'package:loom_next/features/messaging/application/v2_messaging_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v2 runtime opens durable stores but blocks sends without provider', () {
    final root = Directory.systemTemp.createTempSync('loom-v2-runtime-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final runtime = LoomV2MessagingRuntime.open(
      applicationSupportPath: root.path,
    );
    addTearDown(runtime.close);

    expect(runtime.sendReadiness, LoomV2SendReadiness.blockedProviderReview);
    expect(runtime.productionSendEnabled, isFalse);
    expect(File('${root.path}/loom-crypto-v2.sqlite3').existsSync(), isTrue);
    expect(
      File('${root.path}/loom-message-state-v2.sqlite3').existsSync(),
      isTrue,
    );
    expect(
      File('${root.path}/loom-account-roots-v2.sqlite3').existsSync(),
      isTrue,
    );
    expect(
      File('${root.path}/loom-device-directory-v2.sqlite3').existsSync(),
      isTrue,
    );
    expect(File('${root.path}/loom-dtn-v2.sqlite3').existsSync(), isTrue);
  });

  test('closing v2 runtime closes all durable domains', () async {
    final root = Directory.systemTemp.createTempSync('loom-v2-close-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final runtime = LoomV2MessagingRuntime.open(
      applicationSupportPath: root.path,
    );
    runtime.close();

    expect(
      () => runtime.packetStore.read('packet-does-not-exist'),
      throwsStateError,
    );
    expect(
      () => runtime.cryptoStateStore.readSession('session-does-not-exist'),
      throwsStateError,
    );
    expect(
      () => runtime.messageStateStore.readSeenMessage('message-does-not-exist'),
      throwsStateError,
    );
    expect(
      () => runtime.deviceDirectoryStore.directoryRevision(
        'acc2_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      ),
      throwsStateError,
    );
    await expectLater(
      runtime.accountRootStore.resolveTrustedAccountRoot(
        accountId: LoomAccountId.generate(),
        accountKeyVersion: 1,
        now: DateTime.utc(2026, 9, 6),
      ),
      throwsStateError,
    );
  });
}
