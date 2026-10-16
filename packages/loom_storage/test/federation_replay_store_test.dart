import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'federation replay store atomically rejects duplicate event ids',
    () async {
      final store = LoomSqliteFederationReplayStore.openInMemory();
      addTearDown(store.close);
      final expiry = DateTime.now().toUtc().add(const Duration(hours: 1));
      expect(await store.remember('evt_1', expiry), isTrue);
      expect(await store.remember('evt_1', expiry), isFalse);
    },
  );
}
