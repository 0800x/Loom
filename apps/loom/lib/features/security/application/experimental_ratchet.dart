import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

/// Persisted opt-in only. The application still requires the native
/// implementation and security review before using this experimental path.
abstract final class LoomExperimentalRatchet {
  static const _key = 'loom.experimental_ratchet.v2.enabled';
  static final LoomSecretStorage _storage = LoomSecretStorage();

  static bool ratchetV2Enabled = false;

  static Future<void> load() async {
    try {
      ratchetV2Enabled = await _storage.read(key: _key) == 'true';
    } catch (_) {
      // App Lock may still be waiting for user authentication at cold start.
      // The active session calls load again after its vault is unlocked.
      ratchetV2Enabled = false;
    }
  }

  static Future<void> setRatchetV2(bool value) async {
    await _storage.write(key: _key, value: value ? 'true' : 'false');
    ratchetV2Enabled = value;
  }
}
