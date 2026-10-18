import 'dart:async';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  test('definitive HTTP rejection stops alternate routes', () async {
    final first = _FakeMessagingApi(
      sendError: const LoomHttpStatusException(
        statusCode: 403,
        message: 'device revoked',
      ),
    );
    final second = _FakeMessagingApi(receipt: _receipt());
    final routed = _routed(first, second);

    await expectLater(
      routed.sendOpaqueMessage(
        conversationId: 'conversation-0001',
        clientId: 'client-message-0001',
        type: LoomMessageType.text,
        ciphertext: 'opaque',
        protocolVersion: 'test-v1',
      ),
      throwsA(
        isA<LoomHttpStatusException>().having(
          (error) => error.statusCode,
          'statusCode',
          403,
        ),
      ),
    );
    expect(first.sendCalls, 1);
    expect(second.sendCalls, 0);
  });

  test('retryable server failure can use another verified route', () async {
    final first = _FakeMessagingApi(
      sendError: const LoomHttpStatusException(
        statusCode: 503,
        message: 'temporarily unavailable',
      ),
    );
    final receipt = _receipt();
    final second = _FakeMessagingApi(receipt: receipt);
    final routed = _routed(first, second);

    final actual = await routed.sendOpaqueMessage(
      conversationId: 'conversation-0001',
      clientId: 'client-message-0001',
      type: LoomMessageType.text,
      ciphertext: 'opaque',
      protocolVersion: 'test-v1',
    );

    expect(actual.messageId, receipt.messageId);
    expect(first.sendCalls, 1);
    expect(second.sendCalls, 1);
  });

  test(
    'no verified route has an explicit transport-unavailable error',
    () async {
      final routed = LoomRoutedMessagingApi(
        homeNodeId: 'node:home',
        routes: const <LoomMessagingRoute>[],
      );

      await expectLater(
        routed.sendOpaqueMessage(
          conversationId: 'conversation-0001',
          clientId: 'client-message-0001',
          type: LoomMessageType.text,
          ciphertext: 'opaque',
          protocolVersion: 'test-v1',
        ),
        throwsA(isA<LoomMessagingTransportUnavailable>()),
      );
    },
  );

  test(
    'stalled LAN leaves budget for HTTPS and is cooled down for the next send',
    () async {
      final stalled = _NeverCompletesMessagingApi();
      final home = _FakeMessagingApi(receipt: _receipt());
      final routed = LoomRoutedMessagingApi(
        homeNodeId: 'node:home',
        routes: [
          _route(
            id: 'lan',
            kind: LoomRouteKind.localNetwork,
            endpoint: 'http://192.168.1.10:8080',
            api: stalled,
          ),
          _route(
            id: 'home',
            kind: LoomRouteKind.homeNode,
            endpoint: 'https://node.example',
            api: home,
          ),
        ],
        sendAttemptBudget: const Duration(seconds: 2),
        lanFallbackBudget: const Duration(milliseconds: 30),
      );
      final receipt = await _send(routed);
      expect(receipt.messageId, _receipt().messageId);
      expect(stalled.abortCalls, 1);
      expect(home.sendCalls, 1);
      await _send(routed);
      expect(stalled.abortCalls, 1);
      expect(home.sendCalls, 2);
      expect(routed.activeRouteId, 'home');
    },
  );

  test(
      'a retryable failure is not retried ahead of a healthy route on every message',
      () async {
    final failed = _FakeMessagingApi(
      sendError: const SocketException('offline LAN'),
    );
    final home = _FakeMessagingApi(receipt: _receipt());
    final routed = _routed(failed, home);
    await _send(routed);
    await _send(routed);
    expect(failed.sendCalls, 1);
    expect(home.sendCalls, 2);
  });

  test(
    'Test B - generation change discards stale LAN and refreshes routes',
    () async {
      final staleLan = _FakeMessagingApi(receipt: _receipt());
      final refreshedLan = _FakeMessagingApi(receipt: _receipt());
      final home = _FakeMessagingApi(receipt: _receipt());
      var refreshCalls = 0;

      Future<List<LoomMessagingRoute>> refresh() async {
        refreshCalls++;
        return <LoomMessagingRoute>[
          _route(
            id: 'lan-b',
            kind: LoomRouteKind.localNetwork,
            endpoint: 'http://192.168.2.10:8080',
            api: refreshedLan,
            latency: const Duration(milliseconds: 1),
          ),
          _route(
            id: 'home',
            kind: LoomRouteKind.homeNode,
            endpoint: 'https://node.example',
            api: home,
            refresh: refresh,
            latency: const Duration(milliseconds: 20),
          ),
        ];
      }

      final routed = LoomRoutedMessagingApi(
        homeNodeId: 'node:home',
        routes: <LoomMessagingRoute>[
          _route(
            id: 'lan-a',
            kind: LoomRouteKind.localNetwork,
            endpoint: 'http://192.168.1.10:8080',
            api: staleLan,
            latency: const Duration(milliseconds: 1),
          ),
          _route(
            id: 'home',
            kind: LoomRouteKind.homeNode,
            endpoint: 'https://node.example',
            api: home,
            refresh: refresh,
            latency: const Duration(milliseconds: 20),
          ),
        ],
        sendAttemptBudget: const Duration(milliseconds: 250),
      );

      LoomDefaultNetworkGeneration.advance(
        transportClass: 'wifi',
        validated: true,
      );
      final receipt = await _send(routed);

      expect(receipt.clientId, 'client-message-0001');
      expect(refreshCalls, 1);
      expect(staleLan.sendCalls, 0);
      expect(refreshedLan.sendCalls, 1);
      expect(home.sendCalls, 0);
    },
  );

  test('Test C - false-online route is aborted by whole-send budget', () async {
    final stalled = _NeverCompletesMessagingApi();
    final routed = LoomRoutedMessagingApi(
      homeNodeId: 'node:home',
      routes: <LoomMessagingRoute>[
        _route(
          id: 'home',
          kind: LoomRouteKind.homeNode,
          endpoint: 'https://node.example',
          api: stalled,
        ),
      ],
      sendAttemptBudget: const Duration(milliseconds: 40),
    );
    final clock = Stopwatch()..start();

    await expectLater(_send(routed), throwsA(isA<TimeoutException>()));

    expect(stalled.abortCalls, 1);
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test(
    'Test A - obsolete generation cannot keep an active send alive',
    () async {
      final stale = _GenerationStallingMessagingApi();
      final fresh = _FakeMessagingApi(receipt: _receipt());
      var refreshCalls = 0;

      Future<List<LoomMessagingRoute>> refresh() async {
        refreshCalls++;
        return <LoomMessagingRoute>[
          _route(
            id: 'home',
            kind: LoomRouteKind.homeNode,
            endpoint: 'https://node.example',
            api: fresh,
            refresh: refresh,
          ),
        ];
      }

      final routed = LoomRoutedMessagingApi(
        homeNodeId: 'node:home',
        routes: <LoomMessagingRoute>[
          _route(
            id: 'lan-a',
            kind: LoomRouteKind.localNetwork,
            endpoint: 'http://192.168.1.10:8080',
            api: stale,
            latency: const Duration(milliseconds: 1),
          ),
          _route(
            id: 'home',
            kind: LoomRouteKind.homeNode,
            endpoint: 'https://node.example',
            api: _FakeMessagingApi(sendError: const SocketException('offline')),
            refresh: refresh,
            latency: const Duration(milliseconds: 20),
          ),
        ],
        sendAttemptBudget: const Duration(milliseconds: 500),
      );

      final pending = _send(routed);
      await stale.started.future;
      LoomDefaultNetworkGeneration.advance(
        transportClass: 'cellular',
        validated: true,
      );

      final receipt = await pending;
      expect(receipt.clientId, 'client-message-0001');
      expect(stale.cancelledByGeneration, isTrue);
      expect(refreshCalls, 1);
      expect(fresh.sendCalls, 1);
    },
  );
}

Future<LoomSendReceipt> _send(LoomMessagingApi api) => api.sendOpaqueMessage(
      conversationId: 'conversation-0001',
      clientId: 'client-message-0001',
      type: LoomMessageType.text,
      ciphertext: 'opaque',
      protocolVersion: 'test-v1',
    );

LoomMessagingRoute _route({
  required String id,
  required LoomRouteKind kind,
  required String endpoint,
  required LoomMessagingApi api,
  Duration latency = const Duration(milliseconds: 10),
  LoomMessagingRoutesRefresher? refresh,
}) =>
    LoomMessagingRoute(
      candidate: LoomRouteCandidate(
        id: id,
        kind: kind,
        nodeId: 'node:home',
        endpoint: Uri.parse(endpoint),
        identityVerified: true,
        latency: latency,
      ),
      api: api,
      refreshOnNetworkChange: refresh,
    );

LoomRoutedMessagingApi _routed(
  LoomMessagingApi first,
  LoomMessagingApi second,
) =>
    LoomRoutedMessagingApi(
      homeNodeId: 'node:home',
      routes: <LoomMessagingRoute>[
        _route(
          id: 'lan',
          kind: LoomRouteKind.localNetwork,
          endpoint: 'http://192.168.1.10:8080',
          api: first,
          latency: const Duration(milliseconds: 2),
        ),
        _route(
          id: 'internet',
          kind: LoomRouteKind.homeNode,
          endpoint: 'https://node.example',
          api: second,
          latency: const Duration(milliseconds: 20),
        ),
      ],
    );

LoomSendReceipt _receipt() => LoomSendReceipt(
      messageId: 'server-message-0001',
      clientId: 'client-message-0001',
      serverOrder: 42,
      createdAt: DateTime.utc(2026, 9, 12, 12),
    );

class _FakeMessagingApi implements LoomMessagingApi {
  _FakeMessagingApi({this.sendError, this.receipt});

  final Object? sendError;
  final LoomSendReceipt? receipt;
  int sendCalls = 0;

  @override
  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    sendCalls++;
    final error = sendError;
    if (error != null) throw error;
    return receipt!;
  }

  @override
  Future<List<LoomConversation>> fetchConversations() =>
      throw UnimplementedError();

  @override
  Future<LoomSyncPage> sync({String? cursor, int limit = 200}) =>
      throw UnimplementedError();

  @override
  Future<void> markRead({
    required String conversationId,
    required int throughOrder,
  }) =>
      throw UnimplementedError();

  @override
  Future<LoomAttachmentReceipt> uploadEncryptedAttachment({
    required String conversationId,
    required File encryptedFile,
    required String contentType,
  }) =>
      throw UnimplementedError();
}

final class _NeverCompletesMessagingApi extends _FakeMessagingApi
    implements LoomAbortableTransport {
  _NeverCompletesMessagingApi();

  final Completer<LoomSendReceipt> _pending = Completer<LoomSendReceipt>();
  int abortCalls = 0;

  @override
  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) =>
      _pending.future;

  @override
  void abortActiveTransport(String category) {
    abortCalls++;
    if (!_pending.isCompleted) {
      _pending.completeError(const SocketException('aborted'));
    }
  }
}

final class _GenerationStallingMessagingApi extends _FakeMessagingApi
    implements LoomAbortableTransport {
  _GenerationStallingMessagingApi();

  final Completer<void> started = Completer<void>();
  bool cancelledByGeneration = false;
  StreamSubscription<LoomDefaultNetworkSnapshot>? _subscription;
  Completer<LoomSendReceipt>? _pending;

  @override
  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final generation = LoomDefaultNetworkGeneration.current.generation;
    final pending = _pending = Completer<LoomSendReceipt>();
    if (!started.isCompleted) started.complete();
    _subscription = LoomDefaultNetworkGeneration.events.listen((snapshot) {
      if (snapshot.generation <= generation || pending.isCompleted) return;
      cancelledByGeneration = true;
      pending.completeError(
        LoomNetworkGenerationChangedException(
          fromGeneration: generation,
          toGeneration: snapshot.generation,
        ),
      );
      unawaited(_subscription?.cancel());
    });
    return pending.future;
  }

  @override
  void abortActiveTransport(String category) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const SocketException('aborted'));
    }
    unawaited(_subscription?.cancel());
  }
}
