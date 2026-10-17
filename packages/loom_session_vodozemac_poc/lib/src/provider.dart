import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:crypto/crypto.dart';

import 'engine.dart';
import 'prekey_bundle.dart';

final class LoomVodozemacPocInboundResult {
  LoomVodozemacPocInboundResult({
    required this.sessionId,
    required Uint8List plaintext,
  }) : plaintext = Uint8List.fromList(plaintext);

  final String sessionId;
  final Uint8List plaintext;
}

/// Non-shipping provider adapter that composes vodozemac with Loom's durable
/// transaction and protected-state boundaries.
///
/// This class exists to validate the composition. It is deliberately protocol-
/// tagged as a PoC and MUST NOT be enabled by the production Flutter composition
/// root until the provider/security/license review is explicitly closed.
final class LoomVodozemacPocSessionProvider
    implements LoomSessionCryptoProvider {
  LoomVodozemacPocSessionProvider({
    required this.engine,
    required this.stateProtector,
    this.localAccountStateId = 'vodozemac-poc-account-v1',
  });

  static const String providerStateKind = 'vodozemac-olm-account-poc-v1';
  static const String remoteRevocationStateKind =
      'vodozemac-remote-device-revocation-poc-v1';
  static const Duration replayRetention = Duration(days: 30);

  final LoomVodozemacPocEngine engine;
  final LoomSessionStateProtector stateProtector;
  final String localAccountStateId;

  @override
  String get protocolVersion => LoomVodozemacPocPrekeyBundle.protocol;

  /// Creates the local Olm account and returns one unpublished public prekey.
  ///
  /// The caller should upload the returned bundle through the verified device
  /// directory and call [markLocalPrekeysPublished] only after that publication
  /// is durably acknowledged. This PoC currently bootstraps once; replenishment
  /// is intentionally left behind the provider-review gate.
  Future<LoomVodozemacPocPrekeyBundle> createLocalPrekeyBundle({
    required LoomCryptoTransaction transaction,
    required DateTime now,
    int oneTimeKeyCount = 8,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    if (oneTimeKeyCount < 1 || oneTimeKeyCount > 100) {
      throw ArgumentError.value(oneTimeKeyCount, 'oneTimeKeyCount');
    }
    if (await bootstrap.readProviderState(localAccountStateId) != null) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC local account already exists',
      );
    }

    final account = await engine.createAccount(
      oneTimeKeyCount: oneTimeKeyCount,
    );
    if (account.oneTimeKeys.isEmpty) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC engine did not create a one-time key',
      );
    }
    final protected = await _protectString(
      contextId: localAccountStateId,
      revision: 0,
      value: account.accountPickle,
    );
    final timestamp = now.toUtc();
    await bootstrap.writeProviderState(
      LoomProviderStateRecord(
        stateId: localAccountStateId,
        stateKind: providerStateKind,
        revision: 0,
        protectedState: protected,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
      expectedRevision: null,
    );
    return LoomVodozemacPocPrekeyBundle(
      identityKey: account.curve25519,
      oneTimeKey: account.oneTimeKeys.first,
    );
  }

  Future<void> markLocalPrekeysPublished({
    required LoomCryptoTransaction transaction,
    required DateTime now,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final state = await bootstrap.readProviderState(localAccountStateId);
    if (state == null) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC local account is missing',
      );
    }
    _validateProviderState(state);
    final accountPickle = await _unprotectString(
      contextId: state.stateId,
      revision: state.revision,
      protectedState: state.protectedState,
    );
    final updatedPickle = await engine.markKeysPublished(accountPickle);
    final nextRevision = state.revision + 1;
    final protected = await _protectString(
      contextId: state.stateId,
      revision: nextRevision,
      value: updatedPickle,
    );
    await bootstrap.writeProviderState(
      LoomProviderStateRecord(
        stateId: state.stateId,
        stateKind: state.stateKind,
        revision: nextRevision,
        protectedState: protected,
        createdAt: state.createdAt,
        updatedAt: now.toUtc(),
      ),
      expectedRevision: state.revision,
    );
  }

  @override
  Future<String> establishOutgoing({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
    required Uint8List verifiedPrekeyBundle,
  }) async {
    remoteDevice.validate();
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    if (await _isRemoteDeviceRevoked(transaction, remoteDevice)) {
      throw const LoomCryptoStateConflict(
        'Cannot establish a session to a revoked remote device',
      );
    }
    final accountState = await bootstrap.readProviderState(localAccountStateId);
    if (accountState == null) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC local account is missing',
      );
    }
    _validateProviderState(accountState);
    final bundle = LoomVodozemacPocPrekeyBundle.decode(verifiedPrekeyBundle);
    final accountPickle = await _unprotectString(
      contextId: accountState.stateId,
      revision: accountState.revision,
      protectedState: accountState.protectedState,
    );
    final established = await engine.createOutboundSession(
      accountPickle: accountPickle,
      remoteIdentityKey: bundle.identityKey,
      remoteOneTimeKey: bundle.oneTimeKey,
    );
    _validateSessionId(established.sessionId);
    if (await transaction.readSession(established.sessionId) != null) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC session already exists',
      );
    }
    final now = DateTime.now().toUtc();
    final protected = await _protectString(
      contextId: established.sessionId,
      revision: 0,
      value: established.sessionPickle,
    );
    await transaction.writeSession(
      LoomSessionRecord(
        sessionId: established.sessionId,
        remoteDevice: remoteDevice,
        protocolVersion: protocolVersion,
        mode: LoomCryptoSessionMode.active,
        revision: 0,
        protectedState: protected,
        createdAt: now,
        updatedAt: now,
      ),
      expectedRevision: null,
    );
    return established.sessionId;
  }

  @override
  Future<LoomCryptoOutboxRecord> encryptAndStage({
    required LoomCryptoTransaction transaction,
    required String sessionId,
    required String operationId,
    required String messageId,
    required String packetId,
    required Uint8List innerEnvelope,
    required DateTime now,
  }) async {
    final existing = await transaction.readOutbox(operationId);
    if (existing != null) {
      if (existing.sessionId != sessionId ||
          existing.messageId != messageId ||
          existing.packetId != packetId ||
          existing.ciphertext.protocolVersion != protocolVersion) {
        throw const LoomCryptoStateConflict(
          'Vodozemac PoC operation id conflicts with committed outbox state',
        );
      }
      return existing;
    }

    final session = await transaction.readSession(sessionId);
    if (session == null) {
      throw const LoomCryptoStateConflict('Vodozemac PoC session is missing');
    }
    _validateSendableSession(session);
    if (await _isRemoteDeviceRevoked(transaction, session.remoteDevice)) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC remote device is revoked; new sends are disabled',
      );
    }
    final pickle = await _unprotectString(
      contextId: session.sessionId,
      revision: session.revision,
      protectedState: session.protectedState,
    );
    final encrypted = await engine.encrypt(
      sessionPickle: pickle,
      plaintext: innerEnvelope,
    );
    if (encrypted.sessionId != session.sessionId) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC engine changed the session identity during encryption',
      );
    }

    final ciphertextBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(encrypted.message)),
    );
    if (ciphertextBytes.isEmpty || ciphertextBytes.length > 1024 * 1024) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC ciphertext exceeds Loom bounds',
      );
    }

    final nextRevision = session.revision + 1;
    final protected = await _protectString(
      contextId: session.sessionId,
      revision: nextRevision,
      value: encrypted.sessionPickle,
    );
    await transaction.writeSession(
      LoomSessionRecord(
        sessionId: session.sessionId,
        remoteDevice: session.remoteDevice,
        protocolVersion: session.protocolVersion,
        mode: session.mode,
        revision: nextRevision,
        protectedState: protected,
        createdAt: session.createdAt,
        updatedAt: now.toUtc(),
      ),
      expectedRevision: session.revision,
    );

    final record = LoomCryptoOutboxRecord(
      operationId: operationId,
      sessionId: session.sessionId,
      sessionRevision: nextRevision,
      messageId: messageId,
      packetId: packetId,
      ciphertext: LoomSessionCiphertext(
        protocolVersion: protocolVersion,
        sessionLocator: session.sessionId,
        bytes: ciphertextBytes,
      ),
      createdAt: now.toUtc(),
    );
    await transaction.putOutbox(record);
    return record;
  }

  @override
  Future<Uint8List> decryptAndAdvance({
    required LoomCryptoTransaction transaction,
    required LoomSessionCiphertext ciphertext,
    required DateTime now,
  }) async {
    _validateCiphertext(ciphertext);
    final replayKey = _replayKey(ciphertext);
    if (await transaction.isReplayConsumed(replayKey)) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC ciphertext replay was already consumed',
      );
    }
    final session = await transaction.readSession(ciphertext.sessionLocator);
    if (session == null) {
      throw const LoomCryptoStateConflict('Vodozemac PoC session is missing');
    }
    if (session.protocolVersion != protocolVersion ||
        (session.mode != LoomCryptoSessionMode.active &&
            session.mode != LoomCryptoSessionMode.receiveOnly)) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC session cannot receive ciphertext',
      );
    }

    final pickle = await _unprotectString(
      contextId: session.sessionId,
      revision: session.revision,
      protectedState: session.protectedState,
    );
    final decrypted = await engine.decrypt(
      sessionPickle: pickle,
      message: _decodeMessage(ciphertext.bytes),
    );
    if (decrypted.sessionId != session.sessionId) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC engine changed the session identity during decryption',
      );
    }
    final nextRevision = session.revision + 1;
    final protected = await _protectString(
      contextId: session.sessionId,
      revision: nextRevision,
      value: decrypted.sessionPickle,
    );
    await transaction.writeSession(
      LoomSessionRecord(
        sessionId: session.sessionId,
        remoteDevice: session.remoteDevice,
        protocolVersion: session.protocolVersion,
        mode: session.mode,
        revision: nextRevision,
        protectedState: protected,
        createdAt: session.createdAt,
        updatedAt: now.toUtc(),
      ),
      expectedRevision: session.revision,
    );
    await transaction.markReplayConsumed(
      replayKey,
      now.toUtc().add(replayRetention),
    );
    return Uint8List.fromList(decrypted.plaintext);
  }

  /// Handles the first inbound Olm pre-key message. Account one-time-key
  /// consumption and new session creation are staged through the same
  /// [LoomSessionBootstrapTransaction].
  Future<LoomVodozemacPocInboundResult> decryptInitialPrekey({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
    required Object verifiedRemoteIdentityKey,
    required LoomSessionCiphertext ciphertext,
    required DateTime now,
  }) async {
    remoteDevice.validate();
    _validateCiphertext(ciphertext);
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final replayKey = _replayKey(ciphertext);
    if (await transaction.isReplayConsumed(replayKey)) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC pre-key replay was already consumed',
      );
    }
    if (await transaction.readSession(ciphertext.sessionLocator) != null) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC inbound session already exists',
      );
    }

    final accountState = await bootstrap.readProviderState(localAccountStateId);
    if (accountState == null) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC local account is missing',
      );
    }
    _validateProviderState(accountState);
    final accountPickle = await _unprotectString(
      contextId: accountState.stateId,
      revision: accountState.revision,
      protectedState: accountState.protectedState,
    );
    final inbound = await engine.createInboundSession(
      accountPickle: accountPickle,
      remoteIdentityKey: verifiedRemoteIdentityKey,
      message: _decodeMessage(ciphertext.bytes),
    );
    if (inbound.sessionId != ciphertext.sessionLocator) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC inbound session locator does not match engine session id',
      );
    }
    _validateSessionId(inbound.sessionId);

    final accountRevision = accountState.revision + 1;
    final protectedAccount = await _protectString(
      contextId: accountState.stateId,
      revision: accountRevision,
      value: inbound.accountPickle,
    );
    final protectedSession = await _protectString(
      contextId: inbound.sessionId,
      revision: 0,
      value: inbound.sessionPickle,
    );
    final timestamp = now.toUtc();
    await bootstrap.writeProviderState(
      LoomProviderStateRecord(
        stateId: accountState.stateId,
        stateKind: accountState.stateKind,
        revision: accountRevision,
        protectedState: protectedAccount,
        createdAt: accountState.createdAt,
        updatedAt: timestamp,
      ),
      expectedRevision: accountState.revision,
    );
    await transaction.writeSession(
      LoomSessionRecord(
        sessionId: inbound.sessionId,
        remoteDevice: remoteDevice,
        protocolVersion: protocolVersion,
        mode: LoomCryptoSessionMode.active,
        revision: 0,
        protectedState: protectedSession,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
      expectedRevision: null,
    );
    await transaction.markReplayConsumed(
      replayKey,
      timestamp.add(replayRetention),
    );
    return LoomVodozemacPocInboundResult(
      sessionId: inbound.sessionId,
      plaintext: inbound.plaintext,
    );
  }

  /// Revocation is represented by a durable device-scoped marker that every
  /// future session establishment/send checks inside the same crypto
  /// transaction. This fails closed even on stores that cannot yet enumerate
  /// historical sessions. Delayed inbound traffic remains decryptable during
  /// the receive window.
  ///
  /// When the transaction also exposes [LoomSessionInventoryTransaction],
  /// existing sessions are additionally migrated to `receiveOnly` while their
  /// protected state is re-bound to the incremented revision.
  @override
  Future<void> markRemoteDeviceRevoked({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
  }) async {
    remoteDevice.validate();
    final providerTransaction = _requireProviderStateTransaction(transaction);
    final stateId = _revocationStateId(remoteDevice);
    final existing = await providerTransaction.readProviderState(stateId);
    if (existing == null) {
      final protected = await _protectString(
        contextId: stateId,
        revision: 0,
        value: 'revoked',
      );
      final now = DateTime.now().toUtc();
      await providerTransaction.writeProviderState(
        LoomProviderStateRecord(
          stateId: stateId,
          stateKind: remoteRevocationStateKind,
          revision: 0,
          protectedState: protected,
          createdAt: now,
          updatedAt: now,
        ),
        expectedRevision: null,
      );
    } else if (existing.stateKind != remoteRevocationStateKind) {
      throw const LoomCryptoStateConflict(
        'Remote-device revocation state id conflicts with another provider state',
      );
    }

    if (transaction is! LoomSessionInventoryTransaction) return;
    final sessions = await (transaction as LoomSessionInventoryTransaction)
        .listSessionsForRemoteDevice(
      remoteDevice,
    );
    final now = DateTime.now().toUtc();
    for (final session in sessions) {
      if (session.protocolVersion != protocolVersion ||
          session.mode == LoomCryptoSessionMode.receiveOnly ||
          session.mode == LoomCryptoSessionMode.revoked ||
          session.mode == LoomCryptoSessionMode.expired) {
        continue;
      }
      final pickle = await _unprotectString(
        contextId: session.sessionId,
        revision: session.revision,
        protectedState: session.protectedState,
      );
      final nextRevision = session.revision + 1;
      final protected = await _protectString(
        contextId: session.sessionId,
        revision: nextRevision,
        value: pickle,
      );
      await transaction.writeSession(
        LoomSessionRecord(
          sessionId: session.sessionId,
          remoteDevice: session.remoteDevice,
          protocolVersion: session.protocolVersion,
          mode: LoomCryptoSessionMode.receiveOnly,
          revision: nextRevision,
          protectedState: protected,
          createdAt: session.createdAt,
          updatedAt: now,
        ),
        expectedRevision: session.revision,
      );
    }
  }

  Future<bool> _isRemoteDeviceRevoked(
    LoomCryptoTransaction transaction,
    LoomRemoteDeviceRef remoteDevice,
  ) async {
    final providerTransaction = _requireProviderStateTransaction(transaction);
    final state = await providerTransaction.readProviderState(
      _revocationStateId(remoteDevice),
    );
    if (state == null) return false;
    if (state.stateKind != remoteRevocationStateKind) {
      throw const LoomCryptoStateConflict(
        'Remote-device revocation state is invalid',
      );
    }
    return true;
  }

  static LoomProviderStateTransaction _requireProviderStateTransaction(
    LoomCryptoTransaction transaction,
  ) {
    if (transaction is! LoomProviderStateTransaction) {
      throw StateError(
        'Crypto transaction cannot persist provider revocation state atomically',
      );
    }
    return transaction as LoomProviderStateTransaction;
  }

  static String _revocationStateId(LoomRemoteDeviceRef remoteDevice) {
    final digest = sha256.convert(
      utf8.encode(
        '${remoteDevice.accountId}\u0000${remoteDevice.deviceId}\u0000'
        '${remoteDevice.deviceKeyVersion}',
      ),
    );
    return 'vodozemac-poc-revocation:$digest';
  }

  Future<Uint8List> _protectString({
    required String contextId,
    required int revision,
    required String value,
  }) =>
      stateProtector.protect(
        contextId: contextId,
        revision: revision,
        plaintext: Uint8List.fromList(utf8.encode(value)),
      );

  Future<String> _unprotectString({
    required String contextId,
    required int revision,
    required Uint8List protectedState,
  }) async {
    final plaintext = await stateProtector.unprotect(
      contextId: contextId,
      revision: revision,
      protectedState: protectedState,
    );
    return utf8.decode(plaintext);
  }

  void _validateProviderState(LoomProviderStateRecord state) {
    state.validate();
    if (state.stateId != localAccountStateId ||
        state.stateKind != providerStateKind) {
      throw const LoomCryptoStateConflict(
        'Unexpected vodozemac PoC provider state identity',
      );
    }
  }

  void _validateSendableSession(LoomSessionRecord session) {
    session.validate();
    if (session.protocolVersion != protocolVersion ||
        session.mode != LoomCryptoSessionMode.active) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC session is not sendable',
      );
    }
  }

  void _validateCiphertext(LoomSessionCiphertext ciphertext) {
    ciphertext.validate();
    if (ciphertext.protocolVersion != protocolVersion) {
      throw const LoomCryptoStateConflict(
        'Unsupported vodozemac PoC ciphertext protocol',
      );
    }
    _validateSessionId(ciphertext.sessionLocator);
  }

  static Object _decodeMessage(Uint8List bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value == null) {
        throw const FormatException('Null Olm message');
      }
      return value;
    } on FormatException {
      throw const LoomCryptoStateConflict(
        'Invalid vodozemac PoC ciphertext encoding',
      );
    }
  }

  static String _replayKey(LoomSessionCiphertext ciphertext) {
    final prefix = utf8.encode(
      '${ciphertext.protocolVersion}\u0000${ciphertext.sessionLocator}\u0000',
    );
    return 'vodozemac-poc:${sha256.convert(<int>[
          ...prefix,
          ...ciphertext.bytes
        ])}';
  }

  static void _validateSessionId(String value) {
    if (value.trim() != value ||
        value.length < 8 ||
        value.length > 256 ||
        value.contains('\u0000') ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw const LoomCryptoStateConflict('Invalid vodozemac PoC session id');
    }
  }
}
