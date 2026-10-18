import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_next/features/nodes/application/local_https_trust.dart';

void main() {
  test('rejects keys, certificate bundles and malformed PEM', () {
    for (final text in [
      '-----BEGIN PRIVATE '
          'KEY-----\nAAAA\n-----END PRIVATE '
          'KEY-----',
      'not a certificate',
      '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----',
    ]) {
      expect(
        () => LoomLocalHttpsTrust.certificateDer(utf8.encode(text)),
        throwsFormatException,
      );
    }
  });

  test(
    'explicit certificate trust persists, reloads and can be removed',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'loom-local-tls-test-',
      );
      addTearDown(() async {
        HttpOverrides.global = null;
        await temp.delete(recursive: true);
      });
      final result = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=Loom test',
        '-addext',
        'subjectAltName=IP:127.0.0.1',
        '-addext',
        'basicConstraints=critical,CA:FALSE',
        '-keyout',
        '${temp.path}/key.pem',
        '-out',
        '${temp.path}/cert.pem',
      ]);
      expect(result.exitCode, 0, reason: 'OpenSSL fixture generation failed');
      final bytes = await File('${temp.path}/cert.pem').readAsBytes();
      final trust = Directory('${temp.path}/trust');
      final fingerprint = await LoomLocalHttpsTrust.fingerprint(bytes);
      final openssl = await Process.run('openssl', [
        'x509',
        '-in',
        '${temp.path}/cert.pem',
        '-noout',
        '-fingerprint',
        '-sha256',
      ]);
      expect(openssl.stdout.toString(), contains(fingerprint));
      expect(await LoomLocalHttpsTrust.fingerprints(directory: trust), isEmpty);
      final serverContext = SecurityContext()
        ..useCertificateChain('${temp.path}/cert.pem')
        ..usePrivateKey('${temp.path}/key.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.write('verified');
        request.response.close();
      }, onError: (Object _) {});
      Future<String> request(SecurityContext context) async {
        final client = HttpClient(context: context);
        try {
          final response = await (await client.getUrl(
            Uri.parse('https://127.0.0.1:${server.port}/readyz'),
          )).close();
          return await utf8.decoder.bind(response).join();
        } finally {
          client.close(force: true);
        }
      }

      await expectLater(
        request(SecurityContext()),
        throwsA(isA<HandshakeException>()),
      );
      final explicitContext = SecurityContext();
      await LoomLocalHttpsTrust.accept(
        bytes,
        directory: trust,
        endpoint: Uri.parse('https://127.0.0.1:${server.port}'),
        confirmedFingerprint: fingerprint,
      );
      expect(await request(explicitContext), 'verified');
      expect(await LoomLocalHttpsTrust.fingerprints(directory: trust), [
        fingerprint,
      ]);
      final restoredContext = SecurityContext();
      expect(await LoomLocalHttpsTrust.load(directory: trust), 0);
      expect(await request(restoredContext), 'verified');
      await LoomLocalHttpsTrust.forget(fingerprint, directory: trust);
      expect(await LoomLocalHttpsTrust.fingerprints(directory: trust), isEmpty);
      expect(await LoomLocalHttpsTrust.load(directory: trust), 0);
      await expectLater(
        request(SecurityContext()),
        throwsA(isA<HandshakeException>()),
      );
      await expectLater(
        LoomLocalHttpsTrust.forget('../identity', directory: trust),
        throwsFormatException,
      );
    },
  );
}
