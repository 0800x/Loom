import 'dart:io';
import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  final createdAt = DateTime.utc(2026, 9, 5, 12);

  test(
    'provider state and session can commit in one bootstrap transaction',
    () async {
      final store = LoomCryptoStateStore.openInMemory();
      addTearDown(store.close);

      await store.runDurably((transaction) async {
        final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
        await bootstrap.writeProviderState(
          _providerState(revision: 0, byte: 10, createdAt: createdAt),
          expectedRevision: null,
        );
        await bootstrap.writeSession(
          _session(createdAt: createdAt),
          expectedRevision: null,
        );
      });

      expect(store.readProviderState('provider-device-state-1')!.revision, 0);
      expect(
        store.readProviderState('provider-device-state-1')!.protectedState,
        <int>[10],
      );
      expect(store.readSession('session-bootstrap-1'), isNotNull);
    },
  );

  test('provider mutation and session mutation roll back together', () async {
    final store = LoomCryptoStateStore.openInMemory();
    addTearDown(store.close);
    await store.runDurably((transaction) async {
      final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
      await bootstrap.writeProviderState(
        _providerState(revision: 0, byte: 20, createdAt: createdAt),
        expectedRevision: null,
      );
      await bootstrap.writeSession(
        _session(createdAt: createdAt),
        expectedRevision: null,
      );
    });

    await expectLater(
      store.runDurably<void>((transaction) async {
        final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
        await bootstrap.writeProviderState(
          _providerState(
            revision: 1,
            byte: 21,
            createdAt: createdAt,
            updatedAt: createdAt.add(const Duration(seconds: 1)),
          ),
          expectedRevision: 0,
        );
        await bootstrap.writeSession(
          _session(
            revision: 1,
            stateByte: 31,
            createdAt: createdAt,
            updatedAt: createdAt.add(const Duration(seconds: 1)),
          ),
          expectedRevision: 0,
        );
        throw StateError('simulated crash after consuming local prekey state');
      }),
      throwsStateError,
    );

    expect(store.readProviderState('provider-device-state-1')!.revision, 0);
    expect(
      store.readProviderState('provider-device-state-1')!.protectedState,
      <int>[20],
    );
    expect(store.readSession('session-bootstrap-1')!.revision, 0);
    expect(store.readSession('session-bootstrap-1')!.protectedState, <int>[30]);
  });

  test(
    'provider state revision CAS rejects stale or skipped updates',
    () async {
      final store = LoomCryptoStateStore.openInMemory();
      addTearDown(store.close);
      await store.runDurably((transaction) async {
        final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
        await bootstrap.writeProviderState(
          _providerState(revision: 0, byte: 40, createdAt: createdAt),
          expectedRevision: null,
        );
      });

      await expectLater(
        store.runDurably<void>((transaction) async {
          final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
          await bootstrap.writeProviderState(
            _providerState(
              revision: 2,
              byte: 42,
              createdAt: createdAt,
              updatedAt: createdAt.add(const Duration(seconds: 2)),
            ),
            expectedRevision: 0,
          );
        }),
        throwsA(isA<LoomCryptoStateConflict>()),
      );
      expect(store.readProviderState('provider-device-state-1')!.revision, 0);
    },
  );

  test(
    'experimental crypto schema v1 migrates additively to provider-state v2',
    () async {
      final directory = Directory.systemTemp.createTempSync('loom-crypto-v1-');
      final path = '${directory.path}/crypto.sqlite3';
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });

      final old = sqlite3.open(path);
      old.execute('CREATE TABLE crypto_sessions(session_id TEXT PRIMARY KEY)');
      old.execute('CREATE TABLE crypto_outbox(packet_id TEXT)');
      old.execute('CREATE TABLE crypto_replay(replay_key TEXT PRIMARY KEY)');
      old.execute('PRAGMA user_version = 1');
      old.dispose();

      final store = LoomCryptoStateStore.openFile(path);
      await store.runDurably((transaction) async {
        final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
        await bootstrap.writeProviderState(
          _providerState(revision: 0, byte: 50, createdAt: createdAt),
          expectedRevision: null,
        );
      });
      expect(store.readProviderState('provider-device-state-1'), isNotNull);
      store.close();

      final migrated = sqlite3.open(path);
      expect(migrated.select('PRAGMA user_version').first.values.first, 2);
      migrated.dispose();
    },
  );
}

LoomProviderStateRecord _providerState({
  required int revision,
  required int byte,
  required DateTime createdAt,
  DateTime? updatedAt,
}) => LoomProviderStateRecord(
  stateId: 'provider-device-state-1',
  stateKind: 'vodozemac-olm-account-poc1',
  revision: revision,
  protectedState: Uint8List.fromList(<int>[byte]),
  createdAt: createdAt,
  updatedAt: updatedAt ?? createdAt,
);

LoomSessionRecord _session({
  int revision = 0,
  int stateByte = 30,
  required DateTime createdAt,
  DateTime? updatedAt,
}) => LoomSessionRecord(
  sessionId: 'session-bootstrap-1',
  remoteDevice: const LoomRemoteDeviceRef(
    accountId: 'remote-account-1',
    deviceId: 'remote-device-1',
    deviceKeyVersion: 1,
  ),
  protocolVersion: 'Loom-Session-v2-olm-poc1',
  mode: LoomCryptoSessionMode.active,
  revision: revision,
  protectedState: Uint8List.fromList(<int>[stateByte]),
  createdAt: createdAt,
  updatedAt: updatedAt ?? createdAt,
);
