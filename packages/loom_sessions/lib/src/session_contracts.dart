import 'dart:typed_data';

enum LoomCryptoSessionMode {
  noSession,
  establishing,
  active,
  receiveOnly,
  resetRequired,
  revoked,
  expired,
}

final class LoomCryptoStateConflict implements Exception {
  const LoomCryptoStateConflict(this.message);

  final String message;

  @override
  String toString() => 'LoomCryptoStateConflict: $message';
}

final class LoomRemoteDeviceRef {
  const LoomRemoteDeviceRef({
    required this.accountId,
    required this.deviceId,
    required this.deviceKeyVersion,
  });

  final String accountId;
  final String deviceId;
  final int deviceKeyVersion;

  void validate() {
    if (accountId.trim().isEmpty || accountId.length > 256) {
      throw const FormatException('Invalid remote account id');
    }
    if (deviceId.trim().isEmpty || deviceId.length > 256) {
      throw const FormatException('Invalid remote device id');
    }
    if (deviceKeyVersion < 1) {
      throw const FormatException('Invalid remote device key version');
    }
  }
}

final class LoomSessionRecord {
  LoomSessionRecord({
    required this.sessionId,
    required this.remoteDevice,
    required this.protocolVersion,
    required this.mode,
    required this.revision,
    required Uint8List protectedState,
    required this.createdAt,
    required this.updatedAt,
  }) : protectedState = Uint8List.fromList(protectedState);

  final String sessionId;
  final LoomRemoteDeviceRef remoteDevice;
  final String protocolVersion;
  final LoomCryptoSessionMode mode;
  final int revision;
  final Uint8List protectedState;
  final DateTime createdAt;
  final DateTime updatedAt;

  void validate() {
    if (sessionId.trim().isEmpty || sessionId.length > 256) {
      throw const FormatException('Invalid session id');
    }
    remoteDevice.validate();
    if (protocolVersion.trim().isEmpty || protocolVersion.length > 128) {
      throw const FormatException('Invalid session protocol version');
    }
    if (revision < 0) throw const FormatException('Invalid session revision');
    if (protectedState.isEmpty || protectedState.length > 1024 * 1024) {
      throw const FormatException('Invalid protected session state size');
    }
  }
}

final class LoomSessionCiphertext {
  LoomSessionCiphertext({
    required this.protocolVersion,
    required this.sessionLocator,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes);

  final String protocolVersion;
  final String sessionLocator;
  final Uint8List bytes;

  void validate({int maxBytes = 1024 * 1024}) {
    if (protocolVersion.trim().isEmpty || protocolVersion.length > 128) {
      throw const FormatException('Invalid ciphertext protocol version');
    }
    if (sessionLocator.trim().isEmpty || sessionLocator.length > 256) {
      throw const FormatException('Invalid session locator');
    }
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Invalid session ciphertext size');
    }
  }
}

final class LoomCryptoOutboxRecord {
  LoomCryptoOutboxRecord({
    required this.operationId,
    required this.sessionId,
    required this.sessionRevision,
    required this.messageId,
    required this.packetId,
    required this.ciphertext,
    required this.createdAt,
  });

  final String operationId;
  final String sessionId;
  final int sessionRevision;
  final String messageId;
  final String packetId;
  final LoomSessionCiphertext ciphertext;
  final DateTime createdAt;

  void validate() {
    if (operationId.trim().isEmpty || operationId.length > 256) {
      throw const FormatException('Invalid crypto outbox operation id');
    }
    if (sessionId.trim().isEmpty || sessionId.length > 256) {
      throw const FormatException('Invalid crypto outbox session id');
    }
    if (sessionRevision < 0) {
      throw const FormatException('Invalid crypto outbox session revision');
    }
    if (messageId.trim() != messageId ||
        messageId.length < 8 ||
        messageId.length > 128) {
      throw const FormatException('Invalid message id');
    }
    if (packetId.trim() != packetId ||
        packetId.length < 8 ||
        packetId.length > 128) {
      throw const FormatException('Invalid packet id');
    }
    ciphertext.validate();
  }
}

abstract interface class LoomCryptoTransaction {
  Future<LoomSessionRecord?> readSession(String sessionId);

  Future<LoomCryptoOutboxRecord?> readOutbox(String operationId);

  /// Creates or advances session state with compare-and-swap semantics.
  ///
  /// When [expectedRevision] is null the session must not already exist and
  /// [session.revision] must be zero. Otherwise the persisted revision must
  /// equal [expectedRevision] and [session.revision] must equal
  /// `expectedRevision + 1`. Implementations must fail closed on mismatch.
  Future<void> writeSession(
    LoomSessionRecord session, {
    required int? expectedRevision,
  });

  /// Stores the exact immutable ciphertext and stable packet identity that the
  /// routing layer will retry later. This write and the corresponding
  /// session-state advancement MUST commit in the same durable transaction.
  /// Reusing an operation id is allowed only when every persisted field,
  /// including PacketId and ciphertext bytes, is identical.
  Future<void> putOutbox(LoomCryptoOutboxRecord record);

  Future<void> markReplayConsumed(String replayKey, DateTime expiresAt);
  Future<bool> isReplayConsumed(String replayKey);
}

abstract interface class LoomCryptoTransactionRunner {
  Future<T> runDurably<T>(
    Future<T> Function(LoomCryptoTransaction transaction) operation,
  );
}

abstract interface class LoomSessionCryptoProvider {
  String get protocolVersion;

  /// Establishes an asynchronous session using externally verified device and
  /// prekey material. Implementations own protocol-specific validation.
  Future<String> establishOutgoing({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
    required Uint8List verifiedPrekeyBundle,
  });

  /// Derives a one-time message key, encrypts [innerEnvelope], advances session
  /// state, and writes the exact resulting ciphertext plus [packetId] to the
  /// crypto outbox. The provider MUST NOT expose a sendable ciphertext before
  /// the caller's durable transaction can commit the corresponding state
  /// advancement.
  ///
  /// Implementations should first check [LoomCryptoTransaction.readOutbox]
  /// for [operationId]. If a matching record already exists, return it instead
  /// of re-encrypting. This makes caller recovery after a successful commit but
  /// process crash idempotent.
  Future<LoomCryptoOutboxRecord> encryptAndStage({
    required LoomCryptoTransaction transaction,
    required String sessionId,
    required String operationId,
    required String messageId,
    required String packetId,
    required Uint8List innerEnvelope,
    required DateTime now,
  });

  /// Handles delayed, duplicated, and out-of-order messages. Implementations
  /// must bound skipped-key storage and fail safely when policy limits are hit.
  Future<Uint8List> decryptAndAdvance({
    required LoomCryptoTransaction transaction,
    required LoomSessionCiphertext ciphertext,
    required DateTime now,
  });

  Future<void> markRemoteDeviceRevoked({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
  });
}
