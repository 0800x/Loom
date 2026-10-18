class LoomNodeShareLink {
  const LoomNodeShareLink(this.endpoint, this.nodeId, this.fingerprint);
  final Uri endpoint;
  final String nodeId, fingerprint;
  String get encoded => endpoint
      .replace(
        path: '/',
        queryParameters: {
          'loom-node': '1',
          'nodeId': nodeId,
          'fingerprint': fingerprint,
        },
      )
      .toString();
  factory LoomNodeShareLink.parse(String value) {
    final url = value.length <= 4096 ? Uri.tryParse(value.trim()) : null;
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasFragment ||
        !['', '/'].contains(url.path) ||
        url.queryParameters['loom-node'] != '1') {
      throw const FormatException('Invalid Loom server QR');
    }
    for (final field in ['loom-node', 'nodeId', 'fingerprint']) {
      if (url.queryParametersAll[field]?.length != 1) {
        throw const FormatException('Duplicate server QR field');
      }
    }
    final id = url.queryParameters['nodeId'] ?? '';
    final fingerprint = url.queryParameters['fingerprint'] ?? '';
    if (!RegExp(r'^node:[A-Za-z0-9_-]{43}$').hasMatch(id) ||
        !RegExp(
          r'^[A-Fa-f0-9]{64}$',
        ).hasMatch(fingerprint.replaceAll(' ', ''))) {
      throw const FormatException('Invalid server identity');
    }
    return LoomNodeShareLink(
      Uri(scheme: 'https', host: url.host, port: url.hasPort ? url.port : null),
      id,
      fingerprint,
    );
  }
}
