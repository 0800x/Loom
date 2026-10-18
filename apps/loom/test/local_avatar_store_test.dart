import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:loom_next/features/profile/application/local_avatar_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'legacy local avatar becomes a durable upload and a late fetch cannot erase an edit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'loom-profile-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
      final file = File(
        '${directory.path}/profile-avatars/${base64Url.encode(utf8.encode('account'))}.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'version': 1, 'png': png, 'color': 2}),
      );
      final store = LoomLocalAvatarStore(
        'account',
        directory: () async => directory,
      );
      addTearDown(store.dispose);
      await store.load();
      expect(store.pendingUpload, isTrue);
      await store.synchronize(
        fetch: () async =>
            throw StateError('legacy photo must not be overwritten'),
        upload: (body) async {
          expect((body['avatar'] as Map)['png'], png);
          return {...body, 'revision': 'r1'};
        },
        fallbackName: 'Alice',
        force: true,
      );
      expect(store.pendingUpload, isFalse);
      expect(store.revision, 'r1');
      final started = Completer<void>();
      final response = Completer<Map<String, Object?>>();
      final fetching = store.synchronize(
        fetch: () {
          started.complete();
          return response.future;
        },
        upload: (_) async => throw StateError('clean profile must fetch'),
        fallbackName: 'Alice',
        force: true,
      );
      await started.future;
      await store.setColor(5);
      response.complete({
        'displayName': 'Old name',
        'avatar': {'png': null, 'color': 0},
        'revision': 'old',
      });
      await fetching;
      expect(store.colorIndex, 5);
      expect(store.photo, base64Decode(png));
      expect(store.pendingUpload, isTrue);
      final restored = LoomLocalAvatarStore(
        'account',
        directory: () async => directory,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.pendingUpload, isTrue);
      expect(restored.colorIndex, 5);
    },
  );

  test(
    'photo and color survive reload, remain account scoped, and remove durably',
    () async {
      final directory = await Directory.systemTemp.createTemp('loom-avatar-');
      addTearDown(() => directory.delete(recursive: true));
      final first = LoomLocalAvatarStore(
        'first-account',
        directory: () async => directory,
      );
      final other = LoomLocalAvatarStore(
        'other-account',
        directory: () async => directory,
      );
      addTearDown(first.dispose);
      addTearDown(other.dispose);
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLXkAAAAASUVORK5CYII=',
      );
      await Future.wait([first.setPhoto(png), first.setColor(3)]);
      final restored = LoomLocalAvatarStore(
        'first-account',
        directory: () async => directory,
      );
      addTearDown(restored.dispose);
      await restored.load();
      await other.load();
      expect(restored.photo, png);
      expect(restored.colorIndex, 3);
      expect(other.photo, isNull);
      expect(other.colorIndex, 0);
      await restored.removePhoto();
      final cleared = LoomLocalAvatarStore(
        'first-account',
        directory: () async => directory,
      );
      addTearDown(cleared.dispose);
      await cleared.load();
      expect(cleared.photo, isNull);
      expect(cleared.colorIndex, 3);
    },
  );

  test('one failed write does not poison later saves', () async {
    final directory = await Directory.systemTemp.createTemp(
      'loom-avatar-retry-',
    );
    addTearDown(() => directory.delete(recursive: true));
    // A file in place of the directory makes the first write fail predictably.
    final blocker = File('${directory.path}/profile-avatars');
    await blocker.writeAsString('blocked');
    final store = LoomLocalAvatarStore(
      'account',
      directory: () async => directory,
    );
    addTearDown(store.dispose);
    await expectLater(store.setColor(2), throwsA(isA<FileSystemException>()));
    expect(store.colorIndex, 0);
    await blocker.delete();
    await store.setColor(4);
    expect(store.colorIndex, 4);
  });
}
