import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'handle_engine.dart';

final class _NativeOwnedBuffer extends Struct {
  external Pointer<Uint8> ptr;

  @IntPtr()
  external int len;

  @IntPtr()
  external int capacity;

  @Int32()
  external int status;
}

final class _NativeHandleResult extends Struct {
  @Uint64()
  external int handle;

  @Int32()
  external int status;
}

final class _NativeBoolResult extends Struct {
  @Uint8()
  external int value;

  @Int32()
  external int status;
}

final class _NativeInboundResult extends Struct {
  @Uint64()
  external int sessionHandle;

  external _NativeOwnedBuffer plaintext;

  @Int32()
  external int status;
}

typedef _AbiVersionNative = Uint32 Function();
typedef _AbiVersionDart = int Function();
typedef _BufferFreeNative = Void Function(_NativeOwnedBuffer);
typedef _BufferFreeDart = void Function(_NativeOwnedBuffer);
typedef _HandleCloseNative = Int32 Function(Uint64);
typedef _HandleCloseDart = int Function(int);
typedef _AccountNewNative = _NativeHandleResult Function(IntPtr);
typedef _AccountNewDart = _NativeHandleResult Function(int);
typedef _ImportNative = _NativeHandleResult Function(Pointer<Uint8>, IntPtr);
typedef _ImportDart = _NativeHandleResult Function(Pointer<Uint8>, int);
typedef _ExportNative = _NativeOwnedBuffer Function(Uint64);
typedef _ExportDart = _NativeOwnedBuffer Function(int);
typedef _PrepareNative = _NativeOwnedBuffer Function(Uint64, IntPtr, Uint8);
typedef _PrepareDart = _NativeOwnedBuffer Function(int, int, int);
typedef _MarkPublishedNative = Int32 Function(Uint64);
typedef _MarkPublishedDart = int Function(int);
typedef _ForgetFallbackNative = _NativeBoolResult Function(Uint64);
typedef _ForgetFallbackDart = _NativeBoolResult Function(int);
typedef _OutboundNative = _NativeHandleResult Function(
  Uint64,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
);
typedef _OutboundDart = _NativeHandleResult Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);
typedef _InboundNative = _NativeInboundResult Function(
  Uint64,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint8>,
  IntPtr,
);
typedef _InboundDart = _NativeInboundResult Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);
typedef _CryptNative = _NativeOwnedBuffer Function(
  Uint64,
  Pointer<Uint8>,
  IntPtr,
);
typedef _CryptDart = _NativeOwnedBuffer Function(int, Pointer<Uint8>, int);

/// Dart binding for the Architecture-v2 opaque-handle candidate ABI.
///
/// Account and Session objects live in Rust while active. Secret serialized
/// state crosses FFI only as bounded byte buffers for immediate protect/import
/// operations; it is never converted to Dart String/JSON by this binding.
final class LoomVodozemacHandleFfiEngine implements LoomVodozemacHandleEngine {
  LoomVodozemacHandleFfiEngine._(DynamicLibrary library)
    : _abi = library.lookupFunction<_AbiVersionNative, _AbiVersionDart>(
        'loom_vodozemac_v2_abi_version',
      ),
      _bufferFree = library.lookupFunction<_BufferFreeNative, _BufferFreeDart>(
        'loom_vodozemac_v2_buffer_free',
      ),
      _handleClose = library
          .lookupFunction<_HandleCloseNative, _HandleCloseDart>(
            'loom_vodozemac_v2_handle_close',
          ),
      _accountNew = library.lookupFunction<_AccountNewNative, _AccountNewDart>(
        'loom_vodozemac_v2_account_new',
      ),
      _accountImport = library.lookupFunction<_ImportNative, _ImportDart>(
        'loom_vodozemac_v2_account_import',
      ),
      _accountExport = library.lookupFunction<_ExportNative, _ExportDart>(
        'loom_vodozemac_v2_account_export',
      ),
      _accountInventory = library.lookupFunction<_ExportNative, _ExportDart>(
        'loom_vodozemac_v2_account_public_inventory',
      ),
      _preparePrekeys = library.lookupFunction<_PrepareNative, _PrepareDart>(
        'loom_vodozemac_v2_account_prepare_prekeys',
      ),
      _markPublished = library
          .lookupFunction<_MarkPublishedNative, _MarkPublishedDart>(
            'loom_vodozemac_v2_account_mark_keys_published',
          ),
      _forgetFallback = library
          .lookupFunction<_ForgetFallbackNative, _ForgetFallbackDart>(
            'loom_vodozemac_v2_account_forget_previous_fallback',
          ),
      _sessionImport = library.lookupFunction<_ImportNative, _ImportDart>(
        'loom_vodozemac_v2_session_import',
      ),
      _sessionExport = library.lookupFunction<_ExportNative, _ExportDart>(
        'loom_vodozemac_v2_session_export',
      ),
      _sessionId = library.lookupFunction<_ExportNative, _ExportDart>(
        'loom_vodozemac_v2_session_id',
      ),
      _outbound = library.lookupFunction<_OutboundNative, _OutboundDart>(
        'loom_vodozemac_v2_create_outbound_session',
      ),
      _inbound = library.lookupFunction<_InboundNative, _InboundDart>(
        'loom_vodozemac_v2_create_inbound_session',
      ),
      _encrypt = library.lookupFunction<_CryptNative, _CryptDart>(
        'loom_vodozemac_v2_encrypt',
      ),
      _decrypt = library.lookupFunction<_CryptNative, _CryptDart>(
        'loom_vodozemac_v2_decrypt',
      ) {
    if (_abi() != 2) {
      throw const LoomVodozemacHandleEngineException('unsupported_abi');
    }
  }

  final _AbiVersionDart _abi;
  final _BufferFreeDart _bufferFree;
  final _HandleCloseDart _handleClose;
  final _AccountNewDart _accountNew;
  final _ImportDart _accountImport;
  final _ExportDart _accountExport;
  final _ExportDart _accountInventory;
  final _PrepareDart _preparePrekeys;
  final _MarkPublishedDart _markPublished;
  final _ForgetFallbackDart _forgetFallback;
  final _ImportDart _sessionImport;
  final _ExportDart _sessionExport;
  final _ExportDart _sessionId;
  final _OutboundDart _outbound;
  final _InboundDart _inbound;
  final _CryptDart _encrypt;
  final _CryptDart _decrypt;

  static const int _maxStateBytes = 4 * 1024 * 1024;
  static const int _maxMessageBytes = 1024 * 1024 + 64 * 1024;

  factory LoomVodozemacHandleFfiEngine.open(String libraryPath) {
    if (libraryPath.trim() != libraryPath || libraryPath.isEmpty) {
      throw ArgumentError.value(libraryPath, 'libraryPath');
    }
    return LoomVodozemacHandleFfiEngine._(DynamicLibrary.open(libraryPath));
  }

  @override
  int get abiVersion => _abi();

  @override
  LoomVodozemacNativeHandle createAccount({int oneTimeKeyCount = 8}) {
    if (oneTimeKeyCount < 1 || oneTimeKeyCount > 100) {
      throw ArgumentError.value(oneTimeKeyCount, 'oneTimeKeyCount');
    }
    return _handleFrom(_accountNew(oneTimeKeyCount));
  }

  @override
  LoomVodozemacNativeHandle importAccount(Uint8List stateBytes) => _withInput(
    stateBytes,
    maxBytes: _maxStateBytes,
    invoke: (pointer, length) => _handleFrom(_accountImport(pointer, length)),
  );

  @override
  Uint8List exportAccount(LoomVodozemacNativeHandle account) =>
      _takeBuffer(_accountExport(_value(account)), maxBytes: _maxStateBytes);

  @override
  LoomVodozemacPublicInventory accountInventory(
    LoomVodozemacNativeHandle account,
  ) => _decodeInventory(
    _takeBuffer(_accountInventory(_value(account)), maxBytes: 256 * 1024),
  );

  @override
  LoomVodozemacPublicInventory preparePrekeys({
    required LoomVodozemacNativeHandle account,
    required int targetOneTimeKeyCount,
    required bool rotateFallback,
  }) {
    if (targetOneTimeKeyCount < 1 || targetOneTimeKeyCount > 100) {
      throw ArgumentError.value(targetOneTimeKeyCount, 'targetOneTimeKeyCount');
    }
    return _decodeInventory(
      _takeBuffer(
        _preparePrekeys(
          _value(account),
          targetOneTimeKeyCount,
          rotateFallback ? 1 : 0,
        ),
        maxBytes: 256 * 1024,
      ),
    );
  }

  @override
  void markKeysPublished(LoomVodozemacNativeHandle account) =>
      _checkStatus(_markPublished(_value(account)));

  @override
  bool forgetPreviousFallback(LoomVodozemacNativeHandle account) {
    final result = _forgetFallback(_value(account));
    _checkStatus(result.status);
    if (result.value != 0 && result.value != 1) {
      throw const LoomVodozemacHandleEngineException('invalid_native_bool');
    }
    return result.value == 1;
  }

  @override
  LoomVodozemacNativeHandle importSession(Uint8List stateBytes) => _withInput(
    stateBytes,
    maxBytes: _maxStateBytes,
    invoke: (pointer, length) => _handleFrom(_sessionImport(pointer, length)),
  );

  @override
  Uint8List exportSession(LoomVodozemacNativeHandle session) =>
      _takeBuffer(_sessionExport(_value(session)), maxBytes: _maxStateBytes);

  @override
  String sessionId(LoomVodozemacNativeHandle session) {
    final bytes = _takeBuffer(_sessionId(_value(session)), maxBytes: 256);
    try {
      final id = utf8.decode(bytes);
      if (id.trim() != id || id.isEmpty || id.length > 256) {
        throw const LoomVodozemacHandleEngineException('invalid_session_id');
      }
      return id;
    } on FormatException {
      throw const LoomVodozemacHandleEngineException('invalid_session_id');
    } finally {
      loomZeroBytes(bytes);
    }
  }

  @override
  LoomVodozemacNativeHandle createOutboundSession({
    required LoomVodozemacNativeHandle account,
    required Object remoteIdentityKey,
    required Object remoteOneTimeKey,
  }) {
    final identity = Uint8List.fromList(
      utf8.encode(jsonEncode(remoteIdentityKey)),
    );
    final oneTime = Uint8List.fromList(
      utf8.encode(jsonEncode(remoteOneTimeKey)),
    );
    try {
      return _withTwoInputs(
        identity,
        oneTime,
        maxFirst: 4096,
        maxSecond: 4096,
        invoke: (first, firstLength, second, secondLength) => _handleFrom(
          _outbound(_value(account), first, firstLength, second, secondLength),
        ),
      );
    } finally {
      loomZeroBytes(identity);
      loomZeroBytes(oneTime);
    }
  }

  @override
  LoomVodozemacNativeInbound createInboundSession({
    required LoomVodozemacNativeHandle account,
    required Object remoteIdentityKey,
    required Object message,
  }) {
    final identity = Uint8List.fromList(
      utf8.encode(jsonEncode(remoteIdentityKey)),
    );
    final messageBytes = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    try {
      return _withTwoInputs(
        identity,
        messageBytes,
        maxFirst: 4096,
        maxSecond: _maxMessageBytes,
        invoke: (first, firstLength, second, secondLength) {
          final result = _inbound(
            _value(account),
            first,
            firstLength,
            second,
            secondLength,
          );
          _checkStatus(result.status);
          final session = LoomVodozemacNativeHandle(result.sessionHandle);
          if (!session.isValid) {
            throw const LoomVodozemacHandleEngineException(
              'invalid_native_handle',
            );
          }
          final plaintext = _takeBuffer(
            result.plaintext,
            maxBytes: 1024 * 1024,
          );
          return LoomVodozemacNativeInbound(
            session: session,
            plaintext: plaintext,
          );
        },
      );
    } finally {
      loomZeroBytes(identity);
      loomZeroBytes(messageBytes);
    }
  }

  @override
  Object encrypt({
    required LoomVodozemacNativeHandle session,
    required Uint8List plaintext,
  }) {
    final bytes = _withInput(
      plaintext,
      maxBytes: 1024 * 1024,
      invoke: (pointer, length) => _takeBuffer(
        _encrypt(_value(session), pointer, length),
        maxBytes: _maxMessageBytes,
      ),
    );
    try {
      return _decodeJson(bytes);
    } finally {
      loomZeroBytes(bytes);
    }
  }

  @override
  Uint8List decrypt({
    required LoomVodozemacNativeHandle session,
    required Object message,
  }) {
    final encoded = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    try {
      return _withInput(
        encoded,
        maxBytes: _maxMessageBytes,
        invoke: (pointer, length) => _takeBuffer(
          _decrypt(_value(session), pointer, length),
          maxBytes: 1024 * 1024,
        ),
      );
    } finally {
      loomZeroBytes(encoded);
    }
  }

  @override
  void closeHandle(LoomVodozemacNativeHandle handle) {
    final status = _handleClose(_value(handle));
    if (status != 0 && status != 2) _checkStatus(status);
  }

  int _value(LoomVodozemacNativeHandle handle) {
    if (!handle.isValid) {
      throw const LoomVodozemacHandleEngineException('invalid_native_handle');
    }
    return handle.value;
  }

  LoomVodozemacNativeHandle _handleFrom(_NativeHandleResult result) {
    _checkStatus(result.status);
    final handle = LoomVodozemacNativeHandle(result.handle);
    if (!handle.isValid) {
      throw const LoomVodozemacHandleEngineException('invalid_native_handle');
    }
    return handle;
  }

  Uint8List _takeBuffer(_NativeOwnedBuffer buffer, {required int maxBytes}) {
    _checkStatus(buffer.status);
    if (buffer.len < 0 ||
        buffer.len > maxBytes ||
        buffer.capacity < buffer.len ||
        (buffer.len > 0 && buffer.ptr.address == 0)) {
      if (buffer.ptr.address != 0) _bufferFree(buffer);
      throw const LoomVodozemacHandleEngineException('invalid_native_buffer');
    }
    try {
      return buffer.len == 0
          ? Uint8List(0)
          : Uint8List.fromList(buffer.ptr.asTypedList(buffer.len));
    } finally {
      if (buffer.ptr.address != 0) _bufferFree(buffer);
    }
  }

  LoomVodozemacPublicInventory _decodeInventory(Uint8List bytes) {
    try {
      final decoded = _decodeJson(bytes);
      if (decoded is! Map<String, dynamic>) {
        throw const LoomVodozemacHandleEngineException(
          'invalid_public_inventory',
        );
      }
      List<Object> keys(String name, int max) {
        final raw = decoded[name];
        if (raw is! List || raw.length > max) {
          throw const LoomVodozemacHandleEngineException(
            'invalid_public_inventory',
          );
        }
        return List<Object>.unmodifiable(raw.cast<Object>());
      }

      final stored = decoded['stored_one_time_key_count'];
      final maximum = decoded['max_one_time_key_count'];
      if (stored is! int || maximum is! int || stored < 0 || maximum < 1) {
        throw const LoomVodozemacHandleEngineException(
          'invalid_public_inventory',
        );
      }
      final curve = decoded['curve25519'];
      final ed = decoded['ed25519'];
      if (curve == null || ed == null) {
        throw const LoomVodozemacHandleEngineException(
          'invalid_public_inventory',
        );
      }
      return LoomVodozemacPublicInventory(
        curve25519: curve,
        ed25519: ed,
        oneTimeKeys: keys('one_time_keys', 100),
        fallbackKeys: keys('fallback_keys', 1),
        storedOneTimeKeyCount: stored,
        maxOneTimeKeyCount: maximum,
      );
    } finally {
      loomZeroBytes(bytes);
    }
  }

  Object _decodeJson(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const LoomVodozemacHandleEngineException('invalid_native_json');
    }
  }

  T _withInput<T>(
    Uint8List bytes, {
    required int maxBytes,
    required T Function(Pointer<Uint8>, int) invoke,
  }) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const LoomVodozemacHandleEngineException('invalid_input_size');
    }
    final native = calloc<Uint8>(bytes.length);
    try {
      native.asTypedList(bytes.length).setAll(0, bytes);
      return invoke(native, bytes.length);
    } finally {
      native.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(native);
    }
  }

  T _withTwoInputs<T>(
    Uint8List first,
    Uint8List second, {
    required int maxFirst,
    required int maxSecond,
    required T Function(Pointer<Uint8>, int, Pointer<Uint8>, int) invoke,
  }) => _withInput(
    first,
    maxBytes: maxFirst,
    invoke: (firstPointer, firstLength) => _withInput(
      second,
      maxBytes: maxSecond,
      invoke: (secondPointer, secondLength) =>
          invoke(firstPointer, firstLength, secondPointer, secondLength),
    ),
  );

  void _checkStatus(int status) {
    if (status == 0) return;
    final code = switch (status) {
      1 => 'invalid_argument',
      2 => 'invalid_handle',
      3 => 'invalid_state',
      4 => 'crypto_failure',
      5 => 'serialization_failure',
      6 => 'internal_failure',
      _ => 'unknown_native_status',
    };
    throw LoomVodozemacHandleEngineException(code);
  }
}
