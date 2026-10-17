import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:crypto/crypto.dart';

import 'handle_engine.dart';
import 'handle_provider.dart';
import 'prekey_bundle.dart';
import 'prekey_lifecycle.dart';

/// Crash-safe publication/replenishment lifecycle for the opaque-handle
/// provider. Secret Account state never becomes a Dart String in this path.
///
/// Network I/O is deliberately outside the crypto transaction. The immutable
/// pending batch is committed together with any account/prekey advancement;
/// retry after an ACK loss republishes exactly the same ids/bundles/expiry.
final class LoomVodozemacHandlePrekeyLifecycle {
  LoomVodozemacHandlePrekeyLifecycle({
    required this.provider,
    required this.transactionRunner,
    this.targetOneTimeKeys = 50,
    this.publicationLifetime = const Duration(days: 28),
    this.fallbackRotationLead = const Duration(days: 7),
    this.previousFallbackRetention = const Duration(days: 14),
    LoomPrekeyRetirementPolicy? retirementPolicy,
  }) : retirementPolicy =
            retirementPolicy ?? const LoomPrekeyRetirementPolicy() {
    if (targetOneTimeKeys < 1 || targetOneTimeKeys > 50) {
      throw ArgumentError.value(targetOneTimeKeys, 'targetOneTimeKeys');
    }
    if (publicationLifetime <= Duration.zero ||
        publicationLifetime > const Duration(days: 29) ||
        fallbackRotationLead <= Duration.zero ||
        fallbackRotationLead >= publicationLifetime ||
        previousFallbackRetention < const Duration(days: 7)) {
      throw const FormatException(
        'Invalid handle prekey lifecycle timing policy',
      );
    }
  }

  static const String publicationStateKind =
      'vodozemac-prekey-publication-handle-v2';
  static const int stateSchema = 2;

  final LoomVodozemacHandleSessionProvider provider;
  final LoomCryptoTransactionRunner transactionRunner;
  final int targetOneTimeKeys;
  final Duration publicationLifetime;
  final Duration fallbackRotationLead;
  final Duration previousFallbackRetention;
  final LoomPrekeyRetirementPolicy retirementPolicy;

  String get publicationStateId =>
      '${provider.localAccountStateId}-prekey-publication-v2';

  Future<LoomVodozemacPocPrekeyPublicationBatch?> ensurePublished({
    required LoomVodozemacPocPrekeyPublisher publisher,
    required DateTime now,
  }) async {
    final timestamp = now.toUtc();
    await transactionRunner.runDurably<void>(
      (transaction) =>
          cleanupRetiredFallback(transaction: transaction, now: timestamp),
    );
    final batch = await transactionRunner.runDurably(
      (transaction) => prepareOrLoad(transaction: transaction, now: timestamp),
    );
    if (batch == null) return null;

    await publisher.publish(batch);
    await transactionRunner.runDurably<void>(
      (transaction) => acknowledgePublished(
        transaction: transaction,
        batchId: batch.batchId,
        now: timestamp,
      ),
    );
    return batch;
  }

  Future<LoomVodozemacPocPrekeyPublicationBatch?> prepareOrLoad({
    required LoomCryptoTransaction transaction,
    required DateTime now,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final timestamp = now.toUtc();
    final previous = await bootstrap.readProviderState(publicationStateId);
    final state = previous == null
        ? _HandlePublicationState.empty()
        : await _readState(previous);

    final pending = state.pending;
    if (pending != null) {
      if (pending.items.any(
        (item) => !item.expiresAt.toUtc().isAfter(timestamp),
      )) {
        throw const LoomCryptoStateConflict(
          'Pending handle prekey publication expired before acknowledgement',
        );
      }
      return pending;
    }

    var account = await bootstrap.readProviderState(
      provider.localAccountStateId,
    );
    if (account == null) {
      await provider.createLocalPrekeyBundle(
        transaction: transaction,
        now: timestamp,
        oneTimeKeyCount: targetOneTimeKeys,
      );
      account = await bootstrap.readProviderState(provider.localAccountStateId);
    }
    if (account == null ||
        account.stateKind !=
            LoomVodozemacHandleSessionProvider.providerStateKind) {
      throw const LoomCryptoStateConflict(
        'Handle provider account is unavailable for prekey publication',
      );
    }

    final rotateFallback = state.currentFallbackExpiresAt == null ||
        !state.currentFallbackExpiresAt!.isAfter(
          timestamp.add(fallbackRotationLead),
        );
    final inventory = await provider.prepareLocalPrekeys(
      transaction: transaction,
      targetOneTimeKeyCount: targetOneTimeKeys,
      rotateFallback: rotateFallback,
      now: timestamp,
    );
    final expiresAt = timestamp.add(publicationLifetime);
    final items = <LoomVodozemacPocPrekeyPublicationItem>[];
    for (final key in inventory.oneTimeKeys) {
      items.add(
        _publicationItem(
          identityKey: inventory.curve25519,
          prekey: key,
          kind: LoomVodozemacPocPrekeyKind.oneTime,
          expiresAt: expiresAt,
        ),
      );
    }
    for (final key in inventory.fallbackKeys) {
      items.add(
        _publicationItem(
          identityKey: inventory.curve25519,
          prekey: key,
          kind: LoomVodozemacPocPrekeyKind.fallback,
          expiresAt: expiresAt,
        ),
      );
    }
    items.sort((a, b) => a.prekeyId.compareTo(b.prekeyId));
    if (items.isEmpty) return null;

    final batch = LoomVodozemacPocPrekeyPublicationBatch(
      batchId: _batchId(items, timestamp),
      items: items,
      createdAt: timestamp,
    );
    final safeRetirementAfter = retirementPolicy.safeRetirementAfter(
      serverExpiresAt: expiresAt,
    );
    await _writeState(
      bootstrap,
      previous: previous,
      state: state.copyWith(
        pending: batch,
        latestOneTimeKeySafeRetirementAfter: safeRetirementAfter,
      ),
      now: timestamp,
    );
    return batch;
  }

  Future<void> acknowledgePublished({
    required LoomCryptoTransaction transaction,
    required String batchId,
    required DateTime now,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final timestamp = now.toUtc();
    final previous = await bootstrap.readProviderState(publicationStateId);
    if (previous == null) {
      throw const LoomCryptoStateConflict(
        'Handle publication state is missing',
      );
    }
    final state = await _readState(previous);
    final pending = state.pending;
    if (pending == null) {
      if (state.lastAcknowledgedBatchId == batchId) return;
      throw const LoomCryptoStateConflict(
        'Handle publication acknowledgement has no matching pending batch',
      );
    }
    if (pending.batchId != batchId) {
      throw const LoomCryptoStateConflict('Handle publication batch mismatch');
    }

    await provider.markLocalPrekeysPublished(
      transaction: transaction,
      now: timestamp,
    );

    final fallback = pending.items
        .where((item) => item.keyKind == LoomVodozemacPocPrekeyKind.fallback)
        .firstOrNull;
    final rotatedExistingFallback =
        fallback != null && state.currentFallbackId != null;
    await _writeState(
      bootstrap,
      previous: previous,
      state: state.copyWith(
        clearPending: true,
        lastAcknowledgedBatchId: batchId,
        currentFallbackId: fallback?.prekeyId ?? state.currentFallbackId,
        currentFallbackExpiresAt:
            fallback?.expiresAt ?? state.currentFallbackExpiresAt,
        previousFallbackRetainUntil: rotatedExistingFallback
            ? timestamp.add(previousFallbackRetention)
            : state.previousFallbackRetainUntil,
      ),
      now: timestamp,
    );
  }

  Future<void> cleanupRetiredFallback({
    required LoomCryptoTransaction transaction,
    required DateTime now,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final timestamp = now.toUtc();
    final previous = await bootstrap.readProviderState(publicationStateId);
    if (previous == null) return;
    final state = await _readState(previous);
    final retainUntil = state.previousFallbackRetainUntil;
    if (state.pending != null ||
        retainUntil == null ||
        timestamp.isBefore(retainUntil)) {
      return;
    }

    // vodozemac exposes an explicit operation only for the previous fallback.
    // It does not expose safe deletion of an arbitrary unused published OTK.
    // Those OTK private keys are therefore retained rather than risking a
    // claimed-but-delayed first DTN message.
    await provider.forgetPreviousFallback(
      transaction: transaction,
      now: timestamp,
    );
    await _writeState(
      bootstrap,
      previous: previous,
      state: state.copyWith(clearPreviousFallbackRetainUntil: true),
      now: timestamp,
    );
  }

  Future<_HandlePublicationState> _readState(
    LoomProviderStateRecord record,
  ) async {
    if (record.stateKind != publicationStateKind) {
      throw const LoomCryptoStateConflict(
        'Unexpected handle publication state kind',
      );
    }
    final raw = await provider.stateProtector.unprotect(
      contextId: record.stateId,
      revision: record.revision,
      protectedState: record.protectedState,
    );
    try {
      return _HandlePublicationState.decode(raw);
    } finally {
      loomZeroBytes(raw);
    }
  }

  Future<void> _writeState(
    LoomSessionBootstrapTransaction transaction, {
    required LoomProviderStateRecord? previous,
    required _HandlePublicationState state,
    required DateTime now,
  }) async {
    final revision = previous == null ? 0 : previous.revision + 1;
    final raw = state.encode();
    Uint8List protected;
    try {
      protected = await provider.stateProtector.protect(
        contextId: publicationStateId,
        revision: revision,
        plaintext: raw,
      );
    } finally {
      loomZeroBytes(raw);
    }
    await transaction.writeProviderState(
      LoomProviderStateRecord(
        stateId: publicationStateId,
        stateKind: publicationStateKind,
        revision: revision,
        protectedState: protected,
        createdAt: previous?.createdAt ?? now.toUtc(),
        updatedAt: now.toUtc(),
      ),
      expectedRevision: previous?.revision,
    );
  }

  static LoomVodozemacPocPrekeyPublicationItem _publicationItem({
    required Object identityKey,
    required Object prekey,
    required LoomVodozemacPocPrekeyKind kind,
    required DateTime expiresAt,
  }) {
    final bundle = LoomVodozemacPocPrekeyBundle(
      identityKey: identityKey,
      oneTimeKey: prekey,
      keyKind: kind,
    ).encode();
    final digest = sha256.convert(<int>[
      ...utf8.encode('Loom-vodozemac-poc-prekey-id-v1\u0000'),
      ...utf8.encode(kind.wireName),
      0,
      ...bundle,
    ]);
    return LoomVodozemacPocPrekeyPublicationItem(
      prekeyId: 'vpk_$digest',
      keyKind: kind,
      bundle: bundle,
      expiresAt: expiresAt.toUtc(),
    );
  }

  static String _batchId(
    List<LoomVodozemacPocPrekeyPublicationItem> items,
    DateTime createdAt,
  ) {
    final material = StringBuffer('Loom-vodozemac-handle-batch-v2\u0000')
      ..write(createdAt.toUtc().toIso8601String())
      ..write('\u0000');
    for (final item in items) {
      material
        ..write(item.prekeyId)
        ..write('\u0000')
        ..write(item.expiresAt.toUtc().toIso8601String())
        ..write('\u0000');
    }
    return 'vpb_${sha256.convert(utf8.encode(material.toString()))}';
  }
}

final class _HandlePublicationState {
  const _HandlePublicationState({
    required this.pending,
    required this.lastAcknowledgedBatchId,
    required this.currentFallbackId,
    required this.currentFallbackExpiresAt,
    required this.previousFallbackRetainUntil,
    required this.latestOneTimeKeySafeRetirementAfter,
  });

  factory _HandlePublicationState.empty() => const _HandlePublicationState(
        pending: null,
        lastAcknowledgedBatchId: null,
        currentFallbackId: null,
        currentFallbackExpiresAt: null,
        previousFallbackRetainUntil: null,
        latestOneTimeKeySafeRetirementAfter: null,
      );

  final LoomVodozemacPocPrekeyPublicationBatch? pending;
  final String? lastAcknowledgedBatchId;
  final String? currentFallbackId;
  final DateTime? currentFallbackExpiresAt;
  final DateTime? previousFallbackRetainUntil;
  final DateTime? latestOneTimeKeySafeRetirementAfter;

  Uint8List encode() => Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'schema': LoomVodozemacHandlePrekeyLifecycle.stateSchema,
            'pending': pending == null
                ? null
                : <String, Object?>{
                    'batchId': pending!.batchId,
                    'createdAt': pending!.createdAt.toUtc().toIso8601String(),
                    'items': pending!.items
                        .map(
                          (item) => <String, Object?>{
                            'prekeyId': item.prekeyId,
                            'keyKind': item.keyKind.wireName,
                            'bundleBase64': _base64UrlNoPadding(item.bundle),
                            'expiresAt':
                                item.expiresAt.toUtc().toIso8601String(),
                          },
                        )
                        .toList(growable: false),
                  },
            'lastAcknowledgedBatchId': lastAcknowledgedBatchId,
            'currentFallbackId': currentFallbackId,
            'currentFallbackExpiresAt':
                currentFallbackExpiresAt?.toUtc().toIso8601String(),
            'previousFallbackRetainUntil':
                previousFallbackRetainUntil?.toUtc().toIso8601String(),
            'latestOneTimeKeySafeRetirementAfter':
                latestOneTimeKeySafeRetirementAfter?.toUtc().toIso8601String(),
          }),
        ),
      );

  static _HandlePublicationState decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 256 * 1024) {
      throw const FormatException('Invalid handle publication state size');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['schema'] != LoomVodozemacHandlePrekeyLifecycle.stateSchema) {
      throw const FormatException('Unsupported handle publication state');
    }
    LoomVodozemacPocPrekeyPublicationBatch? pending;
    final pendingRaw = value['pending'];
    if (pendingRaw != null) {
      if (pendingRaw is! Map<String, dynamic> ||
          pendingRaw['batchId'] is! String ||
          pendingRaw['createdAt'] is! String ||
          pendingRaw['items'] is! List ||
          (pendingRaw['items'] as List).length > 51) {
        throw const FormatException('Invalid handle pending publication');
      }
      final items = <LoomVodozemacPocPrekeyPublicationItem>[];
      for (final raw in pendingRaw['items'] as List) {
        if (raw is! Map<String, dynamic> ||
            raw['prekeyId'] is! String ||
            raw['bundleBase64'] is! String ||
            raw['expiresAt'] is! String) {
          throw const FormatException('Invalid handle publication item');
        }
        items.add(
          LoomVodozemacPocPrekeyPublicationItem(
            prekeyId: raw['prekeyId'] as String,
            keyKind: LoomVodozemacPocPrekeyKind.parse(raw['keyKind']),
            bundle: _decodeBase64UrlNoPadding(raw['bundleBase64'] as String),
            expiresAt: DateTime.parse(raw['expiresAt'] as String).toUtc(),
          ),
        );
      }
      pending = LoomVodozemacPocPrekeyPublicationBatch(
        batchId: pendingRaw['batchId'] as String,
        items: items,
        createdAt: DateTime.parse(pendingRaw['createdAt'] as String).toUtc(),
      );
    }
    return _HandlePublicationState(
      pending: pending,
      lastAcknowledgedBatchId: _nullableString(
        value['lastAcknowledgedBatchId'],
      ),
      currentFallbackId: _nullableString(value['currentFallbackId']),
      currentFallbackExpiresAt: _nullableDate(
        value['currentFallbackExpiresAt'],
      ),
      previousFallbackRetainUntil: _nullableDate(
        value['previousFallbackRetainUntil'],
      ),
      latestOneTimeKeySafeRetirementAfter: _nullableDate(
        value['latestOneTimeKeySafeRetirementAfter'],
      ),
    );
  }

  _HandlePublicationState copyWith({
    LoomVodozemacPocPrekeyPublicationBatch? pending,
    bool clearPending = false,
    String? lastAcknowledgedBatchId,
    String? currentFallbackId,
    DateTime? currentFallbackExpiresAt,
    DateTime? previousFallbackRetainUntil,
    bool clearPreviousFallbackRetainUntil = false,
    DateTime? latestOneTimeKeySafeRetirementAfter,
  }) =>
      _HandlePublicationState(
        pending: clearPending ? null : pending ?? this.pending,
        lastAcknowledgedBatchId:
            lastAcknowledgedBatchId ?? this.lastAcknowledgedBatchId,
        currentFallbackId: currentFallbackId ?? this.currentFallbackId,
        currentFallbackExpiresAt:
            currentFallbackExpiresAt ?? this.currentFallbackExpiresAt,
        previousFallbackRetainUntil: clearPreviousFallbackRetainUntil
            ? null
            : previousFallbackRetainUntil ?? this.previousFallbackRetainUntil,
        latestOneTimeKeySafeRetirementAfter:
            latestOneTimeKeySafeRetirementAfter ??
                this.latestOneTimeKeySafeRetirementAfter,
      );

  static String? _nullableString(Object? value) {
    if (value == null) return null;
    if (value is! String || value.isEmpty || value.length > 128) {
      throw const FormatException('Invalid handle publication string');
    }
    return value;
  }

  static DateTime? _nullableDate(Object? value) {
    if (value == null) return null;
    if (value is! String || value.length > 64) {
      throw const FormatException('Invalid handle publication date');
    }
    final parsed = DateTime.tryParse(value)?.toUtc();
    if (parsed == null || parsed.year < 2020 || parsed.year >= 2200) {
      throw const FormatException('Invalid handle publication date');
    }
    return parsed;
  }
}

extension _HandleFirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

String _base64UrlNoPadding(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

Uint8List _decodeBase64UrlNoPadding(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid base64url value');
  }
  final padding = (4 - value.length % 4) % 4;
  final decoded = base64Url.decode(
    '$value${List<String>.filled(padding, '=').join()}',
  );
  if (decoded.isEmpty || decoded.length > 16 * 1024) {
    throw const FormatException('Invalid handle publication bundle');
  }
  return Uint8List.fromList(decoded);
}
