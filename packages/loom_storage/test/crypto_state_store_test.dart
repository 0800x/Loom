import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  late LoomCryptoStateStore store;
  final createdAt = DateTime.utc(2026, 9, 5, 12);

  setUp(() {
    store = LoomCryptoStateStore.openInMemory();
  });

  tearDown(() {
    store.close();
  });

  test(
    'session advancement, PacketId, and exact ciphertext commit together',
    () async {
      await store.runDurably((transaction) async {
        await transaction.writeSession(
          _session(revision: 0, stateByte: 10, createdAt: createdAt),
          expectedRevision: null,
        );
      });

      final ciphertext = _outbox(
        sessionRevision: 1,
        bytes: <int>[7, 8, 9],
        createdAt: createdAt.add(const Duration(minutes: 1)),
      );

      await store.runDurably((transaction) async {
        await transaction.writeSession(
          _session(
            revision: 1,
            stateByte: 11,
            createdAt: createdAt,
            updatedAt: createdAt.add(const Duration(minutes: 1)),
          ),
          expectedRevision: 0,
        );
        await transaction.putOutbox(ciphertext);
      });

      expect(store.readSession('session-1')!.revision, 1);
      expect(store.readSession('session-1')!.protectedState, <int>[11]);
      expect(store.readOutbox('operation-1')!.packetId, 'packet-0001');
      expect(store.readOutbox('operation-1')!.ciphertext.bytes, <int>[7, 8, 9]);
    },
  );

  test(
    'rollback leaves ratchet state, PacketId, and outbox unchanged',
    () async {
      await store.runDurably((transaction) async {
        await transaction.writeSession(
          _session(revision: 0, stateByte: 20, createdAt: createdAt),
          expectedRevision: null,
        );
      });

      await expectLater(
        store.runDurably<void>((transaction) async {
          await transaction.writeSession(
            _session(
              revision: 1,
              stateByte: 21,
              createdAt: createdAt,
              updatedAt: createdAt.add(const Duration(minutes: 1)),
            ),
            expectedRevision: 0,
          );
          await transaction.putOutbox(
            _outbox(
              sessionRevision: 1,
              bytes: <int>[1, 2, 3],
              createdAt: createdAt.add(const Duration(minutes: 1)),
            ),
          );
          throw StateError('simulated crash before commit');
        }),
        throwsStateError,
      );

      expect(store.readSession('session-1')!.revision, 0);
      expect(store.readSession('session-1')!.protectedState, <int>[20]);
      expect(store.readOutbox('operation-1'), isNull);
    },
  );

  test('stale session revision fails closed', () async {
    await store.runDurably((transaction) async {
      await transaction.writeSession(
        _session(revision: 0, stateByte: 30, createdAt: createdAt),
        expectedRevision: null,
      );
    });

    await expectLater(
      store.runDurably<void>((transaction) async {
        await transaction.writeSession(
          _session(
            revision: 2,
            stateByte: 31,
            createdAt: createdAt,
            updatedAt: createdAt.add(const Duration(minutes: 1)),
          ),
          expectedRevision: 1,
        );
      }),
      throwsA(isA<LoomCryptoStateConflict>()),
    );

    expect(store.readSession('session-1')!.revision, 0);
  });

  test(
    'same operation id is idempotent only for identical packet and ciphertext',
    () async {
      final outbox = _outbox(
        sessionRevision: 0,
        bytes: <int>[40, 41],
        createdAt: createdAt,
      );

      await store.runDurably((transaction) async {
        await transaction.writeSession(
          _session(revision: 0, stateByte: 40, createdAt: createdAt),
          expectedRevision: null,
        );
        await transaction.putOutbox(outbox);
      });

      await store.runDurably((transaction) async {
        expect(
          (await transaction.readOutbox('operation-1'))!.messageId,
          'message-1',
        );
        await transaction.putOutbox(outbox);
      });

      await expectLater(
        store.runDurably<void>((transaction) async {
          await transaction.putOutbox(
            _outbox(sessionRevision: 0, bytes: <int>[99], createdAt: createdAt),
          );
        }),
        throwsA(isA<LoomCryptoStateConflict>()),
      );

      expect(store.readOutbox('operation-1')!.packetId, 'packet-0001');
      expect(store.readOutbox('operation-1')!.ciphertext.bytes, <int>[40, 41]);
    },
  );

  test('PacketId cannot be assigned to a second crypto operation', () async {
    await store.runDurably((transaction) async {
      await transaction.writeSession(
        _session(revision: 0, stateByte: 45, createdAt: createdAt),
        expectedRevision: null,
      );
      await transaction.putOutbox(
        _outbox(sessionRevision: 0, bytes: <int>[45], createdAt: createdAt),
      );
    });

    await expectLater(
      store.runDurably<void>((transaction) async {
        await transaction.putOutbox(
          _outbox(
            operationId: 'operation-2',
            messageId: 'message-2',
            packetId: 'packet-0001',
            sessionRevision: 0,
            bytes: <int>[46],
            createdAt: createdAt,
          ),
        );
      }),
      throwsA(isA<LoomCryptoStateConflict>()),
    );
  });

  test('pending outbox can be rescheduled and acknowledged without rewriting ciphertext', () async {
    final outbox = _outbox(
      sessionRevision: 0,
      bytes: <int>[50, 51],
      createdAt: createdAt,
    );
    await store.runDurably((transaction) async {
      await transaction.writeSession(
        _session(revision: 0, stateByte: 50, createdAt: createdAt),
        expectedRevision: null,
      );
      await transaction.putOutbox(outbox);
    });

    expect(store.listPendingOutbox(createdAt), hasLength(1));
    store.rescheduleOutbox(
      'operation-1',
      attemptCount: 1,
      nextAttemptAt: createdAt.add(const Duration(minutes: 5)),
    );
    expect(store.listPendingOutbox(createdAt), isEmpty);
    expect(
      store
          .listPendingOutbox(createdAt.add(const Duration(minutes: 5)))
          .single
          .attemptCount,
      1,
    );

    store.acknowledgeOutbox(
      'operation-1',
      createdAt.add(const Duration(minutes: 6)),
    );
    expect(
      store.listPendingOutbox(createdAt.add(const Duration(days: 1))),
      isEmpty,
    );
    expect(store.readOutbox('operation-1')!.packetId, 'packet-0001');
    expect(store.readOutbox('operation-1')!.ciphertext.bytes, <int>[50, 51]);
  });
}

LoomSessionRecord _session({
  required int revision,
  required int stateByte,
  required DateTime createdAt,
  DateTime? updatedAt,
}) => LoomSessionRecord(
  sessionId: 'session-1',
  remoteDevice: const LoomRemoteDeviceRef(
    accountId: 'account-1',
    deviceId: 'device-1',
    deviceKeyVersion: 1,
  ),
  protocolVersion: 'Loom-Session-v2',
  mode: LoomCryptoSessionMode.active,
  revision: revision,
  protectedState: Uint8List.fromList(<int>[stateByte]),
  createdAt: createdAt,
  updatedAt: updatedAt ?? createdAt,
);

LoomCryptoOutboxRecord _outbox({
  String operationId = 'operation-1',
  String messageId = 'message-1',
  String packetId = 'packet-0001',
  required int sessionRevision,
  required List<int> bytes,
  required DateTime createdAt,
}) => LoomCryptoOutboxRecord(
  operationId: operationId,
  sessionId: 'session-1',
  sessionRevision: sessionRevision,
  messageId: messageId,
  packetId: packetId,
  ciphertext: LoomSessionCiphertext(
    protocolVersion: 'Loom-Session-v2',
    sessionLocator: 'opaque-session-locator',
    bytes: Uint8List.fromList(bytes),
  ),
  createdAt: createdAt,
);
