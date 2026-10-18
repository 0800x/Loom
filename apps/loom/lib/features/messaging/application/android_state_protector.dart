import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:flutter/services.dart';

/// Android Keystore implementation of the Architecture-v2 provider-state
/// protection boundary.
///
/// The native wrapping key never crosses the platform channel. Only plaintext
/// provider state during an explicit wrap/unwrap operation and the resulting
/// AES-GCM envelope cross this process-local boundary.
final class LoomAndroidKeystoreStateProtector
    implements LoomSessionStateProtector {
  LoomAndroidKeystoreStateProtector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'loom/state_wrapping';
  static const String _scheme = 'android-keystore-aes256-gcm-v1';
  static const int _maxStateBytes = 1024 * 1024;
  final MethodChannel _channel;

  @override
  String get protectionScheme => _scheme;

  Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    final raw = await _channel.invokeMethod<Object?>('status');
    if (raw is! Map) return false;
    return raw['available'] == true && raw['scheme'] == _scheme;
  }

  @override
  Future<Uint8List> protect({
    required String contextId,
    required int revision,
    required Uint8List plaintext,
  }) async {
    _requireAndroid();
    _validateInput(contextId, revision, plaintext);
    final result = await _channel
        .invokeMethod<Object?>('wrap', <String, Object?>{
          'plaintext': Uint8List.fromList(plaintext),
          'associatedData': _associatedData(contextId, revision),
        });
    final protectedState = _bytes(result, 'wrapped state');
    if (protectedState.isEmpty || protectedState.length > _maxStateBytes + 64) {
      throw const FormatException('Android protected state exceeds bounds');
    }
    return protectedState;
  }

  @override
  Future<Uint8List> unprotect({
    required String contextId,
    required int revision,
    required Uint8List protectedState,
  }) async {
    _requireAndroid();
    validateLoomStateProtectionContext(
      contextId: contextId,
      revision: revision,
    );
    if (protectedState.isEmpty || protectedState.length > _maxStateBytes + 64) {
      throw const FormatException('Android protected state exceeds bounds');
    }
    final result = await _channel
        .invokeMethod<Object?>('unwrap', <String, Object?>{
          'protectedState': Uint8List.fromList(protectedState),
          'associatedData': _associatedData(contextId, revision),
        });
    final plaintext = _bytes(result, 'unwrapped state');
    if (plaintext.isEmpty || plaintext.length > _maxStateBytes) {
      throw const FormatException('Android unwrapped state exceeds bounds');
    }
    return plaintext;
  }

  static Uint8List _associatedData(String contextId, int revision) {
    validateLoomStateProtectionContext(
      contextId: contextId,
      revision: revision,
    );
    final context = utf8.encode(contextId);
    final header = ByteData(12)
      ..setUint32(0, context.length, Endian.big)
      ..setUint64(4, revision, Endian.big);
    return Uint8List.fromList(<int>[
      ...utf8.encode('Loom-Provider-State-v1'),
      ...header.buffer.asUint8List(),
      ...context,
    ]);
  }

  static void _validateInput(
    String contextId,
    int revision,
    Uint8List plaintext,
  ) {
    validateLoomStateProtectionContext(
      contextId: contextId,
      revision: revision,
    );
    if (plaintext.isEmpty || plaintext.length > _maxStateBytes) {
      throw const FormatException('Provider state exceeds protection bounds');
    }
  }

  static Uint8List _bytes(Object? value, String label) => switch (value) {
    Uint8List bytes => Uint8List.fromList(bytes),
    List<Object?> values => Uint8List.fromList(values.cast<int>()),
    _ => throw FormatException('Malformed Android $label'),
  };

  static void _requireAndroid() {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Android Keystore state protection is available only on Android',
      );
    }
  }
}
