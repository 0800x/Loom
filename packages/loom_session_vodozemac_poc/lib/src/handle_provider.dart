import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:crypto/crypto.dart';

import 'handle_engine.dart';
import 'prekey_bundle.dart';

/// Byte-state vodozemac provider candidate. Protocol-tagged as PoC until the
/// remaining review/interoperability gates close, but unlike the validation
/// provider it never represents serialized Account/Session state as Dart String.
final class LoomVodozemacHandleSessionProvider
    implements LoomSessionCryptoProvider, LoomInboundSessionBootstrapProvider {
  LoomVodozemacHandleSessionProvider({
    required this.engine,
    required this.stateProtector,
    this.localAccountStateId = 'vodozemac-handle-account-v2',
  });

  static const String providerStateKind = 'vodozemac-olm-account-handle-poc-v2';
  static const String remoteRevocationStateKind =
      'vodozemac-remote-device-revocation-handle-v2';
  static const Duration replayRetention = Duration(days: 30);

  final LoomVodozemacHandleEngine engine;
  final LoomSessionStateProtector stateProtector;
  final String localAccountStateId;

  @override
  String get protocolVersion => LoomVodozemacPocPrekeyBundle.protocol;

  @override
  String get bootstrapProtocolVersion => protocolVersion;

  Future<LoomVodozemacPocPrekeyBundle> createLocalPrekeyBundle({
    required LoomCryptoTransaction transaction,
    required DateTime now,
    int oneTimeKeyCount = 50,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    if (await bootstrap.readProviderState(localAccountStateId) != null) {
      throw const LoomCryptoStateConflict(
        'Local provider account already exists',
      );
    }
    final handle = engine.createAccount(oneTimeKeyCount: oneTimeKeyCount);
    try {
      final inventory = engine.accountInventory(handle);
      if (inventory.oneTimeKeys.isEmpty) {
        throw const LoomCryptoStateConflict(
          'Provider produced no one-time key',
        );
      }
      final raw = engine.exportAccount(handle);
      final protected = await _protectSecret(
        contextId: localAccountStateId,
        revision: 0,
        raw: raw,
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
        identityKey: inventory.curve25519,
        oneTimeKey: inventory.oneTimeKeys.first,
        keyKind: LoomVodozemacPocPrekeyKind.oneTime,
      );
    } finally {
      engine.closeHandle(handle);
    }
  }

  Future<LoomVodozemacPublicInventory> prepareLocalPrekeys({
    required LoomCryptoTransaction transaction,
    required int targetOneTimeKeyCount,
    required bool rotateFallback,
    required DateTime now,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final state = await bootstrap.readProviderState(localAccountStateId);
    if (state == null) {
      throw const LoomCryptoStateConflict('Local provider account is missing');
    }
    _validateProviderState(state);
    final handle = await _importAccountState(state);
    try {
      final inventory = engine.preparePrekeys(
        account: handle,
        targetOneTimeKeyCount: targetOneTimeKeyCount,
        rotateFallback: rotateFallback,
      );
      await _persistAdvancedAccount(
        bootstrap: bootstrap,
        previous: state,
        handle: handle,
        now: now.toUtc(),
      );
      return inventory;
    } finally {
      engine.closeHandle(handle);
    }
  }

  Future<void> markLocalPrekeysPublished({
    required LoomCryptoTransaction transaction,
    required DateTime now,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final state = await bootstrap.readProviderState(localAccountStateId);
    if (state == null) {
      throw const LoomCryptoStateConflict('Local provider account is missing');
    }
    _validateProviderState(state);
    final handle = await _importAccountState(state);
    try {
      engine.markKeysPublished(handle);
      await _persistAdvancedAccount(
        bootstrap: bootstrap,
        previous: state,
        handle: handle,
        now: now.toUtc(),
      );
    } finally {
      engine.closeHandle(handle);
    }
  }

  Future<bool> forgetPreviousFallback({
    required LoomCryptoTransaction transaction,
    required DateTime now,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final state = await bootstrap.readProviderState(localAccountStateId);
    if (state == null) return false;
    _validateProviderState(state);
    final handle = await _importAccountState(state);
    try {
      final forgotten = engine.forgetPreviousFallback(handle);
      if (forgotten) {
        await _persistAdvancedAccount(
          bootstrap: bootstrap,
          previous: state,
          handle: handle,
          now: now.toUtc(),
        );
      }
      return forgotten;
    } finally {
      engine.closeHandle(handle);
    }
  }

  @override
  Future<String> establishOutgoing({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
    required Uint8List verifiedPrekeyBundle,
  }) async {
    remoteDevice.validate();
    if (await _isRemoteDeviceRevoked(transaction, remoteDevice)) {
      throw const LoomCryptoStateConflict('Remote device is revoked');
    }
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final accountState = await bootstrap.readProviderState(localAccountStateId);
    if (accountState == null) {
      throw const LoomCryptoStateConflict('Local provider account is missing');
    }
    _validateProviderState(accountState);
    final bundle = LoomVodozemacPocPrekeyBundle.decode(verifiedPrekeyBundle);
    final account = await _importAccountState(accountState);
    LoomVodozemacNativeHandle? session;
    try {
      session = engine.createOutboundSession(
        account: account,
        remoteIdentityKey: bundle.identityKey,
        remoteOneTimeKey: bundle.oneTimeKey,
      );
      final sessionId = engine.sessionId(session);
      _validateSessionId(sessionId);
      if (await transaction.readSession(sessionId) != null) {
        throw const LoomCryptoStateConflict('Provider session already exists');
      }
      final raw = engine.exportSession(session);
      final protected = await _protectSecret(
        contextId: sessionId,
        revision: 0,
        raw: raw,
      );
      final timestamp = DateTime.now().toUtc();
      await transaction.writeSession(
        LoomSessionRecord(
          sessionId: sessionId,
          remoteDevice: remoteDevice,
          protocolVersion: protocolVersion,
          mode: LoomCryptoSessionMode.active,
          revision: 0,
          protectedState: protected,
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
        expectedRevision: null,
      );
      return sessionId;
    } finally {
      if (session != null) engine.closeHandle(session);
      engine.closeHandle(account);
    }
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
          'Operation id conflicts with outbox',
        );
      }
      return existing;
    }
    final stored = await transaction.readSession(sessionId);
    if (stored == null) {
      throw const LoomCryptoStateConflict('Provider session is missing');
    }
    _validateSendableSession(stored);
    if (await _isRemoteDeviceRevoked(transaction, stored.remoteDevice)) {
      throw const LoomCryptoStateConflict('Remote device is revoked');
    }

    final handle = await _importSessionState(stored);
    try {
      final message = engine.encrypt(session: handle, plaintext: innerEnvelope);
      if (engine.sessionId(handle) != stored.sessionId) {
        throw const LoomCryptoStateConflict('Native session identity changed');
      }
      final ciphertextBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(message)),
      );
      if (ciphertextBytes.isEmpty || ciphertextBytes.length > 1024 * 1024) {
        throw const LoomCryptoStateConflict(
          'Provider ciphertext exceeds bounds',
        );
      }
      final nextRevision = stored.revision + 1;
      final raw = engine.exportSession(handle);
      final protected = await _protectSecret(
        contextId: stored.sessionId,
        revision: nextRevision,
        raw: raw,
      );
      await transaction.writeSession(
        LoomSessionRecord(
          sessionId: stored.sessionId,
          remoteDevice: stored.remoteDevice,
          protocolVersion: stored.protocolVersion,
          mode: stored.mode,
          revision: nextRevision,
          protectedState: protected,
          createdAt: stored.createdAt,
          updatedAt: now.toUtc(),
        ),
        expectedRevision: stored.revision,
      );
      final outbox = LoomCryptoOutboxRecord(
        operationId: operationId,
        sessionId: stored.sessionId,
        sessionRevision: nextRevision,
        messageId: messageId,
        packetId: packetId,
        ciphertext: LoomSessionCiphertext(
          protocolVersion: protocolVersion,
          sessionLocator: stored.sessionId,
          bytes: ciphertextBytes,
        ),
        createdAt: now.toUtc(),
      );
      await transaction.putOutbox(outbox);
      return outbox;
    } finally {
      engine.closeHandle(handle);
    }
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
      throw const LoomCryptoStateConflict('Ciphertext replay already consumed');
    }
    final stored = await transaction.readSession(ciphertext.sessionLocator);
    if (stored == null) {
      throw const LoomCryptoStateConflict('Provider session is missing');
    }
    if (stored.protocolVersion != protocolVersion ||
        (stored.mode != LoomCryptoSessionMode.active &&
            stored.mode != LoomCryptoSessionMode.receiveOnly)) {
      throw const LoomCryptoStateConflict('Provider session cannot receive');
    }
    final handle = await _importSessionState(stored);
    try {
      final plaintext = engine.decrypt(
        session: handle,
        message: _decodeMessage(ciphertext.bytes),
      );
      if (engine.sessionId(handle) != stored.sessionId) {
        loomZeroBytes(plaintext);
        throw const LoomCryptoStateConflict('Native session identity changed');
      }
      final nextRevision = stored.revision + 1;
      final raw = engine.exportSession(handle);
      final protected = await _protectSecret(
        contextId: stored.sessionId,
        revision: nextRevision,
        raw: raw,
      );
      await transaction.writeSession(
        LoomSessionRecord(
          sessionId: stored.sessionId,
          remoteDevice: stored.remoteDevice,
          protocolVersion: stored.protocolVersion,
          mode: stored.mode,
          revision: nextRevision,
          protectedState: protected,
          createdAt: stored.createdAt,
          updatedAt: now.toUtc(),
        ),
        expectedRevision: stored.revision,
      );
      await transaction.markReplayConsumed(
        replayKey,
        now.toUtc().add(replayRetention),
      );
      return plaintext;
    } finally {
      engine.closeHandle(handle);
    }
  }

  @override
  Future<LoomInboundSessionBootstrapResult> establishIncomingAndDecrypt({
    required LoomCryptoTransaction transaction,
    required LoomRemoteDeviceRef remoteDevice,
    required Uint8List verifiedRemoteSessionIdentity,
    required LoomSessionCiphertext ciphertext,
    required String bootstrapReplayKey,
    required DateTime now,
  }) async {
    remoteDevice.validate();
    _validateCiphertext(ciphertext);
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    if (await transaction.isReplayConsumed(bootstrapReplayKey)) {
      throw const LoomCryptoStateConflict('Inbound bootstrap replay consumed');
    }
    if (await transaction.readSession(ciphertext.sessionLocator) != null) {
      throw const LoomCryptoStateConflict('Inbound session already exists');
    }
    final accountState = await bootstrap.readProviderState(localAccountStateId);
    if (accountState == null) {
      throw const LoomCryptoStateConflict('Local provider account is missing');
    }
    _validateProviderState(accountState);
    final remoteIdentity = _decodeJsonBytes(verifiedRemoteSessionIdentity);
    final account = await _importAccountState(accountState);
    LoomVodozemacNativeHandle? session;
    Uint8List? plaintext;
    try {
      final inbound = engine.createInboundSession(
        account: account,
        remoteIdentityKey: remoteIdentity,
        message: _decodeMessage(ciphertext.bytes),
      );
      session = inbound.session;
      plaintext = inbound.plaintext;
      final sessionId = engine.sessionId(session);
      if (sessionId != ciphertext.sessionLocator) {
        throw const LoomCryptoStateConflict('Inbound session locator mismatch');
      }
      _validateSessionId(sessionId);
      final timestamp = now.toUtc();

      await _persistAdvancedAccount(
        bootstrap: bootstrap,
        previous: accountState,
        handle: account,
        now: timestamp,
      );
      final sessionRaw = engine.exportSession(session);
      final protectedSession = await _protectSecret(
        contextId: sessionId,
        revision: 0,
        raw: sessionRaw,
      );
      await transaction.writeSession(
        LoomSessionRecord(
          sessionId: sessionId,
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
        bootstrapReplayKey,
        timestamp.add(replayRetention),
      );
      final resultBytes = Uint8List.fromList(plaintext);
      return LoomInboundSessionBootstrapResult(
        sessionId: sessionId,
        plaintext: resultBytes,
      );
    } finally {
      if (plaintext != null) loomZeroBytes(plaintext);
      if (session != null) engine.closeHandle(session);
      engine.closeHandle(account);
    }
  }

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
      final raw = Uint8List.fromList(const <int>[1]);
      final protected = await _protectSecret(
        contextId: stateId,
        revision: 0,
        raw: raw,
      );
      final timestamp = DateTime.now().toUtc();
      await providerTransaction.writeProviderState(
        LoomProviderStateRecord(
          stateId: stateId,
          stateKind: remoteRevocationStateKind,
          revision: 0,
          protectedState: protected,
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
        expectedRevision: null,
      );
    } else if (existing.stateKind != remoteRevocationStateKind) {
      throw const LoomCryptoStateConflict('Invalid revocation state collision');
    }

    if (transaction is! LoomSessionInventoryTransaction) return;
    final sessions = await (transaction as LoomSessionInventoryTransaction)
        .listSessionsForRemoteDevice(remoteDevice);
    final timestamp = DateTime.now().toUtc();
    for (final session in sessions) {
      if (session.protocolVersion != protocolVersion ||
          session.mode == LoomCryptoSessionMode.receiveOnly ||
          session.mode == LoomCryptoSessionMode.revoked ||
          session.mode == LoomCryptoSessionMode.expired) {
        continue;
      }
      final raw = await stateProtector.unprotect(
        contextId: session.sessionId,
        revision: session.revision,
        protectedState: session.protectedState,
      );
      final nextRevision = session.revision + 1;
      final protected = await _protectSecret(
        contextId: session.sessionId,
        revision: nextRevision,
        raw: raw,
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
          updatedAt: timestamp,
        ),
        expectedRevision: session.revision,
      );
    }
  }

  Future<LoomVodozemacNativeHandle> _importAccountState(
    LoomProviderStateRecord state,
  ) async {
    final raw = await stateProtector.unprotect(
      contextId: state.stateId,
      revision: state.revision,
      protectedState: state.protectedState,
    );
    try {
      return engine.importAccount(raw);
    } finally {
      loomZeroBytes(raw);
    }
  }

  Future<LoomVodozemacNativeHandle> _importSessionState(
    LoomSessionRecord state,
  ) async {
    final raw = await stateProtector.unprotect(
      contextId: state.sessionId,
      revision: state.revision,
      protectedState: state.protectedState,
    );
    try {
      return engine.importSession(raw);
    } finally {
      loomZeroBytes(raw);
    }
  }

  Future<void> _persistAdvancedAccount({
    required LoomSessionBootstrapTransaction bootstrap,
    required LoomProviderStateRecord previous,
    required LoomVodozemacNativeHandle handle,
    required DateTime now,
  }) async {
    final nextRevision = previous.revision + 1;
    final raw = engine.exportAccount(handle);
    final protected = await _protectSecret(
      contextId: previous.stateId,
      revision: nextRevision,
      raw: raw,
    );
    await bootstrap.writeProviderState(
      LoomProviderStateRecord(
        stateId: previous.stateId,
        stateKind: previous.stateKind,
        revision: nextRevision,
        protectedState: protected,
        createdAt: previous.createdAt,
        updatedAt: now.toUtc(),
      ),
      expectedRevision: previous.revision,
    );
  }

  Future<Uint8List> _protectSecret({
    required String contextId,
    required int revision,
    required Uint8List raw,
  }) async {
    try {
      return await stateProtector.protect(
        contextId: contextId,
        revision: revision,
        plaintext: raw,
      );
    } finally {
      loomZeroBytes(raw);
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
      throw const LoomCryptoStateConflict('Invalid remote revocation state');
    }
    return true;
  }

  static LoomProviderStateTransaction _requireProviderStateTransaction(
    LoomCryptoTransaction transaction,
  ) {
    if (transaction is! LoomProviderStateTransaction) {
      throw StateError('Crypto transaction lacks provider-state capability');
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
    return 'vodozemac-handle-revocation:$digest';
  }

  void _validateProviderState(LoomProviderStateRecord state) {
    state.validate();
    if (state.stateId != localAccountStateId ||
        state.stateKind != providerStateKind) {
      throw const LoomCryptoStateConflict('Unexpected provider account state');
    }
  }

  void _validateSendableSession(LoomSessionRecord session) {
    session.validate();
    if (session.protocolVersion != protocolVersion ||
        session.mode != LoomCryptoSessionMode.active) {
      throw const LoomCryptoStateConflict('Provider session is not sendable');
    }
  }

  void _validateCiphertext(LoomSessionCiphertext ciphertext) {
    ciphertext.validate();
    if (ciphertext.protocolVersion != protocolVersion) {
      throw const LoomCryptoStateConflict(
        'Unsupported provider ciphertext protocol',
      );
    }
    _validateSessionId(ciphertext.sessionLocator);
  }

  static Object _decodeMessage(Uint8List bytes) => _decodeJsonBytes(bytes);

  static Object _decodeJsonBytes(Uint8List bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value == null) throw const FormatException('Null JSON value');
      return value;
    } on FormatException {
      throw const LoomCryptoStateConflict('Invalid provider wire JSON');
    }
  }

  static String _replayKey(LoomSessionCiphertext ciphertext) {
    final prefix = utf8.encode(
      '${ciphertext.protocolVersion}\u0000${ciphertext.sessionLocator}\u0000',
    );
    return 'vodozemac-handle:${sha256.convert(<int>[
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
      throw const LoomCryptoStateConflict('Invalid provider session id');
    }
  }
}
