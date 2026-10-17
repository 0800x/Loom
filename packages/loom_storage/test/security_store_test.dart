import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  LoomDeviceKeyBundle bundle(
    String fingerprint, {
    String deviceId = 'device-1',
  }) => LoomDeviceKeyBundle(
    bundleVersion: 1,
    identityId: 'chn:identity',
    deviceId: deviceId,
    deviceName: 'Laptop',
    signingPublicKey: 'signing',
    agreementPublicKey: 'agreement',
    createdAt: DateTime.utc(2026, 9, 1),
    capabilities: const <String>['signing-ed25519'],
    fingerprint: fingerprint,
    deviceSignature: 'device-signature',
    identitySignature: 'identity-signature',
  );

  test('observing a changed fingerprint invalidates prior verification', () {
    final store = LoomSecurityStore.openInMemory();
    addTearDown(store.close);
    expect(
      store.observeDevice(bundle('AAAA'), observedAt: DateTime.utc(2026, 9, 1)),
      LoomDeviceTrustState.unknown,
    );
    store.markVerified(
      identityId: 'chn:identity',
      deviceId: 'device-1',
      expectedFingerprint: 'AAAA',
      verifiedAt: DateTime.utc(2026, 9, 1, 1),
    );
    expect(
      store.listDevices('chn:identity').single.trustState,
      LoomDeviceTrustState.verified,
    );
    expect(
      store.observeDevice(bundle('BBBB'), observedAt: DateTime.utc(2026, 9, 2)),
      LoomDeviceTrustState.changed,
    );
    final changed = store.listDevices('chn:identity').single;
    expect(changed.trustState, LoomDeviceTrustState.changed);
    expect(changed.verifiedAt, isNull);
  });

  test('removed device remains revoked if an old signed bundle reappears', () {
    final store = LoomSecurityStore.openInMemory();
    addTearDown(store.close);
    final first = bundle('AAAA');
    final second = bundle('BBBB', deviceId: 'device-2');
    store.observeDevice(first, observedAt: DateTime.utc(2026, 9, 1));
    store.observeDevice(second, observedAt: DateTime.utc(2026, 9, 1));

    final revoked = store.reconcileActiveDeviceSet(
      identityId: 'chn:identity',
      activeDeviceIds: const <String>{'device-2'},
      observedAt: DateTime.utc(2026, 9, 2),
    );
    expect(revoked, <String>['device-1']);
    expect(
      store
          .listDevices('chn:identity')
          .firstWhere((item) => item.bundle.deviceId == 'device-1')
          .trustState,
      LoomDeviceTrustState.revoked,
    );

    expect(
      store.observeDevice(first, observedAt: DateTime.utc(2026, 9, 3)),
      LoomDeviceTrustState.revoked,
    );
    expect(
      () => store.markVerified(
        identityId: 'chn:identity',
        deviceId: 'device-1',
        expectedFingerprint: 'AAAA',
        verifiedAt: DateTime.utc(2026, 9, 3),
      ),
      throwsStateError,
    );
    expect(
      store.listEvents().where(
        (event) =>
            event.kind == LoomSecurityEventKind.deviceRevoked &&
            event.deviceId == 'device-1',
      ),
      hasLength(1),
    );
  });

  test('security events are idempotent by event id', () {
    final store = LoomSecurityStore.openInMemory();
    addTearDown(store.close);
    final event = LoomSecurityEvent(
      eventId: 'event-1',
      kind: LoomSecurityEventKind.deviceAdded,
      identityId: 'chn:identity',
      deviceId: 'device-1',
      createdAt: DateTime.utc(2026, 9, 1),
      summary: 'Added',
    );
    store.addEvent(event);
    store.addEvent(event);
    expect(store.listEvents(), hasLength(1));
  });
}
