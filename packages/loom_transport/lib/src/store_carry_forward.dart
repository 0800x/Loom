import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';

const String loomRelayBundleKind = 'relay.bundle.v1';

class LoomRelayBundle {
  const LoomRelayBundle({
    required this.bundleId,
    required this.recipientTag,
    required this.createdAt,
    required this.expiresAt,
    required this.hopCount,
    required this.maxHops,
    required this.sealedPayload,
  });

  factory LoomRelayBundle.fromJson(Map<String, Object?> json) {
    String field(String key, {int max = 1024}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid relay bundle $key');
      }
      return value;
    }

    if (json['kind'] != loomRelayBundleKind || json['version'] != 1) {
      throw const FormatException('Unsupported relay bundle');
    }
    final createdAt = DateTime.tryParse(field('createdAt', max: 64))?.toUtc();
    final expiresAt = DateTime.tryParse(field('expiresAt', max: 64))?.toUtc();
    final hopCount = json['hopCount'];
    final maxHops = json['maxHops'];
    final sealed = json['sealedPayload'];
    if (createdAt == null ||
        expiresAt == null ||
        hopCount is! int ||
        maxHops is! int ||
        sealed is! Map<String, Object?>) {
      throw const FormatException('Invalid relay bundle fields');
    }
    final bundle = LoomRelayBundle(
      bundleId: field('bundleId', max: 256),
      recipientTag: field('recipientTag', max: 128),
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopCount: hopCount,
      maxHops: maxHops,
      sealedPayload: LoomRelaySealedPayload.fromJson(sealed),
    );
    return bundle;
  }

  final String bundleId;
  final String recipientTag;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int hopCount;
  final int maxHops;
  final LoomRelaySealedPayload sealedPayload;

  static const Duration maxLifetime = Duration(days: 7);
  static const int maxBundleBytes = 320 * 1024;
  static const int absoluteMaxHops = 8;

  List<int> associatedData() => utf8.encode(
    <String>[
      'Loom-Relay-Bundle-v1',
      bundleId,
      recipientTag,
      createdAt.toUtc().toIso8601String(),
      expiresAt.toUtc().toIso8601String(),
    ].join('\n'),
  );

  void validateFraming({required DateTime now}) {
    if (bundleId.isEmpty ||
        bundleId.length > 256 ||
        recipientTag.length < 16 ||
        recipientTag.length > 128) {
      throw const FormatException('Invalid relay bundle identifier');
    }
    if (!expiresAt.isAfter(createdAt) ||
        expiresAt.difference(createdAt) > maxLifetime) {
      throw const FormatException('Invalid relay bundle lifetime');
    }
    if (!expiresAt.isAfter(now))
      throw const FormatException('Relay bundle expired');
    if (createdAt.isAfter(now.add(const Duration(minutes: 10)))) {
      throw const FormatException('Relay bundle created too far in the future');
    }
    if (maxHops < 1 ||
        maxHops > absoluteMaxHops ||
        hopCount < 0 ||
        hopCount > maxHops) {
      throw const FormatException('Invalid relay hop bounds');
    }
    if (utf8.encode(jsonEncode(toJson())).length > maxBundleBytes) {
      throw const FormatException('Relay bundle exceeds size limit');
    }
  }

  LoomRelayBundle forwarded() {
    if (hopCount >= maxHops) throw StateError('Relay hop limit reached');
    return LoomRelayBundle(
      bundleId: bundleId,
      recipientTag: recipientTag,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopCount: hopCount + 1,
      maxHops: maxHops,
      sealedPayload: sealedPayload,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': loomRelayBundleKind,
    'version': 1,
    'bundleId': bundleId,
    'recipientTag': recipientTag,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'hopCount': hopCount,
    'maxHops': maxHops,
    'sealedPayload': sealedPayload.toJson(),
  };

  LoomStoredRelayBundle toStored() {
    final encoded = utf8.encode(jsonEncode(toJson()));
    return LoomStoredRelayBundle(
      bundleId: bundleId,
      recipientTag: recipientTag,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopCount: hopCount,
      maxHops: maxHops,
      payloadJson: toJson(),
      sizeBytes: encoded.length,
    );
  }
}

enum LoomRelayConsent { disabled, contactsOnly, trustedDevices, enabled }

class LoomRelayPolicy {
  const LoomRelayPolicy({
    this.consent = LoomRelayConsent.disabled,
    this.maxStoredBytes = 32 * 1024 * 1024,
    this.maxBundleBytes = 320 * 1024,
    this.maxAcceptedHops = 4,
  });

  final LoomRelayConsent consent;
  final int maxStoredBytes;
  final int maxBundleBytes;
  final int maxAcceptedHops;

  bool allows({
    required LoomRelayBundle bundle,
    required int currentlyStoredBytes,
    required bool peerIsContact,
    required bool peerIsTrustedDevice,
  }) {
    if (consent == LoomRelayConsent.disabled) return false;
    if (consent == LoomRelayConsent.contactsOnly && !peerIsContact)
      return false;
    if (consent == LoomRelayConsent.trustedDevices && !peerIsTrustedDevice)
      return false;
    if (bundle.hopCount >= bundle.maxHops || bundle.hopCount > maxAcceptedHops)
      return false;
    final size = utf8.encode(jsonEncode(bundle.toJson())).length;
    if (size > maxBundleBytes || currentlyStoredBytes + size > maxStoredBytes)
      return false;
    return true;
  }
}

/// Durable encounter spool. It never decrypts bundles while acting as relay.
class LoomStoreCarryForwardService {
  LoomStoreCarryForwardService({required this.store, required this.policy});

  final LoomRelayStore store;
  final LoomRelayPolicy policy;

  bool acceptForRelay({
    required LoomRelayBundle bundle,
    required DateTime now,
    required bool peerIsContact,
    required bool peerIsTrustedDevice,
  }) {
    bundle.validateFraming(now: now);
    if (store.contains(bundle.bundleId)) return false;
    final allowed = policy.allows(
      bundle: bundle,
      currentlyStoredBytes: store.totalBytes(now: now),
      peerIsContact: peerIsContact,
      peerIsTrustedDevice: peerIsTrustedDevice,
    );
    if (!allowed) return false;
    return store.putIfAbsent(bundle.toStored(), now: now);
  }

  List<LoomRelayBundle> bundlesForRecipient({
    required Set<String> recipientTags,
    required DateTime now,
  }) {
    return store
        .findByRecipientTags(recipientTags, now: now)
        .map((item) {
          final bundle = LoomRelayBundle.fromJson(item.payloadJson);
          bundle.validateFraming(now: now);
          return bundle;
        })
        .toList(growable: false);
  }

  List<LoomRelayBundle> bundlesForEncounter({
    required DateTime now,
    int limit = 32,
  }) {
    return store
        .nextForForwarding(now: now, limit: limit)
        .map((item) {
          final bundle = LoomRelayBundle.fromJson(item.payloadJson);
          bundle.validateFraming(now: now);
          return bundle.forwarded();
        })
        .toList(growable: false);
  }

  int maintenance(DateTime now) => store.pruneExpired(now);
}
