/// HTTP(S) links only. Does not fetch or preview destinations.
List<({int start, int end, Uri uri})> loomDetectLinks(String text) {
  final pattern = RegExp(
    r'(?:https?://|www\.)[^\s<>\u200c]+|(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,24}(?:/[^\s<>\u200c]*)?',
    caseSensitive: false,
  );
  final links = <({int start, int end, Uri uri})>[];
  for (final match in pattern.allMatches(text)) {
    if (match.start > 0 &&
        RegExp(r'[\w@:/.-]').hasMatch(text[match.start - 1])) {
      continue;
    }
    var value = match.group(0)!;
    value = value.replaceFirst(RegExp(r'[.,!?;:،؛؟]+$'), '');
    while (value.endsWith(')') &&
        ')'.allMatches(value).length > '('.allMatches(value).length) {
      value = value.substring(0, value.length - 1);
    }
    while (value.endsWith(']') || value.endsWith('}')) {
      value = value.substring(0, value.length - 1);
    }
    final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      continue;
    }
    links.add((start: match.start, end: match.start + value.length, uri: uri));
  }
  return links;
}
