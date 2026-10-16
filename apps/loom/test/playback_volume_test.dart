import 'dart:async';

import 'package:loom_next/features/media/application/playback_volume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'gain is applied to the attached player and mute restores previous gain',
    () async {
      final volume = LoomPlaybackVolume();
      addTearDown(volume.dispose);
      final first = <double>[];
      final next = <double>[];
      await volume.attach((value) async => first.add(value));
      await volume.set(36);
      await volume.toggleMute();
      expect(volume.muted, isTrue);
      await volume.toggleMute();
      expect(first, [100, 36, 0, 36]);
      volume.detach();
      await volume.attach((value) async => next.add(value));
      expect(next, [36]);
      await volume.set(200);
      expect(next.last, 100);
      expect(() => volume.set(double.nan), throwsArgumentError);
    },
  );

  test('old queued gain never targets a replaced player', () async {
    final volume = LoomPlaybackVolume();
    addTearDown(volume.dispose);
    final blocked = Completer<void>();
    final old = <double>[];
    final fresh = <double>[];
    final pending = volume.attach((value) async {
      old.add(value);
      await blocked.future;
    });
    await Future<void>.delayed(Duration.zero);
    final change = volume.set(15);
    volume.detach();
    final replacement = volume.attach((value) async => fresh.add(value));
    blocked.complete();
    await Future.wait([pending, change, replacement]);
    expect(old, [100]);
    expect(fresh, [15]);
  });

  test('native failure is surfaced and retry clears the error', () async {
    final volume = LoomPlaybackVolume();
    addTearDown(volume.dispose);
    await volume.attach((_) async => throw StateError('device unavailable'));
    expect(volume.error, isNotNull);
    await volume.attach((_) async {});
    expect(volume.error, isNull);
  });
}
