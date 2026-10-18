import 'dart:convert';
import 'dart:io';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/onboarding/application/committed_recovery_backup.dart';
import 'package:loom_next/features/onboarding/application/recovery_backup_reminder.dart';
import 'package:loom_next/features/onboarding/application/recovery_file_export.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late LoomRecoveryBackupReminderStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('loom-reminder-test-');
    store = LoomRecoveryBackupReminderStore(directory: directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'deferral persists across store instances without identity or secrets',
    () async {
      expect(await store.defer('chn:public-identity-a'), isTrue);
      final reopened = LoomRecoveryBackupReminderStore(directory: directory);
      expect(
        await reopened.load('chn:public-identity-a'),
        LoomRecoveryBackupStatus.deferred,
      );
      final files = await directory
          .list(recursive: true)
          .where((f) => f is File)
          .cast<File>()
          .toList();
      expect(files, hasLength(1));
      expect(
        await files.single.readAsString(),
        '{"version":1,"status":"deferred"}',
      );
      expect(files.single.path, isNot(contains('public-identity-a')));
    },
  );

  test(
    'cancel and browser initiation cannot clear a deferred reminder',
    () async {
      await store.defer('identity-a');
      for (final result in [
        LoomRecoveryExportResult.cancelled,
        LoomRecoveryExportResult.downloadStarted,
      ]) {
        expect(await store.recordExport('identity-a', result), isFalse);
        expect(
          await store.load('identity-a'),
          LoomRecoveryBackupStatus.deferred,
        );
      }
    },
  );

  test(
    'a confirmed export clears only the matching identity reminder',
    () async {
      await store.defer('identity-a');
      await store.defer('identity-b');
      expect(
        await store.recordExport('identity-a', LoomRecoveryExportResult.saved),
        isTrue,
      );
      expect(await store.load('identity-a'), LoomRecoveryBackupStatus.saved);
      expect(await store.load('identity-b'), LoomRecoveryBackupStatus.deferred);
      expect(await store.load('identity-c'), isNull);
    },
  );

  test(
    'manual confirmation stays distinct from confirmed file export',
    () async {
      await store.defer('identity-a');
      expect(await store.confirmManualBackup('identity-a'), isTrue);
      expect(
        await store.load('identity-a'),
        LoomRecoveryBackupStatus.manuallyConfirmed,
      );
      await store.defer('identity-a');
      expect(
        await store.load('identity-a'),
        LoomRecoveryBackupStatus.manuallyConfirmed,
      );
    },
  );

  test(
    'revisiting setup cannot erase earlier confirmed export evidence',
    () async {
      await store.recordExport('identity-a', LoomRecoveryExportResult.saved);
      await store.defer('identity-a');
      expect(await store.load('identity-a'), LoomRecoveryBackupStatus.saved);
    },
  );

  test('write failure is reported rather than claiming persistence', () async {
    final blocker = File('${directory.path}/blocker');
    await blocker.writeAsString('not a directory');
    final blocked = LoomRecoveryBackupReminderStore(
      directory: Directory(blocker.path),
    );
    expect(await blocked.defer('identity-a'), isFalse);
    expect(await blocked.load('identity-a'), isNull);
    // A failed queued write must not poison subsequent persistence.
    expect(await store.defer('identity-a'), isTrue);
  });

  test('damaged metadata is unknown and can be repaired safely', () async {
    await store.defer('identity-a');
    final file =
        (await directory
                .list(recursive: true)
                .where((f) => f is File)
                .cast<File>()
                .toList())
            .single;
    await file.writeAsString('{broken');
    expect(await store.load('identity-a'), isNull);
    expect(await store.defer('identity-a'), isTrue);
    expect(await store.load('identity-a'), LoomRecoveryBackupStatus.deferred);
  });

  test(
    'export reads committed material and zeroes entropy without identity mutation',
    () async {
      final core = _RecoveryCore();
      core.entropy[31] = 1;
      final backup = await readCommittedLoomRecoveryBackup(
        identityCore: core,
        expectedIdentityId: 'identity-a',
      );
      expect(backup.words, hasLength(24));
      expect(backup.words.first, 'abandon');
      expect(core.entropy, everyElement(0));
      expect(core.mutations, 0);
      expect(core.reads, 2);
    },
  );

  test(
    'a changed identity aborts export and zeroes the read entropy',
    () async {
      final core = _RecoveryCore(changeIdentity: true);
      // A non-zero entropy makes zeroisation observable even on failure.
      core.entropy[0] = 73;
      await expectLater(
        readCommittedLoomRecoveryBackup(
          identityCore: core,
          expectedIdentityId: 'identity-a',
        ),
        throwsStateError,
      );
      expect(core.entropy, everyElement(0));
      expect(core.mutations, 0);
    },
  );

  test(
    'mismatched stored entropy cannot be exported as a working backup',
    () async {
      final core = _RecoveryCore(wrongPublicKey: true);
      core.entropy[0] = 73;
      await expectLater(
        readCommittedLoomRecoveryBackup(
          identityCore: core,
          expectedIdentityId: 'identity-a',
        ),
        throwsFormatException,
      );
      expect(core.entropy, everyElement(0));
      expect(core.mutations, 0);
    },
  );
}

class _RecoveryCore implements LoomIdentityCore {
  _RecoveryCore({this.changeIdentity = false, this.wrongPublicKey = false});
  final bool changeIdentity;
  final bool wrongPublicKey;
  final List<int> entropy = List<int>.filled(32, 0);
  int reads = 0;
  int mutations = 0;

  @override
  Future<LoomIdentityPublic?> readIdentity() async {
    reads++;
    final keyPair = await Ed25519().newKeyPairFromSeed(entropy);
    late final String publicKey;
    try {
      publicKey = base64Encode((await keyPair.extractPublicKey()).bytes);
    } finally {
      keyPair.destroy();
    }
    return LoomIdentityPublic(
      identityId: changeIdentity && reads > 1 ? 'identity-b' : 'identity-a',
      publicKey: wrongPublicKey ? 'incorrect-public-key' : publicKey,
      fingerprint: 'fingerprint',
      createdAt: DateTime.utc(2026),
    );
  }

  @override
  Future<List<int>> exportRecoveryEntropy() async => entropy;

  @override
  Future<void> clearIdentity() async {
    mutations++;
  }

  @override
  Future<void> commitPendingIdentity(LoomPendingIdentity pending) async {
    mutations++;
  }

  @override
  Future<LoomPendingIdentity> createIdentity() async {
    mutations++;
    throw UnimplementedError();
  }

  @override
  void discardPendingIdentity() {
    mutations++;
  }

  @override
  Future<LoomIdentityPublic> importRecoveryEntropy(List<int> entropy) async {
    mutations++;
    throw UnimplementedError();
  }

  @override
  Future<LoomPendingIdentity> restoreIdentityFromWords(
    List<String> words,
  ) async {
    mutations++;
    throw UnimplementedError();
  }

  @override
  Future<List<int>> signIdentityBinding(List<int> payload) async =>
      throw UnimplementedError();
}
