import 'dart:io';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';

/// Native call routing and media focus are separate from per-player gain.
class LoomMediaAudioRoute {
  static const _channel = MethodChannel('loom/calls');
  static Future<void> prepare() async {
    if (Platform.isAndroid) {
      // WebRTC can leave MODE_IN_COMMUNICATION selected after a failed call.
      // Native refuses to reset a live call's audio route.
      await _channel.invokeMethod<void>('prepareMediaPlayback');
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      if (!await session.setActive(true)) {
        throw StateError('Media audio focus unavailable');
      }
    }
  }
}
