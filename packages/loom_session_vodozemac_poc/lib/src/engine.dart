import 'dart:typed_data';

/// Narrow provider-engine boundary used by the non-shipping vodozemac PoC.
///
/// The real implementation crosses the Rust C ABI. Unit tests can substitute a
/// deterministic fake without changing Loom's transaction logic.
abstract interface class LoomVodozemacPocEngine {
  Future<LoomVodozemacPocEngineVersion> version();

  Future<LoomVodozemacPocAccount> createAccount({int oneTimeKeyCount = 8});

  /// Replenishes unpublished one-time keys up to [targetOneTimeKeyCount] based
  /// on the account's currently stored private-key count. When
  /// [rotateFallback] is true, a new fallback key is generated as part of the
  /// returned account state.
  ///
  /// The returned account pickle MUST be durably committed before any returned
  /// public key is published to a server.
  Future<LoomVodozemacPocPrekeyInventory> preparePrekeys({
    required String accountPickle,
    required int targetOneTimeKeyCount,
    required bool rotateFallback,
  });

  Future<String> markKeysPublished(String accountPickle);

  /// Forgets the older fallback private key retained by vodozemac after a
  /// rotation. Callers must delay this until their disruption-tolerant receive
  /// window has safely elapsed.
  Future<LoomVodozemacPocFallbackCleanup> forgetPreviousFallback(
    String accountPickle,
  );

  Future<LoomVodozemacPocSession> createOutboundSession({
    required String accountPickle,
    required Object remoteIdentityKey,
    required Object remoteOneTimeKey,
  });

  Future<LoomVodozemacPocInboundSession> createInboundSession({
    required String accountPickle,
    required Object remoteIdentityKey,
    required Object message,
  });

  Future<LoomVodozemacPocEncrypted> encrypt({
    required String sessionPickle,
    required Uint8List plaintext,
  });

  Future<LoomVodozemacPocDecrypted> decrypt({
    required String sessionPickle,
    required Object message,
  });
}

final class LoomVodozemacPocEngineVersion {
  const LoomVodozemacPocEngineVersion({
    required this.abi,
    required this.engine,
    required this.version,
  });

  final int abi;
  final String engine;
  final String version;
}

final class LoomVodozemacPocAccount {
  const LoomVodozemacPocAccount({
    required this.accountPickle,
    required this.curve25519,
    required this.ed25519,
    required this.oneTimeKeys,
  });

  final String accountPickle;
  final Object curve25519;
  final Object ed25519;
  final List<Object> oneTimeKeys;
}

final class LoomVodozemacPocPrekeyInventory {
  const LoomVodozemacPocPrekeyInventory({
    required this.accountPickle,
    required this.curve25519,
    required this.ed25519,
    required this.oneTimeKeys,
    required this.fallbackKeys,
    required this.storedOneTimeKeyCount,
    required this.maxOneTimeKeyCount,
  });

  final String accountPickle;
  final Object curve25519;
  final Object ed25519;

  /// Currently unpublished public one-time keys.
  final List<Object> oneTimeKeys;

  /// Currently unpublished fallback key. Vodozemac exposes at most one.
  final List<Object> fallbackKeys;

  /// Private one-time keys still retained in the account, published or not.
  final int storedOneTimeKeyCount;

  /// Upstream-recommended maximum number of one-time keys kept on the server.
  final int maxOneTimeKeyCount;
}

final class LoomVodozemacPocFallbackCleanup {
  const LoomVodozemacPocFallbackCleanup({
    required this.accountPickle,
    required this.forgotten,
  });

  final String accountPickle;
  final bool forgotten;
}

final class LoomVodozemacPocSession {
  const LoomVodozemacPocSession({
    required this.sessionId,
    required this.sessionPickle,
  });

  final String sessionId;
  final String sessionPickle;
}

final class LoomVodozemacPocInboundSession {
  LoomVodozemacPocInboundSession({
    required this.accountPickle,
    required this.sessionId,
    required this.sessionPickle,
    required Uint8List plaintext,
  }) : plaintext = Uint8List.fromList(plaintext);

  final String accountPickle;
  final String sessionId;
  final String sessionPickle;
  final Uint8List plaintext;
}

final class LoomVodozemacPocEncrypted {
  const LoomVodozemacPocEncrypted({
    required this.sessionId,
    required this.sessionPickle,
    required this.message,
  });

  final String sessionId;
  final String sessionPickle;
  final Object message;
}

final class LoomVodozemacPocDecrypted {
  LoomVodozemacPocDecrypted({
    required this.sessionId,
    required this.sessionPickle,
    required Uint8List plaintext,
  }) : plaintext = Uint8List.fromList(plaintext);

  final String sessionId;
  final String sessionPickle;
  final Uint8List plaintext;
}

final class LoomVodozemacPocEngineException implements Exception {
  const LoomVodozemacPocEngineException(this.code);

  final String code;

  @override
  String toString() => 'LoomVodozemacPocEngineException($code)';
}
