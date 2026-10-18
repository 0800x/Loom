import 'dart:async';
import 'dart:io';

import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/services.dart';

typedef LoomBleReadinessStep = Future<bool> Function();

/// Product startup policy for Android BLE.
///
/// Runtime permission approval and radio enable consent are separate Android
/// flows. Product startup is usable only after both complete, and the second
/// step is entered automatically after the first succeeds.
final class LoomAndroidBleReadinessPolicy {
  const LoomAndroidBleReadinessPolicy._();

  static Future<bool> request({
    required LoomBleReadinessStep requestPermissions,
    required LoomBleReadinessStep ensureRadioReady,
  }) async {
    if (!await requestPermissions()) return false;
    return ensureRadioReady();
  }
}

/// Real Android BLE bearer backed by LE L2CAP CoC in the native host.
///
/// The native side deliberately keeps Bluetooth MAC addresses and BluetoothDevice
/// objects out of Dart. [LoomNearbyCandidate.nativeHandle] and link handles are
/// short-lived random capabilities owned by the native adapter.
///
/// This class supplies only a raw nearby byte channel. The caller must still
/// pass each link through the Loom peer authenticator before sending DTN peer
/// frames or any other application traffic.
final class LoomAndroidBleRadioAdapter implements LoomNearbyRadioAdapter {
  LoomAndroidBleRadioAdapter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'loom/nearby_ble';
  static const int _maxFrameBytes = 320 * 1024;

  final MethodChannel _channel;

  @override
  Set<LoomNearbyBearer> get supportedBearers => const <LoomNearbyBearer>{
    LoomNearbyBearer.bluetoothLowEnergy,
  };

  Future<bool> isSupported() async {
    if (!Platform.isAndroid) return false;
    return (await _channel.invokeMethod<bool>('supported')) ?? false;
  }

  /// Requests the minimum runtime permission set and then, when Bluetooth is
  /// disabled, enters Android's system enable-consent flow. The native bridge
  /// completes [ensureReady] only after the user returns, so callers continue
  /// startup automatically without requiring a second product action.
  Future<bool> requestPermissions() async {
    _requireAndroid();
    return LoomAndroidBleReadinessPolicy.request(
      requestPermissions: () async =>
          (await _channel.invokeMethod<bool>('requestPermissions')) ?? false,
      ensureRadioReady: () async =>
          (await _channel.invokeMethod<bool>('ensureReady')) ?? false,
    );
  }

  /// Starts/stops the user-visible connected-device foreground lifetime.
  ///
  /// Product code should call [startForegroundMode] only from a foreground user
  /// action such as enabling Emergency/Nearby mode. It is intentionally not
  /// started automatically from discovery code.
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
      final map = _stringObjectMap(value);
      final nativeHandle = map['nativeHandle'];
      final rendezvousId = map['rendezvousId'];
      final expiresAtMs = map['expiresAtMs'];
      final signalStrength = map['signalStrength'];
      if (nativeHandle is! String ||
          rendezvousId is! String ||
          expiresAtMs is! num) {
        throw const FormatException('Malformed Android BLE scan result');
      }
      final advertisement = LoomNearbyAdvertisement(
        protocolVersion: 1,
        rendezvousId: rendezvousId,
        bearers: const <LoomNearbyBearer>[LoomNearbyBearer.bluetoothLowEnergy],
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          expiresAtMs.toInt(),
          isUtc: true,
        ),
      );
      yield LoomNearbyCandidate(
        advertisement: advertisement,
        bearer: LoomNearbyBearer.bluetoothLowEnergy,
        nativeHandle: nativeHandle,
        signalStrength: signalStrength is num ? signalStrength.toInt() : null,
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
        !advertisement.bearers.contains(LoomNearbyBearer.bluetoothLowEnergy)) {
      throw const FormatException('Invalid BLE nearby advertisement');
    }
    await _channel.invokeMethod<Object?>('advertise', <String, Object?>{
      'rendezvousId': advertisement.rendezvousId,
      'expiresAtMs': advertisement.expiresAt.toUtc().millisecondsSinceEpoch,
    });
    return _AndroidBleAdvertisingSession(_channel);
  }

  @override
  Future<LoomNearbyLink> connect(LoomNearbyCandidate candidate) async {
    _requireAndroid();
    if (candidate.bearer != LoomNearbyBearer.bluetoothLowEnergy ||
        candidate.nativeHandle.trim() != candidate.nativeHandle ||
        candidate.nativeHandle.length < 8 ||
        candidate.nativeHandle.length > 128 ||
        !candidate.advertisement.expiresAt.toUtc().isAfter(
          DateTime.now().toUtc(),
        )) {
      throw const FormatException('Invalid or expired BLE candidate');
    }
    final response = _stringObjectMap(
      await _channel.invokeMethod<Object?>('connect', <String, Object?>{
        'nativeHandle': candidate.nativeHandle,
      }),
    );
    final linkHandle = response['linkHandle'];
    if (linkHandle is! String ||
        linkHandle.length < 8 ||
        linkHandle.length > 128) {
      throw const FormatException('Malformed Android BLE link response');
    }
    return _AndroidBleLink(_channel, linkHandle);
  }

  void _requireAndroid() {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Android BLE transport is available only on Android',
      );
    }
  }

  static void _validateTimeout(Duration timeout) {
    if (timeout < const Duration(milliseconds: 100) ||
        timeout > const Duration(minutes: 1)) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'BLE timeout is outside bounds',
      );
    }
  }
}

final class _AndroidBleAdvertisingSession
    implements LoomNearbyAdvertisingSession {
  _AndroidBleAdvertisingSession(this._channel) {
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
        final map = _stringObjectMap(raw);
        final linkHandle = map['linkHandle'];
        if (linkHandle is! String ||
            linkHandle.length < 8 ||
            linkHandle.length > 128) {
          throw const FormatException('Malformed accepted Android BLE link');
        }
        _controller.add(_AndroidBleLink(_channel, linkHandle));
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

final class _AndroidBleLink implements LoomNearbyLink {
  _AndroidBleLink(this._channel, this._linkHandle);

  final MethodChannel _channel;
  final String _linkHandle;
  bool _closed = false;

  @override
  LoomNearbyBearer get bearer => LoomNearbyBearer.bluetoothLowEnergy;

  @override
  Future<List<int>> receive({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _ensureOpen();
    LoomAndroidBleRadioAdapter._validateTimeout(timeout);
    final raw = await _channel.invokeMethod<Object?>(
      'receive',
      <String, Object?>{
        'linkHandle': _linkHandle,
        'timeoutMs': timeout.inMilliseconds,
      },
    );
    if (raw == null) {
      throw TimeoutException('Android BLE receive timed out', timeout);
    }
    final bytes = switch (raw) {
      Uint8List value => value,
      List<Object?> value => Uint8List.fromList(value.cast<int>()),
      _ => throw const FormatException('Malformed Android BLE frame'),
    };
    if (bytes.isEmpty ||
        bytes.length > LoomAndroidBleRadioAdapter._maxFrameBytes) {
      throw const FormatException('Android BLE frame exceeds bounds');
    }
    return bytes;
  }

  @override
  Future<void> send(List<int> bytes) async {
    _ensureOpen();
    if (bytes.isEmpty ||
        bytes.length > LoomAndroidBleRadioAdapter._maxFrameBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'BLE frame exceeds bounds',
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
    if (_closed) throw StateError('Android BLE link is closed');
  }
}

Map<String, Object?> _stringObjectMap(Object? value) {
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
