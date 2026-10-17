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
  final String? skipReason = ffiPath == null || ffiPath.trim().isEmpty
      ? 'Rust provider library path is not configured'
      : null;

  test(
    'handle lifecycle retries the exact durable publication batch',
    () async {
      final store = LoomCryptoStateStore.openInMemory();
      addTearDown(store.close);
      final engine = LoomVodozemacHandleFfiEngine.open(ffiPath!);
      final provider = LoomVodozemacHandleSessionProvider(
        engine: engine,
        stateProtector: const _BindingProtector(),
      );
      final lifecycle = LoomVodozemacHandlePrekeyLifecycle(
        provider: provider,
        transactionRunner: store,
        targetOneTimeKeys: 4,
      );
      final publisher = _Publisher(failuresBeforeSuccess: 1);
      final t0 = DateTime.utc(2026, 9, 6, 8);

      await expectLater(
        lifecycle.ensurePublished(publisher: publisher, now: t0),
        throwsStateError,
      );
      expect(publisher.attempts, hasLength(1));
      final first = publisher.attempts.single;
      expect(first.items.length, 5);

      final retry = await lifecycle.ensurePublished(
        publisher: publisher,
        now: t0.add(const Duration(minutes: 1)),
      );
      expect(retry, isNotNull);
      expect(publisher.attempts, hasLength(2));
      final second = publisher.attempts.last;
      expect(second.batchId, first.batchId);
      expect(
        second.items.map((item) => item.prekeyId),
        orderedEquals(first.items.map((item) => item.prekeyId)),
      );
      for (var i = 0; i < first.items.length; i++) {
        expect(second.items[i].bundle, orderedEquals(first.items[i].bundle));
        expect(second.items[i].expiresAt, first.items[i].expiresAt);
      }

      final noWork = await lifecycle.ensurePublished(
        publisher: publisher,
        now: t0.add(const Duration(minutes: 2)),
      );
      expect(noWork, isNull);
    },
    skip: skipReason,
  );
}

final class _Publisher implements LoomVodozemacPocPrekeyPublisher {
  _Publisher({this.failuresBeforeSuccess = 0});
  int failuresBeforeSuccess;
  final List<LoomVodozemacPocPrekeyPublicationBatch> attempts = [];

  @override
  Future<void> publish(LoomVodozemacPocPrekeyPublicationBatch batch) async {
    attempts.add(batch);
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('simulated lost publication acknowledgement');
    }
  }
}

final class _BindingProtector implements LoomSessionStateProtector {
  const _BindingProtector();

  @override
  String get protectionScheme => 'handle-lifecycle-test';

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
          'bytes': base64Encode(plaintext),
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
    final decoded = jsonDecode(utf8.decode(protectedState));
    if (decoded is! Map<String, dynamic> ||
        decoded['context'] != contextId ||
        decoded['revision'] != revision ||
        decoded['bytes'] is! String) {
      throw StateError('protected-state binding mismatch');
    }
    return Uint8List.fromList(base64Decode(decoded['bytes'] as String));
  }
}
