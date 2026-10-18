import 'node_client.dart';

/// Production LAN and public nodes require authenticated TLS. Cleartext is
/// permitted only on exact loopback endpoints for local development.
bool loomIsDevelopmentLoopback(String host) =>
    const {'localhost', '127.0.0.1', '::1'}.contains(host.toLowerCase());

void requireLoomTransport(Uri uri, {bool baseEndpoint = true}) {
  if (uri.host.isEmpty ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' && loomIsDevelopmentLoopback(uri.host))) ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (baseEndpoint &&
          (uri.hasQuery || (uri.path.isNotEmpty && uri.path != '/')))) {
    throw const LoomProtocolException(
      'Node endpoint requires HTTPS; HTTP is only allowed on development loopback',
    );
  }
}
