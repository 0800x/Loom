import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  LoomRelayBundle bundle(DateTime now) => LoomRelayBundle(
        bundleId: 'b-1',
        recipientTag: 'recipient-tag-1234567890',
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 6)),
        hopCount: 0,
        maxHops: 3,
        sealedPayload: const LoomRelaySealedPayload(
          version: 1,
          ephemeralPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          nonce: 'AAAAAAAAAAAAAAAA',
          ciphertext: 'AQ==',
          mac: 'AAAAAAAAAAAAAAAAAAAAAA==',
        ),
      );

  test('relay policy is opt-in and bounded', () {
    final now = DateTime.utc(2026, 9, 1, 12);
    expect(
      const LoomRelayPolicy().allows(
        bundle: bundle(now),
        currentlyStoredBytes: 0,
        peerIsContact: true,
        peerIsTrustedDevice: true,
      ),
      isFalse,
    );
    expect(
      const LoomRelayPolicy(consent: LoomRelayConsent.contactsOnly).allows(
        bundle: bundle(now),
        currentlyStoredBytes: 0,
        peerIsContact: true,
        peerIsTrustedDevice: false,
      ),
      isTrue,
    );
  });

  test('spool deduplicates a carried bundle', () {
    final now = DateTime.utc(2026, 9, 1, 12);
    final store = LoomRelayStore.openInMemory();
    addTearDown(store.close);
    final service = LoomStoreCarryForwardService(
      store: store,
      policy: const LoomRelayPolicy(consent: LoomRelayConsent.enabled),
    );
    expect(
      service.acceptForRelay(
        bundle: bundle(now),
        now: now,
        peerIsContact: false,
        peerIsTrustedDevice: false,
      ),
      isTrue,
    );
    expect(
      service.acceptForRelay(
        bundle: bundle(now),
        now: now,
        peerIsContact: false,
        peerIsTrustedDevice: false,
      ),
      isFalse,
    );
  });
}
