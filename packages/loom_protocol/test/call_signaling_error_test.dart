import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
      'WebSocket call.error preserves its call identity and rejects unscoped errors',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final peer = Completer<WebSocket>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
      peer.complete(socket);
    });
    final connection = LoomCallSignalingConnection(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      accessTokenProvider: () async => 'test-token',
      deviceProofProvider: LoomDeviceRequestProofProvider(
          deviceId: 'dev_00000000-0000-4000-8000-000000000001',
          signer: (_) async => List<int>.filled(64, 0)),
    );
    final errors = <Object>[];
    final received = Completer<void>();
    final subscription =
        connection.signals.listen((_) {}, onError: (Object error) {
      errors.add(error);
      if (!received.isCompleted) received.complete();
    });
    addTearDown(() async {
      await subscription.cancel();
      await connection.dispose();
      await server.close(force: true);
    });
    await connection.connect();
    final socket = await peer.future;
    socket.add(
        jsonEncode({'kind': 'call.error', 'reason': 'call_signaling_failed'}));
    socket.add(jsonEncode({
      'kind': 'call.error',
      'callId': 'call-current',
      'reason': 'call_conversation_not_found'
    }));
    await received.future.timeout(const Duration(seconds: 2));
    expect(errors, hasLength(1));
    expect(
        errors.single,
        isA<LoomCallSignalingException>()
            .having((e) => e.callId, 'callId', 'call-current')
            .having((e) => e.message, 'reason', 'call_conversation_not_found'));
  });
}
