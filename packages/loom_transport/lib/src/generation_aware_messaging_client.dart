import 'dart:async';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';

import 'network_generation.dart';

/// A route-scoped messaging API whose socket lifetime is tied to the current
/// Android default-network generation.
///
/// Each operation gets its own [HttpClient]. That intentionally avoids carrying
/// DNS/socket-pool state across default-network changes. A generation event or
/// an explicit send-budget abort force-closes every active client for this
/// route; a later operation creates fresh sockets on the then-current network.
class LoomGenerationAwareMessagingClient
    implements LoomMessagingApi, LoomAbortableTransport {
  LoomGenerationAwareMessagingClient({
    required this.baseUri,
    required this.accessTokenProvider,
    required this.deviceProofProvider,
    this.refreshRejectedToken,
    this.connectTimeout = const Duration(seconds: 8),
    this.responseHeaderTimeout = const Duration(seconds: 15),
    this.responseBodyTimeout = const Duration(seconds: 15),
  });

  final Uri baseUri;
  final LoomAccessTokenProvider accessTokenProvider;
  final LoomDeviceRequestProofProvider deviceProofProvider;
  final Future<bool> Function(String rejectedToken)? refreshRejectedToken;
  final Duration connectTimeout;
  final Duration responseHeaderTimeout;
  final Duration responseBodyTimeout;

  final Set<HttpClient> _active = <HttpClient>{};

  @override
  void abortActiveTransport(String category) {
    final clients = List<HttpClient>.of(_active);
    for (final client in clients) {
      client.close(force: true);
    }
    LoomTransportDiagnostics.event(
      'active_transport_aborted',
      networkGeneration: LoomDefaultNetworkGeneration.current.generation,
      timeoutCategory: category,
    );
  }

  Future<T> _run<T>(
    Future<T> Function(LoomMessagingClient client) action,
  ) async {
    final generation = LoomDefaultNetworkGeneration.current.generation;
    final http = HttpClient();
    _active.add(http);
    final client = LoomMessagingClient(
      baseUri: baseUri,
      accessTokenProvider: accessTokenProvider,
      deviceProofProvider: deviceProofProvider,
      refreshRejectedToken: refreshRejectedToken,
      connectTimeout: connectTimeout,
      responseHeaderTimeout: responseHeaderTimeout,
      responseBodyTimeout: responseBodyTimeout,
      httpClient: http,
    );
    final changed = Completer<T>();
    late final StreamSubscription<LoomDefaultNetworkSnapshot> subscription;
    subscription = LoomDefaultNetworkGeneration.events.listen((snapshot) {
      if (snapshot.generation <= generation || changed.isCompleted) {
        return;
      }
      http.close(force: true);
      changed.completeError(
        LoomNetworkGenerationChangedException(
          fromGeneration: generation,
          toGeneration: snapshot.generation,
        ),
      );
    });
    try {
      return await Future.any<T>(<Future<T>>[action(client), changed.future]);
    } finally {
      await subscription.cancel();
      _active.remove(http);
      http.close(force: true);
    }
  }

  @override
  Future<List<LoomConversation>> fetchConversations() =>
      _run((client) => client.fetchConversations());

  @override
  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) => _run(
    (client) => client.sendOpaqueMessage(
      conversationId: conversationId,
      clientId: clientId,
      type: type,
      ciphertext: ciphertext,
      protocolVersion: protocolVersion,
      replyToMessageId: replyToMessageId,
      metadata: metadata,
    ),
  );

  @override
  Future<LoomSyncPage> sync({String? cursor, int limit = 200}) =>
      _run((client) => client.sync(cursor: cursor, limit: limit));

  @override
  Future<void> markRead({
    required String conversationId,
    required int throughOrder,
  }) => _run(
    (client) => client.markRead(
      conversationId: conversationId,
      throughOrder: throughOrder,
    ),
  );

  @override
  Future<LoomAttachmentReceipt> uploadEncryptedAttachment({
    required String conversationId,
    required File encryptedFile,
    required String contentType,
  }) => _run(
    (client) => client.uploadEncryptedAttachment(
      conversationId: conversationId,
      encryptedFile: encryptedFile,
      contentType: contentType,
    ),
  );
}
