import 'dart:convert';
import 'dart:io';

class NodeStatus {
  const NodeStatus({
    required this.mode,
    required this.uptimeSeconds,
    required this.node,
    required this.stats,
  });
  final String mode;
  final int uptimeSeconds;
  final Map<String, Object?> node;
  final Map<String, Object?> stats;

  factory NodeStatus.fromJson(Map<String, Object?> json) => NodeStatus(
    mode: json['mode'] as String? ?? 'unknown',
    uptimeSeconds: (json['uptimeSeconds'] as num?)?.toInt() ?? 0,
    node: (json['node'] as Map?)?.cast<String, Object?>() ?? const {},
    stats: (json['stats'] as Map?)?.cast<String, Object?>() ?? const {},
  );
}

class NodeApiException implements Exception {
  const NodeApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NodeAdminApi {
  NodeAdminApi({HttpClient? client}) : _client = client ?? HttpClient();
  final HttpClient _client;

  Future<NodeStatus> status({
    required Uri baseUri,
    required String adminToken,
  }) async {
    final uri = baseUri.resolve('/admin/v1/status');
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' &&
            const {'localhost', '127.0.0.1', '::1'}.contains(uri.host))) {
      throw const NodeApiException('Remote Node management requires HTTPS.');
    }
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $adminToken');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (out, chunk) => out..addAll(chunk),
    );
    if (response.statusCode != HttpStatus.ok) {
      throw NodeApiException(
        response.statusCode == HttpStatus.unauthorized
            ? 'Admin token was rejected.'
            : 'Node returned HTTP ${response.statusCode}.',
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const NodeApiException('Node returned an invalid status payload.');
    }
    return NodeStatus.fromJson(decoded.cast<String, Object?>());
  }

  void close() => _client.close(force: true);
}
