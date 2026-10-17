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

  group('crash-safe vodozemac prekey lifecycle', () {
    late LoomCryptoStateStore store;
    late LoomVodozemacPocFfiEngine engine;
    late LoomVodozemacPocSessionProvider provider;
    late LoomVodozemacPocPrekeyLifecycle lifecycle;

    final t0 = DateTime.utc(2026, 9, 5, 12);

    setUp(() {
      store = LoomCryptoStateStore.openInMemory();
      engine = LoomVodozemacPocFfiEngine.open(ffiPath!);
      provider = LoomVodozemacPocSessionProvider(
        engine: engine,
        stateProtector: const _BindingTestProtector(),
      );
      lifecycle = LoomVodozemacPocPrekeyLifecycle(
        provider: provider,
        transactionRunner: store,
        targetOneTimeKeys: 4,
      );
    });

    tearDown(() => store.close());

    test(
      'lost publication acknowledgement retries identical stable batch',
      () async {
        final publisher = _RecordingPublisher(failuresBeforeSuccess: 1);

        await expectLater(
          lifecycle.ensurePublished(publisher: publisher, now: t0),
          throwsStateError,
        );
        expect(publisher.attempts, hasLength(1));
        final first = publisher.attempts.single;
        expect(first.items, hasLength(5));
        expect(
          first.items
              .where(
                (item) => item.keyKind == LoomVodozemacPocPrekeyKind.oneTime,
              )
              .length,
          4,
        );
        expect(
          first.items
              .where(
                (item) => item.keyKind == LoomVodozemacPocPrekeyKind.fallback,
              )
              .length,
          1,
        );
        expect(
          store.readProviderState(provider.localAccountStateId)!.revision,
          1,
        );

        final retried = await lifecycle.ensurePublished(
          publisher: publisher,
          now: t0.add(const Duration(minutes: 1)),
        );
        expect(retried, isNotNull);
        expect(publisher.attempts, hasLength(2));
        final second = publisher.attempts.last;
        expect(second.batchId, first.batchId);
        expect(
          second.items.map((item) => item.prekeyId),
          orderedEquals(first.items.map((item) => item.prekeyId)),
        );
        for (var i = 0; i < first.items.length; i += 1) {
          expect(second.items[i].bundle, orderedEquals(first.items[i].bundle));
          expect(second.items[i].expiresAt, first.items[i].expiresAt);
        }
        expect(
          store.readProviderState(provider.localAccountStateId)!.revision,
          2,
        );

        final noWork = await lifecycle.ensurePublished(
          publisher: publisher,
          now: t0.add(const Duration(minutes: 2)),
        );
        expect(noWork, isNull);
        expect(publisher.attempts, hasLength(2));
      },
    );

    test(
      'consumed inbound OTK is replenished without rotating fallback',
      () async {
        final publisher = _RecordingPublisher();
        final initial = await lifecycle.ensurePublished(
          publisher: publisher,
          now: t0,
        );
        expect(initial, isNotNull);
        final claimed = initial!.items.firstWhere(
          (item) => item.keyKind == LoomVodozemacPocPrekeyKind.oneTime,
        );
        final localBundle = LoomVodozemacPocPrekeyBundle.decode(claimed.bundle);

        final remote = await engine.createAccount(oneTimeKeyCount: 1);
        final outbound = await engine.createOutboundSession(
          accountPickle: remote.accountPickle,
          remoteIdentityKey: localBundle.identityKey,
          remoteOneTimeKey: localBundle.oneTimeKey,
        );
        final encrypted = await engine.encrypt(
          sessionPickle: outbound.sessionPickle,
          plaintext: Uint8List.fromList(utf8.encode('consume-local-otk')),
        );
        final ciphertext = LoomSessionCiphertext(
          protocolVersion: LoomVodozemacPocPrekeyBundle.protocol,
          sessionLocator: outbound.sessionId,
          bytes: Uint8List.fromList(utf8.encode(jsonEncode(encrypted.message))),
        );

        await store.runDurably<void>((transaction) async {
          final opened = await provider.decryptInitialPrekey(
            transaction: transaction,
            remoteDevice: const LoomRemoteDeviceRef(
              accountId: 'remote-account',
              deviceId: 'remote-device',
              deviceKeyVersion: 1,
            ),
            verifiedRemoteIdentityKey: remote.curve25519,
            ciphertext: ciphertext,
            now: t0.add(const Duration(hours: 1)),
          );
          expect(utf8.decode(opened.plaintext), 'consume-local-otk');
        });

        final replenished = await lifecycle.ensurePublished(
          publisher: publisher,
          now: t0.add(const Duration(days: 1)),
        );
        expect(replenished, isNotNull);
        expect(replenished!.items, hasLength(1));
        expect(
          replenished.items.single.keyKind,
          LoomVodozemacPocPrekeyKind.oneTime,
        );
        expect(publisher.attempts, hasLength(2));
      },
    );

    test(
      'fallback rotates before expiry and old private fallback is retained',
      () async {
        final publisher = _RecordingPublisher();
        final initial = await lifecycle.ensurePublished(
          publisher: publisher,
          now: t0,
        );
        final firstFallback = initial!.items.singleWhere(
          (item) => item.keyKind == LoomVodozemacPocPrekeyKind.fallback,
        );

        final rotationTime = t0.add(const Duration(days: 22));
        final rotated = await lifecycle.ensurePublished(
          publisher: publisher,
          now: rotationTime,
        );
        expect(rotated, isNotNull);
        expect(rotated!.items, hasLength(1));
        final secondFallback = rotated.items.single;
        expect(secondFallback.keyKind, LoomVodozemacPocPrekeyKind.fallback);
        expect(secondFallback.prekeyId, isNot(firstFallback.prekeyId));

        final revisionAfterRotation =
            store.readProviderState(provider.localAccountStateId)!.revision;
        final afterRetention = await lifecycle.ensurePublished(
          publisher: publisher,
          now: rotationTime.add(const Duration(days: 15)),
        );
        expect(afterRetention, isNull);
        expect(
          store.readProviderState(provider.localAccountStateId)!.revision,
          revisionAfterRotation + 1,
        );
      },
    );

    test(
      'expired unacknowledged batch fails closed instead of re-keying an id',
      () async {
        final publisher = _RecordingPublisher(failuresBeforeSuccess: 1);
        await expectLater(
          lifecycle.ensurePublished(publisher: publisher, now: t0),
          throwsStateError,
        );

        await expectLater(
          lifecycle.ensurePublished(
            publisher: publisher,
            now: t0.add(const Duration(days: 29)),
          ),
          throwsA(isA<LoomCryptoStateConflict>()),
        );
        expect(publisher.attempts, hasLength(1));
      },
    );
  }, skip: ffiSkip);
}

final class _RecordingPublisher implements LoomVodozemacPocPrekeyPublisher {
  _RecordingPublisher({this.failuresBeforeSuccess = 0});

  int failuresBeforeSuccess;
  final List<LoomVodozemacPocPrekeyPublicationBatch> attempts = [];

  @override
  Future<void> publish(LoomVodozemacPocPrekeyPublicationBatch batch) async {
    attempts.add(batch);
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess -= 1;
      throw StateError('simulated lost prekey publication acknowledgement');
    }
  }
}

/// Test-only protector that checks context/revision binding. It deliberately
/// does not claim production confidentiality.
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
