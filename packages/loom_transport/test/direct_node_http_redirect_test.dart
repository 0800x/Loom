import 'dart:convert';
import 'dart:io';

import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  test('direct-node HTTP poster never follows redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var firstRequests = 0;
    var redirectedRequests = 0;

    server.listen((request) async {
      if (request.uri.path == '/first') {
        firstRequests += 1;
        request.response.statusCode = HttpStatus.temporaryRedirect;
        request.response.headers.set(HttpHeaders.locationHeader, '/redirected');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/redirected') {
        redirectedRequests += 1;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'accepted': true}));
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final poster = LoomIoDirectHttpPoster();
    addTearDown(poster.close);
    final response = await poster.postJson(
      Uri.parse('http://127.0.0.1:${server.port}/first'),
      <String, Object?>{'packetId': 'packet-redirect-test-0001'},
    );

    expect(response.statusCode, HttpStatus.temporaryRedirect);
    expect(firstRequests, 1);
    expect(redirectedRequests, 0);
  });
}
