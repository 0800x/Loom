import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  LoomMessagingClient clientWithTokenProvider(
    Future<String> Function() tokenProvider,
  ) =>
      LoomMessagingClient(
        baseUri: Uri.parse('https://chat.example'),
        accessTokenProvider: tokenProvider,
        deviceProofProvider: LoomDeviceRequestProofProvider(
          deviceId: 'dev_00000000-0000-0000-0000-000000000001',
          signer: (_) async => List<int>.filled(64, 7),
        ),
      );

  test('missing online session is surfaced as transport unavailability',
      () async {
    final client = clientWithTokenProvider(
      () async => throw const LoomProtocolException('Access token unavailable'),
    );

    await expectLater(
      client.sendOpaqueMessage(
        conversationId: 'conversation-1',
        clientId: 'client-1',
        type: LoomMessageType.text,
        ciphertext: 'opaque-ciphertext',
        protocolVersion: 'test-v1',
      ),
      throwsA(isA<SocketException>()),
    );
  });

  test('unrelated local protocol failures are not reclassified', () async {
    final client = clientWithTokenProvider(
      () async => throw const LoomProtocolException('Credential store damaged'),
    );

    await expectLater(
      client.sendOpaqueMessage(
        conversationId: 'conversation-1',
        clientId: 'client-2',
        type: LoomMessageType.text,
        ciphertext: 'opaque-ciphertext',
        protocolVersion: 'test-v1',
      ),
      throwsA(
        isA<LoomProtocolException>().having(
          (error) => error.message,
          'message',
          'Credential store damaged',
        ),
      ),
    );
  });
}
