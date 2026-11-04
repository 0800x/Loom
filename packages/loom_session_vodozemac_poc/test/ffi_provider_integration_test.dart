import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:loom_session_vodozemac_poc/loom_session_vodozemac_poc.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  final ffiPath =
      Platform.environment[LoomVodozemacPocFfiEngine.environmentVariable];
  final String? ffiSkip = ffiPath == null || ffiPath.trim().isEmpty
      ? 'Rust PoC library path is not configured'
      : null;

  group('Rust FFI engine', () {
    test(
      'reports the pinned engine and performs asynchronous round trip',
      () async {
        final engine = LoomVodozemacPocFfiEngine.open(ffiPath!);
        final version = await engine.version();
        expect(version.abi, 1);
        expect(version.engine, 'vodozemac');
        expect(version.version, '0.10.0');

        final alice = await engine.createAccount(oneTimeKeyCount: 1);
        final bob = await engine.createAccount(oneTimeKeyCount: 1);
        final outbound = await engine.createOutboundSession(
          accountPickle: alice.accountPickle,
          remoteIdentityKey: bob.curve25519,
          remoteOneTimeKey: bob.oneTimeKeys.single,
        );
        final encrypted = await engine.encrypt(
          sessionPickle: outbound.sessionPickle,
          plaintext: Uint8List.fromList(utf8.encode('ffi-round-trip')),
        );
        final inbound = await engine.createInboundSession(
          accountPickle: bob.accountPickle,
          remoteIdentityKey: alice.curve25519,
          message: encrypted.message,
        );
        expect(inbound.sessionId, outbound.sessionId);
        expect(utf8.decode(inbound.plaintext), 'ffi-round-trip');

        final reply = await engine.encrypt(
          sessionPickle: inbound.sessionPickle,
          plaintext: Uint8List.fromList(utf8.encode('reply')),
        );
        final opened = await engine.decrypt(
          sessionPickle: encrypted.sessionPickle,
          message: reply.message,
        );
        expect(utf8.decode(opened.plaintext), 'reply');
      },
    );
  }, skip: ffiSkip);

  group('Loom provider composition', () {
    late LoomCryptoStateStore aliceStore;
    late LoomCryptoStateStore bobStore;
    late LoomVodozemacPocSessionProvider aliceProvider;
    late LoomVodozemacPocSessionProvider bobProvider;
    late LoomVodozemacPocPrekeyBundle aliceBundle;
    late LoomVodozemacPocPrekeyBundle bobBundle;

    const aliceDevice = LoomRemoteDeviceRef(
      accountId: 'alice-account',
      deviceId: 'alice-device',
      deviceKeyVersion: 1,
    );
    const bobDevice = LoomRemoteDeviceRef(
      accountId: 'bob-account',
      deviceId: 'bob-device',
      deviceKeyVersion: 1,
    );
    final t0 = DateTime.utc(2026, 9, 5, 12);

    setUp(() async {
      final engine = LoomVodozemacPocFfiEngine.open(ffiPath!);
      aliceStore = LoomCryptoStateStore.openInMemory();
      bobStore = LoomCryptoStateStore.openInMemory();
      aliceProvider = LoomVodozemacPocSessionProvider(
        engine: engine,
        stateProtector: const _BindingTestProtector(),
      );
      bobProvider = LoomVodozemacPocSessionProvider(
        engine: engine,
        stateProtector: const _BindingTestProtector(),
      );

      aliceBundle = await aliceStore.runDurably(
        (transaction) => aliceProvider.createLocalPrekeyBundle(
          transaction: transaction,
          now: t0,
          oneTimeKeyCount: 4,
        ),
      );
      bobBundle = await bobStore.runDurably(
        (transaction) => bobProvider.createLocalPrekeyBundle(
          transaction: transaction,
          now: t0,
          oneTimeKeyCount: 4,
        ),
      );
      await aliceStore.runDurably(
        (transaction) => aliceProvider.markLocalPrekeysPublished(
          transaction: transaction,
          now: t0.add(const Duration(seconds: 1)),
        ),
      );
      await bobStore.runDurably(
        (transaction) => bobProvider.markLocalPrekeysPublished(
          transaction: transaction,
          now: t0.add(const Duration(seconds: 1)),
        ),
      );
    });

    tearDown(() {
      aliceStore.close();
      bobStore.close();
    });

    test(
      'crash rolls back consumed prekey/session and retry succeeds',
      () async {
        final sessionId = await aliceStore.runDurably(
          (transaction) => aliceProvider.establishOutgoing(
            transaction: transaction,
            remoteDevice: bobDevice,
            verifiedPrekeyBundle: bobBundle.encode(),
          ),
        );

        final first = await aliceStore.runDurably(
          (transaction) => aliceProvider.encryptAndStage(
            transaction: transaction,
            sessionId: sessionId,
            operationId: 'operation-alice-0001',
            messageId: 'message-alice-0001',
            packetId: 'packet-alice-0001',
            innerEnvelope: Uint8List.fromList(utf8.encode('first-message')),
            now: t0.add(const Duration(minutes: 1)),
          ),
        );

        final aliceRevisionAfterCommit = aliceStore
            .readSession(sessionId)!
            .revision;
        final retried = await aliceStore.runDurably(
          (transaction) => aliceProvider.encryptAndStage(
            transaction: transaction,
            sessionId: sessionId,
            operationId: 'operation-alice-0001',
            messageId: 'message-alice-0001',
            packetId: 'packet-alice-0001',
            innerEnvelope: Uint8List.fromList(utf8.encode('ignored-on-retry')),
            now: t0.add(const Duration(minutes: 2)),
          ),
        );
        expect(retried.ciphertext.bytes, orderedEquals(first.ciphertext.bytes));
        expect(retried.packetId, first.packetId);
        expect(
          aliceStore.readSession(sessionId)!.revision,
          aliceRevisionAfterCommit,
        );

        final bobAccountBefore = bobStore
            .readProviderState('vodozemac-poc-account-v1')!
            .revision;
        await expectLater(
          bobStore.runDurably<void>((transaction) async {
            final opened = await bobProvider.decryptInitialPrekey(
              transaction: transaction,
              remoteDevice: aliceDevice,
              verifiedRemoteIdentityKey: aliceBundle.identityKey,
              ciphertext: first.ciphertext,
              now: t0.add(const Duration(minutes: 3)),
            );
            expect(utf8.decode(opened.plaintext), 'first-message');
            throw StateError('simulated process crash before SQLite commit');
          }),
          throwsStateError,
        );

        expect(bobStore.readSession(sessionId), isNull);
        expect(
          bobStore.readProviderState('vodozemac-poc-account-v1')!.revision,
          bobAccountBefore,
        );

        final opened = await bobStore.runDurably(
          (transaction) => bobProvider.decryptInitialPrekey(
            transaction: transaction,
            remoteDevice: aliceDevice,
            verifiedRemoteIdentityKey: aliceBundle.identityKey,
            ciphertext: first.ciphertext,
            now: t0.add(const Duration(minutes: 4)),
          ),
        );
        expect(opened.sessionId, sessionId);
        expect(utf8.decode(opened.plaintext), 'first-message');
        expect(bobStore.readSession(sessionId), isNotNull);
        expect(
          bobStore.readProviderState('vodozemac-poc-account-v1')!.revision,
          bobAccountBefore + 1,
        );
      },
    );

    test(
      'reply completes ratchet and delayed messages decrypt out of order',
      () async {
        final sessionId = await aliceStore.runDurably(
          (transaction) => aliceProvider.establishOutgoing(
            transaction: transaction,
            remoteDevice: bobDevice,
            verifiedPrekeyBundle: bobBundle.encode(),
          ),
        );
        final first = await _stage(
          store: aliceStore,
          provider: aliceProvider,
          sessionId: sessionId,
          operation: 'operation-a-first',
          message: 'message-a-first',
          packet: 'packet-a-first',
          text: 'hello-bob',
          now: t0.add(const Duration(minutes: 1)),
        );
        await bobStore.runDurably(
          (transaction) => bobProvider.decryptInitialPrekey(
            transaction: transaction,
            remoteDevice: aliceDevice,
            verifiedRemoteIdentityKey: aliceBundle.identityKey,
            ciphertext: first.ciphertext,
            now: t0.add(const Duration(minutes: 2)),
          ),
        );

        final reply = await _stage(
          store: bobStore,
          provider: bobProvider,
          sessionId: sessionId,
          operation: 'operation-b-reply',
          message: 'message-b-reply',
          packet: 'packet-b-reply',
          text: 'hello-alice',
          now: t0.add(const Duration(minutes: 3)),
        );
        final openedReply = await aliceStore.runDurably(
          (transaction) => aliceProvider.decryptAndAdvance(
            transaction: transaction,
            ciphertext: reply.ciphertext,
            now: t0.add(const Duration(minutes: 4)),
          ),
        );
        expect(utf8.decode(openedReply), 'hello-alice');

        final m12 = await _stage(
          store: aliceStore,
          provider: aliceProvider,
          sessionId: sessionId,
          operation: 'operation-a-0012',
          message: 'message-a-0012',
          packet: 'packet-a-0012',
          text: 'message-12',
          now: t0.add(const Duration(minutes: 5)),
        );
        final m13 = await _stage(
          store: aliceStore,
          provider: aliceProvider,
          sessionId: sessionId,
          operation: 'operation-a-0013',
          message: 'message-a-0013',
          packet: 'packet-a-0013',
          text: 'message-13',
          now: t0.add(const Duration(minutes: 6)),
        );
        final m14 = await _stage(
          store: aliceStore,
          provider: aliceProvider,
          sessionId: sessionId,
          operation: 'operation-a-0014',
          message: 'message-a-0014',
          packet: 'packet-a-0014',
          text: 'message-14',
          now: t0.add(const Duration(minutes: 7)),
        );

        expect(
          utf8.decode(await _open(bobStore, bobProvider, m14, t0, 8)),
          'message-14',
        );
        expect(
          utf8.decode(await _open(bobStore, bobProvider, m12, t0, 9)),
          'message-12',
        );
        expect(
          utf8.decode(await _open(bobStore, bobProvider, m13, t0, 10)),
          'message-13',
        );

        final beforeReplay = bobStore.readSession(sessionId)!.revision;
        await expectLater(
          bobStore.runDurably(
            (transaction) => bobProvider.decryptAndAdvance(
              transaction: transaction,
              ciphertext: m13.ciphertext,
              now: t0.add(const Duration(minutes: 11)),
            ),
          ),
          throwsA(isA<LoomCryptoStateConflict>()),
        );
        expect(bobStore.readSession(sessionId)!.revision, beforeReplay);
      },
    );

    test(
      'revocation blocks new sends while delayed inbound traffic still opens',
      () async {
        final sessionId = await aliceStore.runDurably(
          (transaction) => aliceProvider.establishOutgoing(
            transaction: transaction,
            remoteDevice: bobDevice,
            verifiedPrekeyBundle: bobBundle.encode(),
          ),
        );
        final first = await _stage(
          store: aliceStore,
          provider: aliceProvider,
          sessionId: sessionId,
          operation: 'operation-revoke-first',
          message: 'message-revoke-first',
          packet: 'packet-revoke-first',
          text: 'establish-before-revoke',
          now: t0.add(const Duration(minutes: 1)),
        );
        await bobStore.runDurably(
          (transaction) => bobProvider.decryptInitialPrekey(
            transaction: transaction,
            remoteDevice: aliceDevice,
            verifiedRemoteIdentityKey: aliceBundle.identityKey,
            ciphertext: first.ciphertext,
            now: t0.add(const Duration(minutes: 2)),
          ),
        );

        // Produce a valid message before revocation but deliver it only afterward,
        // modeling DTN traffic already in flight.
        final delayed = await _stage(
          store: bobStore,
          provider: bobProvider,
          sessionId: sessionId,
          operation: 'operation-delayed-after-revoke',
          message: 'message-delayed-after-revoke',
          packet: 'packet-delayed-after-revoke',
          text: 'already-in-flight',
          now: t0.add(const Duration(minutes: 3)),
        );

        await aliceStore.runDurably(
          (transaction) => aliceProvider.markRemoteDeviceRevoked(
            transaction: transaction,
            remoteDevice: bobDevice,
          ),
        );

        await expectLater(
          aliceStore.runDurably(
            (transaction) => aliceProvider.encryptAndStage(
              transaction: transaction,
              sessionId: sessionId,
              operationId: 'operation-must-not-send',
              messageId: 'message-must-not-send',
              packetId: 'packet-must-not-send',
              innerEnvelope: Uint8List.fromList(utf8.encode('blocked')),
              now: t0.add(const Duration(minutes: 4)),
            ),
          ),
          throwsA(isA<LoomCryptoStateConflict>()),
        );
        expect(aliceStore.readOutbox('operation-must-not-send'), isNull);

        await expectLater(
          aliceStore.runDurably(
            (transaction) => aliceProvider.establishOutgoing(
              transaction: transaction,
              remoteDevice: bobDevice,
              verifiedPrekeyBundle: bobBundle.encode(),
            ),
          ),
          throwsA(isA<LoomCryptoStateConflict>()),
        );

        final opened = await aliceStore.runDurably(
          (transaction) => aliceProvider.decryptAndAdvance(
            transaction: transaction,
            ciphertext: delayed.ciphertext,
            now: t0.add(const Duration(minutes: 5)),
          ),
        );
        expect(utf8.decode(opened), 'already-in-flight');
      },
    );
  }, skip: ffiSkip);
}

Future<LoomCryptoOutboxRecord> _stage({
  required LoomCryptoStateStore store,
  required LoomVodozemacPocSessionProvider provider,
  required String sessionId,
  required String operation,
  required String message,
  required String packet,
  required String text,
  required DateTime now,
}) => store.runDurably(
  (transaction) => provider.encryptAndStage(
    transaction: transaction,
    sessionId: sessionId,
    operationId: operation,
    messageId: message,
    packetId: packet,
    innerEnvelope: Uint8List.fromList(utf8.encode(text)),
    now: now,
  ),
);

Future<Uint8List> _open(
  LoomCryptoStateStore store,
  LoomVodozemacPocSessionProvider provider,
  LoomCryptoOutboxRecord record,
  DateTime origin,
  int minute,
) => store.runDurably(
  (transaction) => provider.decryptAndAdvance(
    transaction: transaction,
    ciphertext: record.ciphertext,
    now: origin.add(Duration(minutes: minute)),
  ),
);

/// Test-only protector that authenticates the context/revision binding without
/// pretending to provide production confidentiality.
final class _BindingTestProtector implements LoomSessionStateProtector {
  const _BindingTestProtector();

  @override
  String get protectionScheme => 'binding-test-only';

  @override
  Future<Uint8List> protect({
    required String contextId,
    required int revision,
    required Uint8List plaintext,
  }) async {
    validateLoomStateProtectionContext(
      contextId: contextId,
      revision: revision,
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'context': contextId,
          'revision': revision,
          'plaintext': base64Encode(plaintext),
        }),
      ),
    );
  }

  @override
  Future<Uint8List> unprotect({
    required String contextId,
    required int revision,
    required Uint8List protectedState,
  }) async {
    validateLoomStateProtectionContext(
      contextId: contextId,
      revision: revision,
    );
    final decoded = jsonDecode(utf8.decode(protectedState));
    if (decoded is! Map<String, dynamic> ||
        decoded['context'] != contextId ||
        decoded['revision'] != revision ||
        decoded['plaintext'] is! String) {
      throw StateError('Protected state context/revision mismatch');
    }
    return Uint8List.fromList(base64Decode(decoded['plaintext'] as String));
  }
}
