import 'dart:convert';
import 'dart:io';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  for (final body in [
    '<html>Not Found</html>',
    '{"error":"not_found"}',
    '{"error":"group_invite_unavailable"}'
  ]) {
    test(
        'group 404 keeps its HTTP status and distinguishes an unavailable invite: $body',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 404;
        request.response.write(body);
        await request.response.close();
      });
      final client = LoomGroupClient(
          baseUri: Uri.parse('http://localhost:${server.port}'),
          accessTokenProvider: () async => 'token',
          deviceProof: LoomDeviceRequestProofProvider(
              deviceId: 'dev_00000000-0000-4000-8000-000000000001',
              signer: (_) async => List.filled(64, 1)));
      try {
        await expectLater(
            client.previewInvite('a' * 43),
            throwsA(isA<LoomGroupProtocolException>()
                .having((e) => e.status, 'HTTP status', 404)
                .having(
                    (e) => e.code,
                    'diagnostic',
                    body.startsWith('{')
                        ? (jsonDecode(body) as Map)['error']
                        : 'not_found')));
      } finally {
        client.close();
        await server.close(force: true);
      }
    });
  }
}
