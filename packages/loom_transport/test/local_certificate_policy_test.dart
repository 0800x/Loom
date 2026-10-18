import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:loom_transport/src/local_certificate_policy.dart';

void main() {
  test(
      'leaf pins are origin scoped, reject CA, survive reload and revoke open clients',
      () async {
    final temp = await Directory.systemTemp.createTemp('loom-host-pins-');
    addTearDown(() => temp.delete(recursive: true));
    Future<File> certificate(String name, bool ca) async {
      final result = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=localhost',
        '-addext',
        'subjectAltName=IP:127.0.0.1,DNS:localhost',
        '-addext',
        'basicConstraints=critical,CA:${ca ? 'TRUE' : 'FALSE'}',
        '-keyout',
        '${temp.path}/$name.key',
        '-out',
        '${temp.path}/$name.pem'
      ]);
      expect(result.exitCode, 0);
      return File('${temp.path}/$name.pem');
    }

    final file = await certificate('leaf', false),
        ca = await certificate('ca', true);
    final bytes = await file.readAsBytes(), caBytes = await ca.readAsBytes();
    final context = SecurityContext()
      ..useCertificateChain(file.path)
      ..usePrivateKey('${temp.path}/leaf.key');
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      req.response.write('verified');
      req.response.close();
    }, onError: (Object _) {});
    final endpoint = Uri.parse('https://127.0.0.1:${server.port}'),
        trust = Directory('${temp.path}/trust');
    final policy = LoomScopedCertificatePolicy(),
        digest = LoomScopedCertificatePolicy.fingerprint(bytes);
    Future<String> read(HttpClient client, Uri uri) async {
      final response = await (await client.getUrl(uri)).close();
      return utf8.decoder.bind(response).join();
    }

    final ordinary = HttpClient();
    addTearDown(() => ordinary.close(force: true));
    await expectLater(
        read(ordinary, endpoint), throwsA(isA<HandshakeException>()));
    await expectLater(
        policy.accept(caBytes,
            endpoint: endpoint,
            confirmedFingerprint:
                LoomScopedCertificatePolicy.fingerprint(caBytes),
            directory: trust),
        throwsFormatException);
    await expectLater(
        policy.accept(bytes,
            endpoint: endpoint,
            confirmedFingerprint: 'wrong',
            directory: trust),
        throwsFormatException);
    await policy.accept(bytes,
        endpoint: endpoint, confirmedFingerprint: digest, directory: trust);
    final pinned = policy.createHttpClient(null);
    addTearDown(() => pinned.close(force: true));
    expect(await read(pinned, endpoint), 'verified');
    await expectLater(
        read(ordinary, endpoint), throwsA(isA<HandshakeException>()));
    await expectLater(
        read(pinned, Uri.parse('https://localhost:${server.port}')),
        throwsA(isA<HandshakeException>()));
    final restored = LoomScopedCertificatePolicy();
    expect(await restored.load(trust), 0);
    final reload = restored.createHttpClient(null);
    addTearDown(() => reload.close(force: true));
    expect(await read(reload, endpoint), 'verified');
    await restored.forgetHost(endpoint, trust);
    final fresh = restored.createHttpClient(null);
    addTearDown(() => fresh.close(force: true));
    await expectLater(
        read(fresh, endpoint), throwsA(isA<HandshakeException>()));
    await File('${trust.path}/old.pem').writeAsBytes(bytes);
    expect(await restored.load(trust), 1);
  });
}
