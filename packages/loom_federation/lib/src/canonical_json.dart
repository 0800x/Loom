import 'dart:convert';

/// Deterministic JSON serializer used only for Loom protocol signatures.
/// Maps are sorted lexicographically by key and only JSON-compatible values
/// are accepted. This is intentionally small and protocol-scoped.
String loomCanonicalJson(Object? value) {
  Object? normalize(Object? input) {
    if (input == null || input is bool || input is num || input is String) {
      return input;
    }
    if (input is List) {
      return input.map(normalize).toList(growable: false);
    }
    if (input is Map) {
      final entries = <String, Object?>{};
      for (final entry in input.entries) {
        if (entry.key is! String) {
          throw const FormatException(
            'Canonical JSON map keys must be strings',
          );
        }
        entries[entry.key as String] = normalize(entry.value);
      }
      final keys = entries.keys.toList()..sort();
      return <String, Object?>{for (final key in keys) key: entries[key]};
    }
    throw FormatException(
      'Unsupported canonical JSON value: ${input.runtimeType}',
    );
  }

  return jsonEncode(normalize(value));
}
