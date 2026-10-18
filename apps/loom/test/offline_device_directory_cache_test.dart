import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_next/features/messaging/application/offline_device_directory_cache.dart';

Future<LoomDeviceKeyBundle> _acceptBundle({
  required LoomDeviceKeyBundle bundle,
  required String identityId,
  required String identityPublicKey,
}) async => bundle;

LoomDeviceKeyBundle _bundle({
  required String identityId,
  required String deviceId,
  required DateTime observedAt,
  String fingerprint = 'FP-1',
}) => LoomDeviceKeyBundle(
  bundleVersion: 1,
  identityId: identityId,
  deviceId: deviceId,
  deviceName: 'Test device',
  signingPublicKey: 'signing-public-key',
  agreementPublicKey: 'agreement-public-key',
  createdAt: observedAt.toUtc(),
  capabilities: const ['signing-ed25519', 'agreement-x25519'],
  fingerprint: fingerprint,
  deviceSignature: 'device-signature',
  identitySignature: 'identity-signature',
);

void main() {
  test(
    'peer directory survives restart and enforces freshness and revocation',
    () async {
      final now = DateTime.utc(2026, 9, 10, 8);
      final directory = await Directory.systemTemp.createTemp(
        'loom-offline-dir-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/security.sqlite3';

      final seedSecurity = LoomSecurityStore.openFile(path);
      seedSecurity.observeDevice(
        _bundle(
          identityId: 'chn:peer-identity',
          deviceId: 'peer-device-1',
          observedAt: now,
        ),
        observedAt: now,
      );
      seedSecurity.close();

      final seedPins = LoomPeerIdentityStore.openFile(path);
      seedPins.observe(
        address: '@sara:helsinki.example',
        identityId: 'chn:peer-identity',
        publicKey: 'peer-identity-public-key',
        fingerprint: 'PEER-ID-FP',
        observedAt: now,
      );
      seedPins.close();

      final security = LoomSecurityStore.openFile(path);
      final pins = LoomPeerIdentityStore.openFile(path);
      addTearDown(security.close);
      addTearDown(pins.close);
      final cache = LoomOfflineDeviceDirectoryCache(
        securityStore: security,
        peerIdentityStore: pins,
        bundleVerifier: _acceptBundle,
      );

      final restored = await cache.loadPeer(
        address: '@sara:helsinki.example',
        now: now.add(const Duration(hours: 1)),
        displayName: 'Sara',
      );
      expect(restored, isNotNull);
      expect(restored!.displayName, 'Sara');
      expect(restored.devices.map((item) => item.deviceId), ['peer-device-1']);

      final stale = await cache.loadPeer(
        address: '@sara:helsinki.example',
        now: now.add(const Duration(days: 8)),
      );
      expect(stale, isNull);

      security.markRevoked(
        identityId: 'chn:peer-identity',
        deviceId: 'peer-device-1',
      );
      final revoked = await cache.loadPeer(
        address: '@sara:helsinki.example',
        now: now.add(const Duration(hours: 1)),
      );
      expect(revoked, isNull);
    },
  );

  test('own directory requires the current non-revoked device', () async {
    final now = DateTime.utc(2026, 9, 10, 8);
    final security = LoomSecurityStore.openInMemory();
    final pins = LoomPeerIdentityStore.openInMemory();
    addTearDown(security.close);
    addTearDown(pins.close);

    security.observeDevice(
      _bundle(
        identityId: 'chn:own-identity',
        deviceId: 'own-device-1',
        observedAt: now,
      ),
      observedAt: now,
    );
    final cache = LoomOfflineDeviceDirectoryCache(
      securityStore: security,
      peerIdentityStore: pins,
      bundleVerifier: _acceptBundle,
    );
    final identity = LoomIdentityPublic(
      identityId: 'chn:own-identity',
      publicKey: 'own-identity-public-key',
      fingerprint: 'OWN-ID-FP',
      createdAt: now.subtract(const Duration(days: 30)),
    );

    final restored = await cache.loadOwn(
      identity: identity,
      currentDeviceId: 'own-device-1',
      now: now.add(const Duration(hours: 1)),
    );
    expect(restored, isNotNull);
    expect(restored!.single.deviceId, 'own-device-1');

    expect(
      await cache.loadOwn(
        identity: identity,
        currentDeviceId: 'missing-device',
        now: now.add(const Duration(hours: 1)),
      ),
      isNull,
    );

    security.markRevoked(
      identityId: 'chn:own-identity',
      deviceId: 'own-device-1',
    );
    expect(
      await cache.loadOwn(
        identity: identity,
        currentDeviceId: 'own-device-1',
        now: now.add(const Duration(hours: 1)),
      ),
      isNull,
    );
  });
}
