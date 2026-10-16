import 'dart:typed_data';

/// Protects serialized provider account/session state before it enters durable
/// storage.
///
/// Implementations should bind [contextId] and [revision] as authenticated data
/// so a protected blob cannot be silently transplanted to another provider
/// state record or revision. The wrapping key itself must not be stored in the
/// session database.
abstract interface class LoomSessionStateProtector {
  String get protectionScheme;

  Future<Uint8List> protect({
    required String contextId,
    required int revision,
    required Uint8List plaintext,
  });

  Future<Uint8List> unprotect({
    required String contextId,
    required int revision,
    required Uint8List protectedState,
  });
}

void validateLoomStateProtectionContext({
  required String contextId,
  required int revision,
}) {
  if (contextId.trim() != contextId ||
      contextId.length < 8 ||
      contextId.length > 256 ||
      contextId.contains('\u0000') ||
      contextId.contains('\r') ||
      contextId.contains('\n')) {
    throw const FormatException('Invalid protected-state context id');
  }
  if (revision < 0 || revision > 0x7fffffffffffffff) {
    throw const FormatException('Invalid protected-state revision');
  }
}
