import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

class LoomSearchPreferences {
  const LoomSearchPreferences({this.enabled = true});

  final bool enabled;
}

/// Stores whether local decrypted-message indexing is enabled.
///
/// The preference follows the active account through LoomSecretStorage's
/// account-scoped key namespace and is unavailable while the vault is locked.
class LoomSearchPreferencesStore {
  LoomSearchPreferencesStore([LoomSecretStorage? storage])
    : _storage = storage ?? LoomSecretStorage();

  static const _key = 'loom.local_search.enabled.v1';
  final LoomSecretStorage _storage;

  Future<LoomSearchPreferences> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return const LoomSearchPreferences();
    if (value == 'true') return const LoomSearchPreferences(enabled: true);
    if (value == 'false') return const LoomSearchPreferences(enabled: false);
    throw const FormatException('Invalid local-search preference');
  }

  Future<void> save(LoomSearchPreferences preferences) async {
    await _storage.write(
      key: _key,
      value: preferences.enabled ? 'true' : 'false',
    );
  }
}
