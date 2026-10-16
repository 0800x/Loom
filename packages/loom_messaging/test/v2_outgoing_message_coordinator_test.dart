import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  late LoomCryptoStateStore store;
  late _FakeSessionProvider provider;
  late LoomV2OutgoingMessageCoordinator coordinator;
  final now = DateTime.utc(2026, 9, 5, 13);

  setUp(() async {
    store = LoomCryptoStateStore.openInMemory();
    await store.runDurably((transaction) async {
      await transaction.writeSession(
        LoomSessionRecord(
          sessionId: 'session-00000001',
          remoteDevice: const LoomRemoteDeviceRef(
            accountId: 'account-recipient-00000001',
            deviceId: 'device-recipient-00000001',
            deviceKeyVersion: 1,
          ),
          protocolVersion: 'Loom-Session-v2',
          mode: LoomCryptoSessionMode.active,
          revision: 0,
          protectedState: Uint8List.fromList(<int>[1]),
          createdAt: now,
          updatedAt: now,
        ),
        expectedRevision: null,
      );
    });
    provider = _FakeSessionProvider();
    coordinator = LoomV2OutgoingMessageCoordinator(
      transactionRunner: store,
      sessionProvider: provider,
    );
  });

  tearDown(() {
    store.close();
  });

  test(
    'text encryption advances session and commits exact outbox before return',
    () async {
      final intent = _intent(now, plaintext: '  keep this whitespace  ');

      final committed = await coordinator.encryptAndCommitText(intent);

      expect(provider.encryptCalls, 1);
      expect(store.readSession(intent.sessionId)!.revision, 1);
      final persisted = store.readOutbox(intent.operationId)!;
      expect(persisted.packetId, intent.packetId);
      expect(persisted.ciphertext.bytes, committed.ciphertext.bytes);

      final inner = LoomEnvelopeV2Codec.decodeInner(committed.ciphertext.bytes);
      expect(utf8.decode(inner.contentPayload), '  keep this whitespace  ');
      expect(inner.messageId, intent.messageId);
      expect(inner.recipientDeviceId, intent.recipientDeviceId);
    },
  );

  test(
    'retry after commit returns existing ciphertext without advancing again',
    () async {
      final intent = _intent(now, plaintext: 'hello once');

      final first = await coordinator.encryptAndCommitText(intent);
      final second = await coordinator.encryptAndCommitText(intent);

      expect(provider.encryptCalls, 1);
      expect(store.readSession(intent.sessionId)!.revision, 1);
      expect(second.sessionRevision, first.sessionRevision);
      expect(second.ciphertext.bytes, first.ciphertext.bytes);
    },
  );

  test(
    'reusing operation id with different packet identity fails closed',
    () async {
      final intent = _intent(now, plaintext: 'immutable intent');
      await coordinator.encryptAndCommitText(intent);

      final conflicting = LoomV2TextIntent(
        sessionId: intent.sessionId,
        operationId: intent.operationId,
        messageId: intent.messageId,
        packetId: 'packet-999999999999',
        conversationRef: intent.conversationRef,
        senderAccountId: intent.senderAccountId,
        senderDeviceId: intent.senderDeviceId,
        recipientAccountId: intent.recipientAccountId,
        recipientDeviceId: intent.recipientDeviceId,
        plaintext: intent.plaintext,
        createdAt: intent.createdAt,
      );

      await expectLater(
        coordinator.encryptAndCommitText(conflicting),
        throwsA(isA<LoomCryptoStateConflict>()),
      );
      expect(provider.encryptCalls, 1);
      expect(store.readSession(intent.sessionId)!.revision, 1);
    },
  );

  test(
    'provider result without exact outbox staging rolls back session state',
    () async {
      provider.omitOutbox = true;
      final intent = _intent(now, plaintext: 'must rollback');

      await expectLater(
        coordinator.encryptAndCommitText(intent),
        throwsA(isA<LoomCryptoStateConflict>()),
      );

      expect(provider.encryptCalls, 1);
      expect(store.readSession(intent.sessionId)!.revision, 0);
      expect(store.readOutbox(intent.operationId), isNull);
    },
  );
}

LoomV2TextIntent _intent(DateTime now, {required String plaintext}) =>
    LoomV2TextIntent(
      sessionId: 'session-00000001',
      operationId: 'operation-00000001',
      messageId: 'message-00000001',
      packetId: 'packet-000000000001',
      conversationRef: 'conversation-00000001',
      senderAccountId: 'account-sender-00000001',
      senderDeviceId: 'device-sender-00000001',
      recipientAccountId: 'account-recipient-00000001',
      recipientDeviceId: 'device-recipient-00000001',
      plaintext: plaintext,
      createdAt: now,
    );

final class _FakeSessionProvider implements LoomSessionCryptoProvider {
  int encryptCalls = 0;
  bool omitOutbox = false;

  @override
  String get protocolVersion => 'Loom-Session-v2';

  @override
  Future<LoomCryptoOutboxRecord> encryptAndStage({
    required LoomCryptoTransaction transaction,
    required String sessionId,
    required String operationId,
    required String messageId,
    required String packetId,
    required Uint8List innerEnvelope,
    required DateTime now,
  }) async {
    encryptCalls++;
    final current = await transaction.readSession(sessionId);
    if (current == null) throw StateError('missing fake test session');
    final next = LoomSessionRecord(
      sessionId: current.sessionId,
      remoteDevice: current.remoteDevice,
      protocolVersion: current.protocolVersion,
      mode: current.mode,
      revision: current.revision + 1,
      protectedState: Uint8List.fromList(<int>[current.revision + 2]),
      createdAt: current.createdAt,
      updatedAt: now,
    );
    await transaction.writeSession(next, expectedRevision: current.revision);

    final record = LoomCryptoOutboxRecord(
      operationId: operationId,
      sessionId: sessionId,
      sessionRevision: next.revision,
      messageId: messageId,
      packetId: packetId,
      ciphertext: LoomSessionCiphertext(
        protocolVersion: protocolVersion,
        sessionLocator: 'opaque-session-locator',
        bytes: Uint8List.fromList(innerEnvelope),
      ),
      createdAt: now,
    );
    if (!omitOutbox) await transaction.putOutbox(record);
    return record;
  }

  @override
  Future<Uint8List> decryptAndAdvance({
    required LoomCryptoTransaction transaction,
    required LoomSessionCiphertext ciphertext,
    required DateTime now,
  }) {
    throw UnimplementedError('not used by outgoing coordinator tests');
  }

  @override
  Future<String> establishOutgoing({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
    required Uint8List verifiedPrekeyBundle,
  }) {
    throw UnimplementedError('not used by outgoing coordinator tests');
  }

  @override
  Future<void> markRemoteDeviceRevoked({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
  }) {
    throw UnimplementedError('not used by outgoing coordinator tests');
  }
}
