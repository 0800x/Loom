/// A link names a Home Node and an opaque invitation capability, never keys.
class LoomGroupInviteLink {
  const LoomGroupInviteLink(this.node, this.token);
  final Uri node;
  final String token;
  static LoomGroupInviteLink? tryParse(String value) {
    try {
      final uri = Uri.parse(value.trim());
      late Uri node;
      late String token;
      if (uri.scheme == 'https' &&
          uri.pathSegments.length == 2 &&
          uri.pathSegments.first == 'g') {
        if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
          return null;
        }
        node = Uri(
          scheme: 'https',
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: '/',
        );
        token = uri.pathSegments.last;
      } else if (uri.scheme == 'loom' &&
          uri.host == 'group' &&
          uri.path == '/join') {
        if (uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            uri.hasPort ||
            uri.queryParametersAll.length != 2 ||
            uri.queryParametersAll['node']?.length != 1 ||
            uri.queryParametersAll['token']?.length != 1) {
          return null;
        }
        node = Uri.parse(uri.queryParameters['node'] ?? '');
        token = uri.queryParameters['token'] ?? '';
      } else {
        return null;
      }
      if (node.scheme != 'https' ||
          node.host.isEmpty ||
          node.userInfo.isNotEmpty ||
          (node.path.isNotEmpty && node.path != '/') ||
          node.hasQuery ||
          node.hasFragment ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
        return null;
      }
      return LoomGroupInviteLink(node, token);
    } on FormatException {
      return null;
    }
  }
}
