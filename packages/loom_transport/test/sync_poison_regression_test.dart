import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

class _Api implements LoomMessagingApi {
  _Api(this.page);
  final LoomSyncPage page;
  @override
  Future<LoomSyncPage> sync({String? cursor, int limit = 200}) async => page;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> conversation(String id, String kind) => {
      'id': id,
      'kind': kind,
      'updatedOrder': 1,
      'unreadCount': 0,
    };
LoomSyncEvent event(String id, String kind, Map<String, Object?> payload) =>
    LoomSyncEvent(eventId: id, kind: kind, order: 1, payload: payload);
void main() {
  test(
    'unknown event, message and conversation types do not poison later sync',
    () async {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      final page = LoomSyncPage(
        events: [
          event('unknown-event', 'future.event', {}),
          event(
            'unknown-conversation',
            'conversation.upsert',
            conversation('future', 'future-kind'),
          ),
          event('unknown-message', 'message.created', {'type': 'future-type'}),
          event(
            'valid',
            'conversation.upsert',
            conversation('valid', 'direct'),
          ),
        ],
        nextCursor: 'cursor-4',
        hasMore: false,
      );
      final engine = LoomMessagingEngine(
        store: store,
        client: _Api(page),
        senderAddress: '@me:example.org',
      );
      expect(await engine.synchronize(), 4);
      expect(store.conversationById('valid'), isNotNull);
      expect(store.conversationById('future'), isNull);
      expect(store.readCursor('account'), 'cursor-4');
      expect(await engine.synchronize(), 0);
    },
  );
  test(
    'malformed known event rolls back complete batch and durable cursor',
    () async {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      store.writeCursor('account', 'before');
      final page = LoomSyncPage(
        events: [
          event(
            'valid',
            'conversation.upsert',
            conversation('valid', 'direct'),
          ),
          event('bad', 'message.created', {'type': 'text'}),
        ],
        nextCursor: 'after',
        hasMore: false,
      );
      final engine = LoomMessagingEngine(
        store: store,
        client: _Api(page),
        senderAddress: '@me:example.org',
      );
      await expectLater(engine.synchronize(), throwsFormatException);
      expect(store.conversationById('valid'), isNull);
      expect(store.readCursor('account'), 'before');
    },
  );
}
