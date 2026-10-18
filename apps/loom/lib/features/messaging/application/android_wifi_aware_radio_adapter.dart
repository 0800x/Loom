import 'dart:async';
import 'dart:io';

import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/services.dart';

import 'android_wifi_readiness_policy.dart';

final class LoomAndroidWifiAwareRadioAdapter implements LoomNearbyRadioAdapter {
  LoomAndroidWifiAwareRadioAdapter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'loom/nearby_wifi_aware_v2';
  static const int _maxFrameBytes = 320 * 1024;

  final MethodChannel _channel;

  @override
  Set<LoomNearbyBearer> get supportedBearers => const <LoomNearbyBearer>{
    LoomNearbyBearer.wifiAware,
  };

  Future<bool> isSupported() async {
    if (!Platform.isAndroid) return false;
    return (await _channel.invokeMethod<bool>('supported')) ?? false;
  }

  Future<bool> requestPermissions() async {
    _requireAndroid();
    return LoomAndroidWifiReadinessPolicy.request(
      requestPermissions: () async =>
          (await _channel.invokeMethod<bool>('requestPermissions')) ?? false,
      ensureRadioReady: () async =>
          (await _channel.invokeMethod<bool>('ensureReady')) ?? false,
    );
  }

  Future<void> startForegroundMode() async {
    _requireAndroid();
    await _channel.invokeMethod<void>('startForegroundMode');
  }

  Future<void> stopForegroundMode() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopForegroundMode');
  }

  @override
  Stream<LoomNearbyCandidate> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    _requireAndroid();
    _validateTimeout(timeout);
    final raw = await _channel.invokeMethod<List<Object?>>(
      'scan',
      <String, Object?>{'timeoutMs': timeout.inMilliseconds},
    );
    if (raw == null) return;
    for (final value in raw) {
      final map = _awareMap(value);
      final nativeHandle = map['nativeHandle'];
      final rendezvousId = map['rendezvousId'];
      final expiresAtMs = map['expiresAtMs'];
      if (nativeHandle is! String ||
          rendezvousId is! String ||
          expiresAtMs is! num ||
          nativeHandle.length < 8 ||
          nativeHandle.length > 128 ||
          rendezvousId.length < 16 ||
          rendezvousId.length > 128) {
        throw const FormatException(
          'Malformed Android Wi-Fi Aware scan result',
        );
      }
      yield LoomNearbyCandidate(
        advertisement: LoomNearbyAdvertisement(
          protocolVersion: 1,
          rendezvousId: rendezvousId,
          bearers: const <LoomNearbyBearer>[LoomNearbyBearer.wifiAware],
          expiresAt: DateTime.fromMillisecondsSinceEpoch(
            expiresAtMs.toInt(),
            isUtc: true,
          ),
        ),
        bearer: LoomNearbyBearer.wifiAware,
        nativeHandle: nativeHandle,
      );
    }
  }

  @override
  Future<LoomNearbyAdvertisingSession> advertise(
    LoomNearbyAdvertisement advertisement,
  ) async {
    _requireAndroid();
    final now = DateTime.now().toUtc();
    if (advertisement.protocolVersion != 1 ||
        advertisement.rendezvousId.length < 16 ||
        advertisement.rendezvousId.length > 128 ||
        !advertisement.expiresAt.toUtc().isAfter(now) ||
        !advertisement.bearers.contains(LoomNearbyBearer.wifiAware)) {
      throw const FormatException('Invalid Wi-Fi Aware nearby advertisement');
    }
    await _channel.invokeMethod<Object?>('advertise', <String, Object?>{
      'rendezvousId': advertisement.rendezvousId,
      'expiresAtMs': advertisement.expiresAt.toUtc().millisecondsSinceEpoch,
    });
    return _AndroidWifiAwareAdvertisingSession(_channel);
  }

  @override
  Future<LoomNearbyLink> connect(LoomNearbyCandidate candidate) async {
    _requireAndroid();
    if (candidate.bearer != LoomNearbyBearer.wifiAware ||
        candidate.nativeHandle.trim() != candidate.nativeHandle ||
        candidate.nativeHandle.length < 8 ||
        candidate.nativeHandle.length > 128 ||
        !candidate.advertisement.expiresAt.toUtc().isAfter(
          DateTime.now().toUtc(),
        )) {
      throw const FormatException('Invalid or expired Wi-Fi Aware candidate');
    }
    final response = _awareMap(
      await _channel.invokeMethod<Object?>('connect', <String, Object?>{
        'nativeHandle': candidate.nativeHandle,
      }),
    );
    final handle = response['linkHandle'];
    if (handle is! String || handle.length < 8 || handle.length > 128) {
      throw const FormatException(
        'Malformed Android Wi-Fi Aware link response',
      );
    }
    return _AndroidWifiAwareLink(_channel, handle);
  }

  void _requireAndroid() {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Wi-Fi Aware transport is available only on Android',
      );
    }
  }

  static void _validateTimeout(Duration timeout) {
    if (timeout < const Duration(milliseconds: 100) ||
        timeout > const Duration(minutes: 1)) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Wi-Fi Aware timeout is outside bounds',
      );
    }
  }
}

final class _AndroidWifiAwareAdvertisingSession
    implements LoomNearbyAdvertisingSession {
  _AndroidWifiAwareAdvertisingSession(this._channel) {
    _pump();
  }

  final MethodChannel _channel;
  final StreamController<LoomNearbyLink> _controller =
      StreamController<LoomNearbyLink>();
  bool _closed = false;

  @override
  Stream<LoomNearbyLink> get incomingLinks => _controller.stream;

  Future<void> _pump() async {
    while (!_closed) {
      try {
        final raw = await _channel.invokeMethod<Object?>(
          'accept',
          const <String, Object?>{'timeoutMs': 1000},
        );
        if (_closed) break;
        if (raw == null) continue;
        final map = _awareMap(raw);
        final handle = map['linkHandle'];
        if (handle is! String || handle.length < 8 || handle.length > 128) {
          throw const FormatException('Malformed accepted Wi-Fi Aware link');
        }
        _controller.add(_AndroidWifiAwareLink(_channel, handle));
      } on PlatformException catch (error, stackTrace) {
        if (_closed) break;
        _controller.addError(error, stackTrace);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } catch (error, stackTrace) {
        if (_closed) break;
        _controller.addError(error, stackTrace);
        break;
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.invokeMethod<void>('stopAdvertising');
    } finally {
      await _controller.close();
    }
  }
}

final class _AndroidWifiAwareLink implements LoomNearbyLink {
  _AndroidWifiAwareLink(this._channel, this._linkHandle);

  final MethodChannel _channel;
  final String _linkHandle;
  bool _closed = false;

  @override
  LoomNearbyBearer get bearer => LoomNearbyBearer.wifiAware;

  @override
  Future<List<int>> receive({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _ensureOpen();
    LoomAndroidWifiAwareRadioAdapter._validateTimeout(timeout);
    final raw = await _channel.invokeMethod<Object?>(
      'receive',
      <String, Object?>{
        'linkHandle': _linkHandle,
        'timeoutMs': timeout.inMilliseconds,
      },
    );
    if (raw == null) {
      throw TimeoutException('Android Wi-Fi Aware receive timed out', timeout);
    }
    final bytes = switch (raw) {
      Uint8List value => value,
      List<Object?> value => Uint8List.fromList(value.cast<int>()),
      _ => throw const FormatException('Malformed Android Wi-Fi Aware frame'),
    };
    if (bytes.isEmpty ||
        bytes.length > LoomAndroidWifiAwareRadioAdapter._maxFrameBytes) {
      throw const FormatException('Android Wi-Fi Aware frame exceeds bounds');
    }
    return bytes;
  }

  @override
  Future<void> send(List<int> bytes) async {
    _ensureOpen();
    if (bytes.isEmpty ||
        bytes.length > LoomAndroidWifiAwareRadioAdapter._maxFrameBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'Wi-Fi Aware frame exceeds bounds',
      );
    }
    await _channel.invokeMethod<void>('send', <String, Object?>{
      'linkHandle': _linkHandle,
      'bytes': Uint8List.fromList(bytes),
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.invokeMethod<void>('close', <String, Object?>{
      'linkHandle': _linkHandle,
    });
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Android Wi-Fi Aware link is closed');
  }
}

Map<String, Object?> _awareMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected platform map');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const FormatException('Platform map key is not a string');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}
