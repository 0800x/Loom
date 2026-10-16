import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'engine.dart';

final class LoomVodozemacPocFfiEngine implements LoomVodozemacPocEngine {
  LoomVodozemacPocFfiEngine._(DynamicLibrary library)
      : _call = library
            .lookupFunction<_NativeCall, _DartCall>('loom_vodozemac_poc_call'),
        _free = library
            .lookupFunction<_NativeFree, _DartFree>('loom_vodozemac_poc_free');

  static const environmentVariable = 'LOOM_VODOZEMAC_POC_LIB';
  static const _maxRequestBytes = 4 * 1024 * 1024;
  static const _maxResponseBytes = 4 * 1024 * 1024;
  final _DartCall _call;
  final _DartFree _free;

  factory LoomVodozemacPocFfiEngine.open(String libraryPath) {
    if (libraryPath.trim().isEmpty)
      throw ArgumentError.value(libraryPath, 'libraryPath');
    return LoomVodozemacPocFfiEngine._(DynamicLibrary.open(libraryPath.trim()));
  }

  factory LoomVodozemacPocFfiEngine.openFromEnvironment() {
    final path = Platform.environment[environmentVariable];
    if (path == null || path.trim().isEmpty)
      throw StateError('$environmentVariable is not configured');
    return LoomVodozemacPocFfiEngine.open(path);
  }

  @override
  Future<LoomVodozemacPocEngineVersion> version() async {
    final result = _invoke({'op': 'version'});
    return LoomVodozemacPocEngineVersion(
        abi: _requiredInt(result, 'abi'),
        engine: _requiredString(result, 'engine', maxLength: 128),
        version: _requiredString(result, 'version', maxLength: 128));
  }

  @override
  Future<LoomVodozemacPocAccount> createAccount(
      {int oneTimeKeyCount = 8}) async {
    if (oneTimeKeyCount < 1 || oneTimeKeyCount > 100)
      throw ArgumentError.value(oneTimeKeyCount, 'oneTimeKeyCount');
    final result = _invoke(
        {'op': 'create_account', 'one_time_key_count': oneTimeKeyCount});
    return LoomVodozemacPocAccount(
        accountPickle: _requiredString(result, 'account_pickle'),
        curve25519: _requiredJsonValue(result, 'curve25519'),
        ed25519: _requiredJsonValue(result, 'ed25519'),
        oneTimeKeys: _requiredList(result, 'one_time_keys'));
  }

  @override
  Future<LoomVodozemacPocPrekeyInventory> preparePrekeys(
      {required String accountPickle,
      required int targetOneTimeKeyCount,
      required bool rotateFallback}) async {
    final result = _invoke({
      'op': 'prepare_prekeys',
      'account_pickle': _boundedSecret(accountPickle, 'account_pickle'),
      'target_one_time_key_count': targetOneTimeKeyCount,
      'rotate_fallback': rotateFallback
    });
    return LoomVodozemacPocPrekeyInventory(
        accountPickle: _requiredString(result, 'account_pickle'),
        curve25519: _requiredJsonValue(result, 'curve25519'),
        ed25519: _requiredJsonValue(result, 'ed25519'),
        oneTimeKeys: _requiredList(result, 'one_time_keys'),
        fallbackKeys: _requiredList(result, 'fallback_keys'),
        storedOneTimeKeyCount:
            _requiredInt(result, 'stored_one_time_key_count'),
        maxOneTimeKeyCount: _requiredInt(result, 'max_one_time_key_count'));
  }

  @override
  Future<String> markKeysPublished(String accountPickle) async =>
      _requiredString(
          _invoke({
            'op': 'mark_keys_published',
            'account_pickle': _boundedSecret(accountPickle, 'account_pickle')
          }),
          'account_pickle');

  @override
  Future<LoomVodozemacPocFallbackCleanup> forgetPreviousFallback(
      String accountPickle) async {
    final result = _invoke({
      'op': 'forget_previous_fallback',
      'account_pickle': _boundedSecret(accountPickle, 'account_pickle')
    });
    final forgotten = result['forgotten'];
    if (forgotten is! bool)
      throw const LoomVodozemacPocEngineException('invalid_engine_response');
    return LoomVodozemacPocFallbackCleanup(
        accountPickle: _requiredString(result, 'account_pickle'),
        forgotten: forgotten);
  }

  @override
  Future<LoomVodozemacPocSession> createOutboundSession(
      {required String accountPickle,
      required Object remoteIdentityKey,
      required Object remoteOneTimeKey}) async {
    final result = _invoke({
      'op': 'create_outbound_session',
      'account_pickle': _boundedSecret(accountPickle, 'account_pickle'),
      'remote_identity_key': _boundedPublicKey(remoteIdentityKey),
      'remote_one_time_key': _boundedPublicKey(remoteOneTimeKey)
    });
    return LoomVodozemacPocSession(
        sessionId: _requiredString(result, 'session_id', maxLength: 256),
        sessionPickle: _requiredString(result, 'session_pickle'));
  }

  @override
  Future<LoomVodozemacPocInboundSession> createInboundSession(
      {required String accountPickle,
      required Object remoteIdentityKey,
      required Object message}) async {
    final result = _invoke({
      'op': 'create_inbound_session',
      'account_pickle': _boundedSecret(accountPickle, 'account_pickle'),
      'remote_identity_key': _boundedPublicKey(remoteIdentityKey),
      'message': _boundedMessage(message)
    });
    return LoomVodozemacPocInboundSession(
        accountPickle: _requiredString(result, 'account_pickle'),
        sessionId: _requiredString(result, 'session_id', maxLength: 256),
        sessionPickle: _requiredString(result, 'session_pickle'),
        plaintext: _requiredBytes(result, 'plaintext'));
  }

  @override
  Future<LoomVodozemacPocEncrypted> encrypt(
      {required String sessionPickle, required Uint8List plaintext}) async {
    if (plaintext.isEmpty || plaintext.length > 1024 * 1024)
      throw const LoomVodozemacPocEngineException('invalid_plaintext');
    final result = _invoke({
      'op': 'encrypt',
      'session_pickle': _boundedSecret(sessionPickle, 'session_pickle'),
      'plaintext': base64Encode(plaintext)
    });
    return LoomVodozemacPocEncrypted(
        sessionId: _requiredString(result, 'session_id', maxLength: 256),
        sessionPickle: _requiredString(result, 'session_pickle'),
        message: _requiredJsonValue(result, 'message'));
  }

  @override
  Future<LoomVodozemacPocDecrypted> decrypt(
      {required String sessionPickle, required Object message}) async {
    final result = _invoke({
      'op': 'decrypt',
      'session_pickle': _boundedSecret(sessionPickle, 'session_pickle'),
      'message': _boundedMessage(message)
    });
    return LoomVodozemacPocDecrypted(
        sessionId: _requiredString(result, 'session_id', maxLength: 256),
        sessionPickle: _requiredString(result, 'session_pickle'),
        plaintext: _requiredBytes(result, 'plaintext'));
  }

  Map<String, Object?> _invoke(Map<String, Object?> request) {
    final encoded = utf8.encode(jsonEncode(request));
    if (encoded.isEmpty || encoded.length > _maxRequestBytes) {
      throw const LoomVodozemacPocEngineException('request_too_large');
    }
    final input = calloc<Uint8>(encoded.length);
    try {
      input.asTypedList(encoded.length).setAll(0, encoded);
      final responsePointer = _call(input, encoded.length);
      if (responsePointer == nullptr) {
        throw const LoomVodozemacPocEngineException('engine_null_response');
      }
      try {
        final bytes = responsePointer.cast<Utf8>().toDartString().codeUnits;
        if (bytes.length > _maxResponseBytes) {
          throw const LoomVodozemacPocEngineException('response_too_large');
        }
        final decoded = jsonDecode(String.fromCharCodes(bytes));
        if (decoded is! Map<String, Object?>) {
          throw const LoomVodozemacPocEngineException(
            'invalid_engine_response',
          );
        }
        final ok = decoded['ok'];
        if (ok != true) {
          final code = decoded['error'];
          throw LoomVodozemacPocEngineException(
            code is String && code.isNotEmpty ? code : 'engine_error',
          );
        }
        return _requiredMap(decoded, 'value');
      } finally {
        _free(responsePointer);
      }
    } finally {
      input.asTypedList(encoded.length).fillRange(0, encoded.length, 0);
      calloc.free(input);
    }
  }

  static String _boundedSecret(String value, String label) {
    if (value.isEmpty || value.length > 2 * 1024 * 1024) {
      throw LoomVodozemacPocEngineException('invalid_$label');
    }
    return value;
  }

  static Object _boundedPublicKey(Object value) {
    if (jsonEncode(value).length > 512) {
      throw const LoomVodozemacPocEngineException('invalid_public_key');
    }
    return value;
  }

  static Object _boundedMessage(Object value) {
    final encoded = jsonEncode(value);
    if (encoded.length > 2 * 1024 * 1024) {
      throw const LoomVodozemacPocEngineException('invalid_message');
    }
    return value;
  }

  static String _requiredString(
    Map<String, Object?> value,
    String key, {
    int maxLength = 2 * 1024 * 1024,
  }) {
    final result = value[key];
    if (result is! String || result.isEmpty || result.length > maxLength) {
      throw const LoomVodozemacPocEngineException('invalid_engine_response');
    }
    return result;
  }

  static Uint8List _requiredBytes(Map<String, Object?> value, String key) {
    final encoded = _requiredString(value, key);
    final decoded = base64Decode(base64.normalize(encoded));
    if (decoded.isEmpty || decoded.length > 1024 * 1024) {
      throw const LoomVodozemacPocEngineException('invalid_engine_response');
    }
    return Uint8List.fromList(decoded);
  }

  static List<Object> _requiredList(Map<String, Object?> value, String key) {
    final raw = value[key];
    if (raw is! List || raw.any((item) => item == null) || raw.length > 1024) {
      throw const LoomVodozemacPocEngineException('invalid_engine_response');
    }
    return List<Object>.unmodifiable(raw.cast<Object>());
  }

  static int _requiredInt(Map<String, Object?> value, String key) {
    final result = value[key];
    if (result is! int || result < 0)
      throw const LoomVodozemacPocEngineException('invalid_engine_response');
    return result;
  }

  static Map<String, Object?> _requiredMap(
    Map<String, Object?> value,
    String key,
  ) {
    final raw = value[key];
    if (raw is! Map) {
      throw const LoomVodozemacPocEngineException('invalid_engine_response');
    }
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) {
        throw const LoomVodozemacPocEngineException('invalid_engine_response');
      }
      result[entry.key as String] = _validatedJsonValue(entry.value);
    }
    return result;
  }

  static Object? _validatedJsonValue(Object? value, [int depth = 0]) {
    if (depth > 16) {
      throw const LoomVodozemacPocEngineException('invalid_engine_response');
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is Map<String, Object?>) {
      return value.map(
          (key, item) => MapEntry(key, _validatedJsonValue(item, depth + 1)));
    }
    if (value is List) {
      if (value.length > 1024) {
        throw const LoomVodozemacPocEngineException('invalid_engine_response');
      }
      return value
          .map((item) => _validatedJsonValue(item, depth + 1))
          .toList(growable: false);
    }
    throw const LoomVodozemacPocEngineException('invalid_engine_response');
  }

  static Object _requiredJsonValue(Map<String, Object?> value, String key) {
    final result = value[key];
    if (result == null) {
      throw const LoomVodozemacPocEngineException('invalid_engine_response');
    }
    jsonEncode(result);
    return result;
  }
}

typedef _NativeCall = Pointer<Utf8> Function(Pointer<Uint8>, IntPtr);
typedef _DartCall = Pointer<Utf8> Function(Pointer<Uint8>, int);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);
