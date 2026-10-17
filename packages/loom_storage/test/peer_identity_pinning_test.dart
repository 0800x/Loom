import 'dart:io';

import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'first contact persists and changed identity never replaces known binding',
    () async {
      final dir = await Directory.systemTemp.createTemp('loom-tofu-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/pins.sqlite';
      var store = LoomPeerIdentityStore.openFile(path);
      LoomPeerIdentityObservation observe(String identity) => store.observe(
        address: '@Alice:example.org',
        identityId: identity,
        publicKey: 'key-$identity',
        fingerprint: 'fingerprint-$identity',
        observedAt: DateTime.utc(2026),
      );
      expect(observe('original'), LoomPeerIdentityObservation.firstSeen);
      store.close();
      store = LoomPeerIdentityStore.openFile(path);
      addTearDown(store.close);
      expect(observe('original'), LoomPeerIdentityObservation.unchanged);
      expect(observe('substituted'), LoomPeerIdentityObservation.changed);
      expect(store.pinForAddress('@alice:example.org')!.identityId, 'original');
    },
  );
}
