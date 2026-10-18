import 'dart:async';
import 'dart:io';

import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/services.dart';

/// Android default-network events are invalidation hints, never routing truth.
final class LoomDefaultNetworkGenerationMonitor {
  LoomDefaultNetworkGenerationMonitor({EventChannel? channel})
    : _channel = channel ?? const EventChannel('loom/default_network');

  final EventChannel _channel;
  StreamSubscription<Object?>? _subscription;
  int? _lastNativeGeneration;

  void start() {
    if (!Platform.isAndroid || _subscription != null) return;
    _subscription = _channel.receiveBroadcastStream().listen(
      _onEvent,
      onError: (_) {
        // Ordinary Send remains authoritative if the native hint is absent.
      },
    );
  }

  void _onEvent(Object? event) {
    if (event is! Map<Object?, Object?>) return;
    final nativeGeneration = event['generation'];
    if (nativeGeneration is! int || nativeGeneration == _lastNativeGeneration) {
      return;
    }
    _lastNativeGeneration = nativeGeneration;
    final transport = event['transport'];
    final validated = event['validated'];
    LoomDefaultNetworkGeneration.advance(
      transportClass: transport is String ? transport : 'unknown',
      validated: validated is bool ? validated : null,
    );
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
