import 'dart:typed_data';

import 'session_contracts.dart';

/// Protected device-local state owned by a session provider rather than one
/// remote peer session. Examples include an asynchronous prekey account and its
/// unpublished/published one-time-key inventory.
final class LoomProviderStateRecord {
  LoomProviderStateRecord({
    required this.stateId,
    required this.stateKind,
    required this.revision,
    required Uint8List protectedState,
    required this.createdAt,
    required this.updatedAt,
  }) : protectedState = Uint8List.fromList(protectedState) {
    validate();
  }

  final String stateId;
  final String stateKind;
  final int revision;
  final Uint8List protectedState;
  final DateTime createdAt;
  final DateTime updatedAt;

  void validate() {
    _validateId(stateId, 'provider state id', maxLength: 256);
    _validateId(stateKind, 'provider state kind', maxLength: 128);
    if (revision < 0) {
      throw const FormatException(
        'Provider state revision must be non-negative',
      );
    }
    if (protectedState.isEmpty || protectedState.length > 2 * 1024 * 1024) {
      throw const FormatException('Provider protected state exceeds bounds');
    }
    final created = createdAt.toUtc();
    final updated = updatedAt.toUtc();
    if (updated.isBefore(created)) {
      throw const FormatException('Provider state update predates creation');
    }
  }
}

/// Additional transaction capability required by providers whose local account
/// or prekey inventory mutates during session establishment.
///
/// Implementations MUST commit these writes in the same database transaction as
/// the resulting [LoomSessionRecord]. This is intentionally an additive
/// capability rather than a breaking expansion of [LoomCryptoTransaction].
abstract interface class LoomProviderStateTransaction {
  Future<LoomProviderStateRecord?> readProviderState(String stateId);

  /// CAS semantics mirror session-state writes:
  ///
  /// * `expectedRevision == null` creates revision zero only;
  /// * otherwise persisted revision must equal [expectedRevision] and the new
  ///   revision must be exactly `expectedRevision + 1`.
  Future<void> writeProviderState(
    LoomProviderStateRecord state, {
    required int? expectedRevision,
  });
}

/// Transaction capability required for first inbound asynchronous/prekey
/// session establishment.
abstract interface class LoomSessionBootstrapTransaction
    implements LoomCryptoTransaction, LoomProviderStateTransaction {}

LoomSessionBootstrapTransaction requireLoomSessionBootstrapTransaction(
  LoomCryptoTransaction transaction,
) {
  if (transaction is! LoomSessionBootstrapTransaction) {
    throw StateError(
      'Crypto transaction cannot atomically persist provider prekey/account state',
    );
  }
  return transaction;
}

/// Result of atomically consuming a first inbound asynchronous/prekey message.
final class LoomInboundSessionBootstrapResult {
  LoomInboundSessionBootstrapResult({
    required this.sessionId,
    required Uint8List plaintext,
  }) : plaintext = Uint8List.fromList(plaintext) {
    _validateId(sessionId, 'session id', maxLength: 256);
    if (this.plaintext.isEmpty || this.plaintext.length > 1024 * 1024) {
      throw const FormatException('Inbound bootstrap plaintext exceeds bounds');
    }
  }

  final String sessionId;
  final Uint8List plaintext;
}

/// Optional provider capability for the first inbound prekey message.
///
/// [verifiedRemoteSessionIdentity] must come from the already verified device
/// authorization/contact-key layer, never from unauthenticated transport data.
/// [bootstrapReplayKey] is an opaque locally derived key that is consumed in the
/// same transaction so a first-message replay cannot create a second session.
abstract interface class LoomInboundSessionBootstrapProvider {
  String get bootstrapProtocolVersion;

  Future<LoomInboundSessionBootstrapResult> establishIncomingAndDecrypt({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
    required Uint8List verifiedRemoteSessionIdentity,
    required LoomSessionCiphertext ciphertext,
    required String bootstrapReplayKey,
    required DateTime now,
  });
}

void _validateId(String value, String label, {int maxLength = 128}) {
  if (value.trim() != value ||
      value.length < 4 ||
      value.length > maxLength ||
      value.contains('\u0000') ||
      value.contains('\r') ||
      value.contains('\n')) {
    throw FormatException('Invalid $label');
  }
}
