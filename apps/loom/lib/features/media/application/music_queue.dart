import 'dart:math';

/// Queue navigation is independent of the decoder and platform media session.
/// Shuffle visits each track once before repeating a queue.
class LoomMusicQueue {
  LoomMusicQueue({Random? random}) : _random = random ?? Random();
  final Random _random;
  final List<String> ids = [];
  final List<String> _history = [];
  final Set<String> _visited = {};
  String? current;
  bool shuffle = false;
  int repeat = 0; // off / queue / track

  void replace(Iterable<String> values, {String? start}) {
    ids
      ..clear()
      ..addAll(values.toSet());
    _history.clear();
    _visited.clear();
    current = null;
    if (start != null) select(start);
  }

  void select(String id) {
    if (current != null && current != id) _history.add(current!);
    current = id;
    _visited.add(id);
  }

  void remove(String id) {
    ids.remove(id);
    _history.removeWhere((v) => v == id);
    _visited.remove(id);
  }

  void reorder(int from, int to) {
    ids.insert(to, ids.removeAt(from));
  }

  String? next({bool completed = false}) {
    if (ids.isEmpty) return null;
    if (completed && repeat == 2 && ids.contains(current)) return current;
    String? selected;
    if (shuffle) {
      var remaining = ids.where((id) => !_visited.contains(id)).toList();
      if (remaining.isEmpty && (repeat == 1 || !completed)) {
        _visited.clear();
        remaining = ids.where((id) => id != current).toList();
        if (remaining.isEmpty) remaining = List.of(ids);
      }
      if (remaining.isNotEmpty) {
        selected = remaining[_random.nextInt(remaining.length)];
      }
    } else {
      final index = ids.indexOf(current ?? '');
      if (index + 1 < ids.length) {
        selected = ids[index + 1];
      } else if (repeat == 1 || !completed) {
        selected = ids.first;
      }
    }
    if (selected != null) select(selected);
    return selected;
  }

  String? previous() {
    while (_history.isNotEmpty) {
      final id = _history.removeLast();
      if (ids.contains(id)) {
        current = id;
        return id;
      }
    }
    if (ids.isEmpty) return null;
    final index = ids.indexOf(current ?? '');
    current = ids[(index - 1 + ids.length) % ids.length];
    return current;
  }
}
