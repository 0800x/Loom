import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:loom_next/features/media/application/music_queue.dart';

void main() {
  test(
    'end of queue stops unless repeat is enabled; explicit skip can wrap',
    () {
      final queue = LoomMusicQueue()..replace(['a', 'b'], start: 'a');
      expect(queue.next(completed: true), 'b');
      expect(queue.next(completed: true), isNull);
      queue.repeat = 1;
      expect(queue.next(completed: true), 'a');
      queue.repeat = 2;
      expect(queue.next(completed: true), 'a');
      expect(queue.next(), 'b');
    },
  );
  test('shuffle visits every track once and previous retraces playback', () {
    final queue = LoomMusicQueue(random: Random(4))
      ..replace(['a', 'b', 'c', 'd'], start: 'a')
      ..shuffle = true;
    final played = ['a'];
    for (var i = 0; i < 3; i++) {
      played.add(queue.next(completed: true)!);
    }
    expect(played.toSet(), {'a', 'b', 'c', 'd'});
    expect(queue.next(completed: true), isNull);
    expect(queue.previous(), played[2]);
    expect(queue.previous(), played[1]);
  });
  test('reordering and deleting the active item leaves a playable queue', () {
    final queue = LoomMusicQueue()..replace(['a', 'b', 'c'], start: 'a');
    queue.reorder(2, 1);
    expect(queue.next(), 'c');
    queue.remove('c');
    expect(queue.next(), 'a');
    queue.replace([]);
    expect(queue.next(), isNull);
    expect(queue.previous(), isNull);
  });
}
