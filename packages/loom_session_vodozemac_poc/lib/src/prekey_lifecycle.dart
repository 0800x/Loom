import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:crypto/crypto.dart';

import 'prekey_bundle.dart';
import 'provider.dart';

final class LoomVodozemacPocPrekeyPublicationItem {
  LoomVodozemacPocPrekeyPublicationItem({
    required this.prekeyId,
    required this.keyKind,
    required Uint8List bundle,
    required this.expiresAt,
  }) : bundle = Uint8List.fromList(bundle) {
    if (!RegExp(r'^vpk_[0-9a-f]{64}$').hasMatch(prekeyId)) {
      throw const FormatException(
        'Invalid vodozemac PoC prekey publication id',
      );
    }
    if (this.bundle.isEmpty || this.bundle.length > 16 * 1024) {
      throw const FormatException(
        'Invalid vodozemac PoC prekey publication bundle',
      );
    }
  }

  final String prekeyId;
  final LoomVodozemacPocPrekeyKind keyKind;
  final Uint8List bundle;
  final DateTime expiresAt;

  Map<String, Object?> toServerJson() => <String, Object?>{
        'prekeyId': prekeyId,
        'keyKind': keyKind.wireName,
        'bundleBase64': _base64UrlNoPadding(bundle),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };
}

final class LoomVodozemacPocPrekeyPublicationBatch {
  LoomVodozemacPocPrekeyPublicationBatch({
    required this.batchId,
    required List<LoomVodozemacPocPrekeyPublicationItem> items,
    required this.createdAt,
  }) : items = List.unmodifiable(items) {
    if (!RegExp(r'^vpb_[0-9a-f]{64}$').hasMatch(batchId)) {
      throw const FormatException('Invalid vodozemac PoC publication batch id');
    }
    if (this.items.isEmpty || this.items.length > 51) {
      throw const FormatException(
        'Invalid vodozemac PoC publication batch size',
      );
    }
    final ids = this.items.map((item) => item.prekeyId).toSet();
    if (ids.length != this.items.length) {
      throw const FormatException(
        'Duplicate vodozemac PoC prekey publication id',
      );
    }
    if (this
            .items
            .where(
              (item) => item.keyKind == LoomVodozemacPocPrekeyKind.fallback,
            )
            .length >
        1) {
      throw const FormatException(
        'Multiple fallback keys in one publication batch',
      );
    }
  }

  final String batchId;
  final List<LoomVodozemacPocPrekeyPublicationItem> items;
  final DateTime createdAt;

  bool get containsFallback =>
      items.any((item) => item.keyKind == LoomVodozemacPocPrekeyKind.fallback);
}

/// Network boundary used by the PoC lifecycle coordinator.
///
/// Implementations MUST return successfully only after the server has accepted
/// the exact stable PrekeyIds/bundles/expiries. Retrying the same batch must be
/// idempotent; `/api/v2/prekeys` provides that property.
abstract interface class LoomVodozemacPocPrekeyPublisher {
  Future<void> publish(LoomVodozemacPocPrekeyPublicationBatch batch);
}

/// Crash-safe publication/replenishment coordinator for the vodozemac PoC.
///
/// The three-step invariant is:
///
/// 1. generate keys and durably commit the advanced protected Account plus an
///    immutable pending publication batch;
/// 2. publish that exact batch over the network outside the SQLite transaction;
/// 3. after server success, atomically mark upstream keys published and advance
///    the durable publication metadata.
///
/// A crash after step 1 or 2 therefore retries the same PrekeyIds, bundles and
/// expiry timestamps. It never regenerates the private key merely because the
/// network acknowledgement was lost.
final class LoomVodozemacPocPrekeyLifecycle {
  LoomVodozemacPocPrekeyLifecycle({
    required this.provider,
    required this.transactionRunner,
    this.targetOneTimeKeys = 50,
    this.publicationLifetime = const Duration(days: 28),
    this.fallbackRotationLead = const Duration(days: 7),
    this.previousFallbackRetention = const Duration(days: 14),
  }) {
    if (targetOneTimeKeys < 1 || targetOneTimeKeys > 50) {
      throw ArgumentError.value(targetOneTimeKeys, 'targetOneTimeKeys');
    }
    if (publicationLifetime <= Duration.zero ||
        publicationLifetime > const Duration(days: 29)) {
      throw ArgumentError.value(publicationLifetime, 'publicationLifetime');
    }
    if (fallbackRotationLead <= Duration.zero ||
        fallbackRotationLead >= publicationLifetime) {
      throw ArgumentError.value(fallbackRotationLead, 'fallbackRotationLead');
    }
    if (previousFallbackRetention < const Duration(days: 7)) {
      throw ArgumentError.value(
        previousFallbackRetention,
        'previousFallbackRetention',
      );
    }
  }

  static const String publicationStateKind =
      'vodozemac-prekey-publication-poc-v1';
  static const int stateSchema = 1;

  final LoomVodozemacPocSessionProvider provider;
  final LoomCryptoTransactionRunner transactionRunner;
  final int targetOneTimeKeys;
  final Duration publicationLifetime;
  final Duration fallbackRotationLead;

  /// Must cover the DTN maximum packet lifetime plus safety margin. The default
  /// is 14 days for the current 7-day packet TTL policy.
  final Duration previousFallbackRetention;

  String get publicationStateId =>
      '${provider.localAccountStateId}-prekey-publication-v1';

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
    final publicationRecord = await bootstrap.readProviderState(
      publicationStateId,
    );
    final lifecycle = publicationRecord == null
        ? _PublicationLifecycleState.empty()
        : await _readLifecycle(publicationRecord);

    final pending = lifecycle.pending;
    if (pending != null) {
      if (pending.items.any(
        (item) => !item.expiresAt.toUtc().isAfter(timestamp),
      )) {
        throw const LoomCryptoStateConflict(
          'Pending vodozemac PoC prekey publication expired before acknowledgement',
        );
      }
      return pending;
    }

    var accountRecord = await bootstrap.readProviderState(
      provider.localAccountStateId,
    );
    if (accountRecord == null) {
      await provider.createLocalPrekeyBundle(
        transaction: transaction,
        now: timestamp,
        oneTimeKeyCount: targetOneTimeKeys,
      );
      accountRecord = await bootstrap.readProviderState(
        provider.localAccountStateId,
      );
    }
    if (accountRecord == null ||
        accountRecord.stateKind !=
            LoomVodozemacPocSessionProvider.providerStateKind) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC account state is unavailable for prekey publication',
      );
    }

    final accountPickle = await _unprotectString(accountRecord);
    final currentFallbackExpiry = lifecycle.currentFallbackExpiresAt;
    final rotateFallback = currentFallbackExpiry == null ||
        !currentFallbackExpiry.isAfter(timestamp.add(fallbackRotationLead));
    final inventory = await provider.engine.preparePrekeys(
      accountPickle: accountPickle,
      targetOneTimeKeyCount: targetOneTimeKeys,
      rotateFallback: rotateFallback,
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

    final batchId = _batchId(items, timestamp);
    final batch = LoomVodozemacPocPrekeyPublicationBatch(
      batchId: batchId,
      items: items,
      createdAt: timestamp,
    );

    final nextAccountRevision = accountRecord.revision + 1;
    final protectedAccount = await provider.stateProtector.protect(
      contextId: accountRecord.stateId,
      revision: nextAccountRevision,
      plaintext: Uint8List.fromList(utf8.encode(inventory.accountPickle)),
    );
    await bootstrap.writeProviderState(
      LoomProviderStateRecord(
        stateId: accountRecord.stateId,
        stateKind: accountRecord.stateKind,
        revision: nextAccountRevision,
        protectedState: protectedAccount,
        createdAt: accountRecord.createdAt,
        updatedAt: timestamp,
      ),
      expectedRevision: accountRecord.revision,
    );

    final pendingState = lifecycle.copyWith(pending: batch);
    await _writeLifecycle(
      bootstrap,
      previous: publicationRecord,
      lifecycle: pendingState,
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
    final publicationRecord = await bootstrap.readProviderState(
      publicationStateId,
    );
    if (publicationRecord == null) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC publication state is missing',
      );
    }
    final lifecycle = await _readLifecycle(publicationRecord);
    final pending = lifecycle.pending;
    if (pending == null) {
      if (lifecycle.lastAcknowledgedBatchId == batchId) return;
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC publication acknowledgement has no pending batch',
      );
    }
    if (pending.batchId != batchId) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC publication acknowledgement batch mismatch',
      );
    }

    final accountRecord = await bootstrap.readProviderState(
      provider.localAccountStateId,
    );
    if (accountRecord == null ||
        accountRecord.stateKind !=
            LoomVodozemacPocSessionProvider.providerStateKind) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC account state is missing during publication acknowledgement',
      );
    }
    final accountPickle = await _unprotectString(accountRecord);
    final markedPickle = await provider.engine.markKeysPublished(accountPickle);
    final nextAccountRevision = accountRecord.revision + 1;
    final protectedAccount = await provider.stateProtector.protect(
      contextId: accountRecord.stateId,
      revision: nextAccountRevision,
      plaintext: Uint8List.fromList(utf8.encode(markedPickle)),
    );
    await bootstrap.writeProviderState(
      LoomProviderStateRecord(
        stateId: accountRecord.stateId,
        stateKind: accountRecord.stateKind,
        revision: nextAccountRevision,
        protectedState: protectedAccount,
        createdAt: accountRecord.createdAt,
        updatedAt: timestamp,
      ),
      expectedRevision: accountRecord.revision,
    );

    final fallback = pending.items
        .where((item) => item.keyKind == LoomVodozemacPocPrekeyKind.fallback)
        .firstOrNull;
    final rotatedExistingFallback =
        fallback != null && lifecycle.currentFallbackId != null;
    final idle = lifecycle.copyWith(
      clearPending: true,
      lastAcknowledgedBatchId: batchId,
      currentFallbackId: fallback?.prekeyId ?? lifecycle.currentFallbackId,
      currentFallbackExpiresAt:
          fallback?.expiresAt ?? lifecycle.currentFallbackExpiresAt,
      previousFallbackRetainUntil: rotatedExistingFallback
          ? timestamp.add(previousFallbackRetention)
          : lifecycle.previousFallbackRetainUntil,
    );
    await _writeLifecycle(
      bootstrap,
      previous: publicationRecord,
      lifecycle: idle,
      now: timestamp,
    );
  }

  Future<void> cleanupRetiredFallback({
    required LoomCryptoTransaction transaction,
    required DateTime now,
  }) async {
    final bootstrap = requireLoomSessionBootstrapTransaction(transaction);
    final timestamp = now.toUtc();
    final publicationRecord = await bootstrap.readProviderState(
      publicationStateId,
    );
    if (publicationRecord == null) return;
    final lifecycle = await _readLifecycle(publicationRecord);
    final retainUntil = lifecycle.previousFallbackRetainUntil;
    if (lifecycle.pending != null ||
        retainUntil == null ||
        timestamp.isBefore(retainUntil)) {
      return;
    }

    final accountRecord = await bootstrap.readProviderState(
      provider.localAccountStateId,
    );
    if (accountRecord == null ||
        accountRecord.stateKind !=
            LoomVodozemacPocSessionProvider.providerStateKind) {
      throw const LoomCryptoStateConflict(
        'Vodozemac PoC account state is missing during fallback cleanup',
      );
    }
    final accountPickle = await _unprotectString(accountRecord);
    final cleanup = await provider.engine.forgetPreviousFallback(accountPickle);
    if (cleanup.forgotten) {
      final nextAccountRevision = accountRecord.revision + 1;
      final protectedAccount = await provider.stateProtector.protect(
        contextId: accountRecord.stateId,
        revision: nextAccountRevision,
        plaintext: Uint8List.fromList(utf8.encode(cleanup.accountPickle)),
      );
      await bootstrap.writeProviderState(
        LoomProviderStateRecord(
          stateId: accountRecord.stateId,
          stateKind: accountRecord.stateKind,
          revision: nextAccountRevision,
          protectedState: protectedAccount,
          createdAt: accountRecord.createdAt,
          updatedAt: timestamp,
        ),
        expectedRevision: accountRecord.revision,
      );
    }

    await _writeLifecycle(
      bootstrap,
      previous: publicationRecord,
      lifecycle: lifecycle.copyWith(clearPreviousFallbackRetainUntil: true),
      now: timestamp,
    );
  }

  Future<String> _unprotectString(LoomProviderStateRecord record) async {
    final bytes = await provider.stateProtector.unprotect(
      contextId: record.stateId,
      revision: record.revision,
      protectedState: record.protectedState,
    );
    return utf8.decode(bytes);
  }

  Future<_PublicationLifecycleState> _readLifecycle(
    LoomProviderStateRecord record,
  ) async {
    if (record.stateKind != publicationStateKind) {
      throw const LoomCryptoStateConflict(
        'Unexpected vodozemac PoC publication state kind',
      );
    }
    final bytes = await provider.stateProtector.unprotect(
      contextId: record.stateId,
      revision: record.revision,
      protectedState: record.protectedState,
    );
    return _PublicationLifecycleState.decode(bytes);
  }

  Future<void> _writeLifecycle(
    LoomSessionBootstrapTransaction transaction, {
    required LoomProviderStateRecord? previous,
    required _PublicationLifecycleState lifecycle,
    required DateTime now,
  }) async {
    final revision = previous == null ? 0 : previous.revision + 1;
    final protectedState = await provider.stateProtector.protect(
      contextId: publicationStateId,
      revision: revision,
      plaintext: lifecycle.encode(),
    );
    await transaction.writeProviderState(
      LoomProviderStateRecord(
        stateId: publicationStateId,
        stateKind: publicationStateKind,
        revision: revision,
        protectedState: protectedState,
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
    final material = StringBuffer('Loom-vodozemac-poc-batch-v1\u0000')
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

final class _PublicationLifecycleState {
  const _PublicationLifecycleState({
    required this.pending,
    required this.lastAcknowledgedBatchId,
    required this.currentFallbackId,
    required this.currentFallbackExpiresAt,
    required this.previousFallbackRetainUntil,
  });

  factory _PublicationLifecycleState.empty() =>
      const _PublicationLifecycleState(
        pending: null,
        lastAcknowledgedBatchId: null,
        currentFallbackId: null,
        currentFallbackExpiresAt: null,
        previousFallbackRetainUntil: null,
      );

  final LoomVodozemacPocPrekeyPublicationBatch? pending;
  final String? lastAcknowledgedBatchId;
  final String? currentFallbackId;
  final DateTime? currentFallbackExpiresAt;
  final DateTime? previousFallbackRetainUntil;

  Uint8List encode() {
    final pendingValue = pending == null
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
                    'expiresAt': item.expiresAt.toUtc().toIso8601String(),
                  },
                )
                .toList(growable: false),
          };
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'schema': LoomVodozemacPocPrekeyLifecycle.stateSchema,
          'pending': pendingValue,
          'lastAcknowledgedBatchId': lastAcknowledgedBatchId,
          'currentFallbackId': currentFallbackId,
          'currentFallbackExpiresAt':
              currentFallbackExpiresAt?.toUtc().toIso8601String(),
          'previousFallbackRetainUntil':
              previousFallbackRetainUntil?.toUtc().toIso8601String(),
        }),
      ),
    );
  }

  static _PublicationLifecycleState decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 256 * 1024) {
      throw const FormatException(
        'Invalid vodozemac PoC publication state size',
      );
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['schema'] != LoomVodozemacPocPrekeyLifecycle.stateSchema) {
      throw const FormatException(
        'Unsupported vodozemac PoC publication state',
      );
    }
    LoomVodozemacPocPrekeyPublicationBatch? pending;
    final pendingRaw = value['pending'];
    if (pendingRaw != null) {
      if (pendingRaw is! Map<String, dynamic> ||
          pendingRaw['batchId'] is! String ||
          pendingRaw['createdAt'] is! String ||
          pendingRaw['items'] is! List) {
        throw const FormatException(
          'Invalid vodozemac PoC pending publication',
        );
      }
      final items = <LoomVodozemacPocPrekeyPublicationItem>[];
      for (final raw in pendingRaw['items'] as List) {
        if (raw is! Map<String, dynamic> ||
            raw['prekeyId'] is! String ||
            raw['bundleBase64'] is! String ||
            raw['expiresAt'] is! String) {
          throw const FormatException('Invalid vodozemac PoC publication item');
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
    return _PublicationLifecycleState(
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
    );
  }

  _PublicationLifecycleState copyWith({
    LoomVodozemacPocPrekeyPublicationBatch? pending,
    bool clearPending = false,
    String? lastAcknowledgedBatchId,
    String? currentFallbackId,
    DateTime? currentFallbackExpiresAt,
    DateTime? previousFallbackRetainUntil,
    bool clearPreviousFallbackRetainUntil = false,
  }) =>
      _PublicationLifecycleState(
        pending: clearPending ? null : pending ?? this.pending,
        lastAcknowledgedBatchId:
            lastAcknowledgedBatchId ?? this.lastAcknowledgedBatchId,
        currentFallbackId: currentFallbackId ?? this.currentFallbackId,
        currentFallbackExpiresAt:
            currentFallbackExpiresAt ?? this.currentFallbackExpiresAt,
        previousFallbackRetainUntil: clearPreviousFallbackRetainUntil
            ? null
            : previousFallbackRetainUntil ?? this.previousFallbackRetainUntil,
      );

  static String? _nullableString(Object? value) {
    if (value == null) return null;
    if (value is! String || value.isEmpty || value.length > 128) {
      throw const FormatException('Invalid vodozemac PoC publication string');
    }
    return value;
  }

  static DateTime? _nullableDate(Object? value) {
    if (value == null) return null;
    if (value is! String || value.length > 64) {
      throw const FormatException('Invalid vodozemac PoC publication date');
    }
    return DateTime.parse(value).toUtc();
  }
}

extension _IterableFirstOrNull<T> on Iterable<T> {
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
  final suffix = List<String>.filled(padding, '=').join();
  final decoded = base64Url.decode('$value$suffix');
  return Uint8List.fromList(decoded);
}
