/// Namespaces secure-storage keys by the active local account.
///
/// A null scope intentionally preserves the historic single-account key names,
/// so existing installations remain readable without a credential migration.
final class LoomAccountScope {
  const LoomAccountScope(this.id);

  final String id;

  static LoomAccountScope? current;

  static String scopedKey(String key) {
    final scope = current;
    if (scope == null) return key;
    if (key.isEmpty || key.length > 512) {
      throw ArgumentError.value(key, 'key');
    }
    final normalizedId = scope.id.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(normalizedId)) {
      throw StateError('Invalid active account scope');
    }
    return 'loom.account.' + normalizedId + '.' + key;
  }
}
