import 'dart:typed_data';

/// Opaque native Account/Session handle. The numeric token has no protocol or
/// identity meaning and is valid only inside one process/native library instance.
final class LoomVodozemacNativeHandle {
  const LoomVodozemacNativeHandle(this.value);
  final int value;

  bool get isValid => value > 0;
}

final class LoomVodozemacPublicInventory {
  const LoomVodozemacPublicInventory({
    required this.curve25519,
    required this.ed25519,
    required this.oneTimeKeys,
    required this.fallbackKeys,
    required this.storedOneTimeKeyCount,
    required this.maxOneTimeKeyCount,
  });

  final Object curve25519;
  final Object ed25519;
  final List<Object> oneTimeKeys;
  final List<Object> fallbackKeys;
  final int storedOneTimeKeyCount;
  final int maxOneTimeKeyCount;
}

/// Native inbound result. [plaintext] intentionally takes ownership of the
/// exact byte buffer returned by the FFI engine rather than cloning it. The
/// provider copies only the application result it needs and then zeroes this
/// buffer in `finally`, avoiding a second secret plaintext copy waiting for GC.
final class LoomVodozemacNativeInbound {
  const LoomVodozemacNativeInbound({
    required this.session,
    required this.plaintext,
  });

  final LoomVodozemacNativeHandle session;
  final Uint8List plaintext;
}

/// Candidate production FFI shape for the vodozemac evaluation core.
///
/// Sensitive Account/Session state is represented as byte arrays only at the
/// persistence boundary. It is never required to become a Dart String or travel
/// in the public JSON command ABI. Public keys and Olm ciphertext remain JSON
/// values because they are protocol/public material, not secret provider state.
abstract interface class LoomVodozemacHandleEngine {
  int get abiVersion;

  LoomVodozemacNativeHandle createAccount({int oneTimeKeyCount = 8});
  LoomVodozemacNativeHandle importAccount(Uint8List stateBytes);
  Uint8List exportAccount(LoomVodozemacNativeHandle account);
  LoomVodozemacPublicInventory accountInventory(
    LoomVodozemacNativeHandle account,
  );
  LoomVodozemacPublicInventory preparePrekeys({
    required LoomVodozemacNativeHandle account,
    required int targetOneTimeKeyCount,
    required bool rotateFallback,
  });
  void markKeysPublished(LoomVodozemacNativeHandle account);
  bool forgetPreviousFallback(LoomVodozemacNativeHandle account);

  LoomVodozemacNativeHandle importSession(Uint8List stateBytes);
  Uint8List exportSession(LoomVodozemacNativeHandle session);
  String sessionId(LoomVodozemacNativeHandle session);
  LoomVodozemacNativeHandle createOutboundSession({
    required LoomVodozemacNativeHandle account,
    required Object remoteIdentityKey,
    required Object remoteOneTimeKey,
  });
  LoomVodozemacNativeInbound createInboundSession({
    required LoomVodozemacNativeHandle account,
    required Object remoteIdentityKey,
    required Object message,
  });
  Object encrypt({
    required LoomVodozemacNativeHandle session,
    required Uint8List plaintext,
  });
  Uint8List decrypt({
    required LoomVodozemacNativeHandle session,
    required Object message,
  });
  void closeHandle(LoomVodozemacNativeHandle handle);
}

void loomZeroBytes(Uint8List bytes) {
  bytes.fillRange(0, bytes.length, 0);
}

final class LoomVodozemacHandleEngineException implements Exception {
  const LoomVodozemacHandleEngineException(this.code);
  final String code;

  @override
  String toString() => 'LoomVodozemacHandleEngineException($code)';
}
