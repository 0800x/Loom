/// One authenticated sharing session owns one stable message anchor. Position
/// updates and the terminal stop event change its content, never its list key.
List<T> projectLoomLiveLocations<T>(
  Iterable<T> messages, {
  required Map<String, Object?>? Function(T) location,
  required String Function(T) sender,
  required int Function(T, T) compare,
  required T Function(T anchor, T latest) merge,
}) {
  final ordinary = <T>[];
  final sessions = <(String, String), (T, T)>{};
  for (final message in messages) {
    final point = location(message), session = point?['session'];
    if (session is! String || point?['at'] is! int) {
      ordinary.add(message);
      continue;
    }
    final key = (sender(message), session), previous = sessions[key];
    if (previous == null) {
      sessions[key] = (message, message);
      continue;
    }
    final anchor = compare(message, previous.$1) < 0 ? message : previous.$1;
    final old = location(previous.$2)!;
    final terminal = old['stopped'] == true;
    final sameExpiry = point!['until'] == old['until'];
    final newer = (point['at'] as int) > (old['at'] as int);
    final latest =
        sameExpiry && !terminal && (newer || point['stopped'] == true)
        ? message
        : previous.$2;
    sessions[key] = (anchor, latest);
  }
  ordinary.addAll(sessions.values.map((pair) => merge(pair.$1, pair.$2)));
  ordinary.sort(compare);
  return ordinary;
}
