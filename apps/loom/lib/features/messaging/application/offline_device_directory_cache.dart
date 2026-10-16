import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';

typedef LoomOfflineBundleVerifier =
    Future<LoomDeviceKeyBundle> Function({
      required LoomDeviceKeyBundle bundle,
      required String identityId,
      required String identityPublicKey,
    });

/// Reads previously authenticated device-directory material from durable local
/// storage so direct-message encryption can proceed without a live Node lookup.
///
/// The cache never stores private key material. Cached public bundles are
/// cryptographically re-verified before use, unresolved key changes fail
/// closed, and revoked devices are never resurrected from older observations.
class LoomOfflineDeviceDirectoryCache {
  LoomOfflineDeviceDirectoryCache({
    required this._securityStore,
    required this._peerIdentityStore,
    LoomOfflineBundleVerifier? bundleVerifier,
    this.maxOfflineAge = const Duration(days: 7),
    this.allowedClockSkew = const Duration(minutes: 5),
  }) : _verifyBundle = bundleVerifier ?? LoomDeviceBundleVerifier().verify;

  final LoomSecurityStore _securityStore;
  final LoomPeerIdentityStore _peerIdentityStore;
  final LoomOfflineBundleVerifier _verifyBundle;
  final Duration maxOfflineAge;
  final Duration allowedClockSkew;

  Future<LoomResolvedUserSecurity?> loadPeer({
    required String address,
    required DateTime now,
    String displayName = '',
  }) async {
    final current = now.toUtc();
    final pin = _peerIdentityStore.pinForAddress(address);
    if (pin == null || !_isFresh(pin.lastSeenAt, current)) return null;

    final known = _securityStore.listDevices(pin.identityId);
    if (known.any(
      (item) => item.trustState == LoomDeviceTrustState.changed,
    )) {
      return null;
    }
    final active = known
        .where(
          (item) =>
              item.trustState != LoomDeviceTrustState.revoked &&
              item.trustState != LoomDeviceTrustState.changed,
        )
        .toList(growable: false);
    if (active.isEmpty ||
        active.any((item) => !_isFresh(item.lastSeenAt, current))) {
      return null;
    }

    final devices = <LoomDeviceKeyBundle>[];
    try {
      for (final item in active) {
        devices.add(
          await _verifyBundle(
            bundle: item.bundle,
            identityId: pin.identityId,
            identityPublicKey: pin.publicKey,
          ),
        );
      }
    } catch (_) {
      return null;
    }

    return LoomResolvedUserSecurity(
      address: pin.address,
      displayName: displayName.trim(),
      identityId: pin.identityId,
      identityPublicKey: pin.publicKey,
      identityFingerprint: pin.fingerprint,
      devices: List<LoomDeviceKeyBundle>.unmodifiable(devices),
    );
  }

  Future<List<LoomDeviceKeyBundle>?> loadOwn({
    required LoomIdentityPublic identity,
    required String currentDeviceId,
    required DateTime now,
  }) async {
    final current = now.toUtc();
    final known = _securityStore.listDevices(identity.identityId);
    if (known.any(
      (item) => item.trustState == LoomDeviceTrustState.changed,
    )) {
      return null;
    }
    final active = known
        .where(
          (item) =>
              item.trustState != LoomDeviceTrustState.revoked &&
              item.trustState != LoomDeviceTrustState.changed,
        )
        .toList(growable: false);
    if (active.isEmpty ||
        !active.any((item) => item.bundle.deviceId == currentDeviceId) ||
        active.any((item) => !_isFresh(item.lastSeenAt, current))) {
      return null;
    }

    final devices = <LoomDeviceKeyBundle>[];
    try {
      for (final item in active) {
        devices.add(
          await _verifyBundle(
            bundle: item.bundle,
            identityId: identity.identityId,
            identityPublicKey: identity.publicKey,
          ),
        );
      }
    } catch (_) {
      return null;
    }
    return List<LoomDeviceKeyBundle>.unmodifiable(devices);
  }

  bool _isFresh(DateTime observedAt, DateTime now) {
    final observed = observedAt.toUtc();
    if (observed.isAfter(now.add(allowedClockSkew))) return false;
    return now.difference(observed) <= maxOfflineAge;
  }
}
