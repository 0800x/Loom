class LoomParsedAddress {
  const LoomParsedAddress({
    required this.username,
    required this.homeNode,
    required this.canonical,
  });

  final String username;
  final String homeNode;
  final String canonical;

  bool isSameNode(String node) =>
      homeNode.toLowerCase() ==
      LoomAddress.normalizeHomeNode(node).toLowerCase();
}

abstract final class LoomAddress {
  static final RegExp _username = RegExp(r'^[a-z0-9_][a-z0-9_.-]{2,31}$');

  /// Accepts Loom canonical addresses (`@alice:node.example`), the familiar
  /// user-facing alias (`alice@node.example`), or a bare username. Bare names
  /// always resolve on the signed-in account's Home Node.
  static LoomParsedAddress normalizeInput(
    String input, {
    required String homeNode,
  }) {
    final value = input.trim();
    if (value.isEmpty) {
      throw const FormatException('Enter a username or Loom address');
    }

    String username;
    String node;
    if (value.startsWith('@')) {
      final separator = value.indexOf(':', 1);
      if (separator <= 1 || separator == value.length - 1) {
        throw const FormatException('Invalid Loom address');
      }
      username = value.substring(1, separator);
      node = value.substring(separator + 1);
    } else if (value.contains('@')) {
      final separator = value.indexOf('@');
      if (separator <= 0 ||
          separator != value.lastIndexOf('@') ||
          separator == value.length - 1) {
        throw const FormatException('Invalid Loom address');
      }
      username = value.substring(0, separator);
      node = value.substring(separator + 1);
    } else {
      username = value;
      node = homeNode;
    }

    final normalizedUsername = username.trim().toLowerCase();
    if (!_username.hasMatch(normalizedUsername)) {
      throw const FormatException(
        'Username must be 3–32 characters using letters, numbers, _, . or -',
      );
    }
    final normalizedNode = normalizeHomeNode(node);
    return LoomParsedAddress(
      username: normalizedUsername,
      homeNode: normalizedNode,
      canonical: '@$normalizedUsername:$normalizedNode',
    );
  }

  static LoomParsedAddress parseCanonical(String input) {
    final value = input.trim();
    if (!value.startsWith('@')) {
      throw const FormatException('Invalid Loom canonical address');
    }
    final separator = value.indexOf(':', 1);
    if (separator <= 1 || separator == value.length - 1) {
      throw const FormatException('Invalid Loom canonical address');
    }
    return normalizeInput(
      value,
      homeNode: value.substring(separator + 1),
    );
  }

  /// Home Nodes are authorities, not arbitrary URLs. Host:port is supported
  /// because local/LAN Nodes use it in registration receipts on Android and
  /// Windows. A URL may be supplied by internal callers, but path/query/user
  /// info are never part of a Loom identity address.
  static String normalizeHomeNode(String input) {
    var value = input.trim().toLowerCase();
    if (value.startsWith('https://') || value.startsWith('http://')) {
      final uri = Uri.tryParse(value);
      if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
        throw const FormatException('Invalid Home Node');
      }
      if ((uri.path.isNotEmpty && uri.path != '/') ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('Home Node must not include a path');
      }
      value = uri.authority;
    }
    if (value.endsWith('.')) value = value.substring(0, value.length - 1);
    if (value.isEmpty ||
        value.length > 320 ||
        value.contains(RegExp(r'\s')) ||
        value.contains('/') ||
        value.contains('\\') ||
        value.contains('@') ||
        value.contains('?') ||
        value.contains('#')) {
      throw const FormatException('Invalid Home Node');
    }
    final uri = Uri.tryParse('https://$value');
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid Home Node');
    }
    return value;
  }
}
