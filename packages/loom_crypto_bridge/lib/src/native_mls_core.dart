import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:loom_models/loom_models.dart';

final class _Output extends Struct {
  external Pointer<Uint8> data;
  @UintPtr()
  external int length;
}

typedef _CallNative = Pointer<_Output> Function(Pointer<Uint8>, UintPtr);
typedef _Call = Pointer<_Output> Function(Pointer<Uint8>, int);
typedef _ReleaseNative = Void Function(Pointer<_Output>);
typedef _Release = void Function(Pointer<_Output>);

class LoomMlsOperation {
  const LoomMlsOperation({required this.state, required this.result});
  final LoomMlsSealedState state;
  final Map<String, Object?> result;
}

/// Native MLS operations run off the UI isolate. State leaves native code only
/// as an authenticated encrypted blob. Platform storage owns the sealing key.
class LoomNativeMlsCore {
  const LoomNativeMlsCore({this.libraryPath});
  final String? libraryPath;
  static String get defaultLibraryPath => Platform.isWindows
      ? 'loom_mls.dll'
      : Platform.isMacOS
          ? '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libloom_mls.dylib'
          : Platform.isIOS
              ? 'libloom_mls.dylib'
              : 'libloom_mls.so';
  Future<LoomMlsOperation> execute({
    required String deviceId,
    required List<int> sealingKey,
    required String operation,
    LoomMlsSealedState? state,
    String? groupId,
    Map<String, Object?> arguments = const {},
  }) async {
    if (sealingKey.length != 32) throw ArgumentError('Invalid MLS sealing key');
    final request = <String, Object?>{
      'operation': operation,
      'device': utf8.encode(deviceId),
      'key': List<int>.of(sealingKey),
      'generation': state?.generation ?? 0,
      'state': state?.bytes ?? <int>[],
      'group': groupId == null ? <int>[] : utf8.encode(groupId),
      ...arguments,
    };
    final path = libraryPath ?? defaultLibraryPath;
    late final Map<String, Object?> response;
    try {
      response = await Isolate.run(() => _execute(path, request));
    } finally {
      (request['key'] as List<int>).fillRange(0, 32, 0);
    }
    if (response['error'] != null) throw StateError('MLS operation rejected');
    final next = LoomMlsSealedState(
      generation: response['generation'] as int,
      bytes: (response['state'] as List).cast<int>(),
    );
    if (next.generation != (state?.generation ?? 0) + 1 || next.bytes.isEmpty) {
      throw StateError('Invalid native MLS state transition');
    }
    return LoomMlsOperation(
      state: next,
      result: Map<String, Object?>.from(response['result'] as Map),
    );
  }

  static Map<String, Object?> _execute(
    String path,
    Map<String, Object?> request,
  ) {
    final library = DynamicLibrary.open(path);
    final call = library.lookupFunction<_CallNative, _Call>(
      'loom_mls_request',
    );
    final release = library.lookupFunction<_ReleaseNative, _Release>(
      'loom_mls_release',
    );
    final encoded = Uint8List.fromList(utf8.encode(jsonEncode(request)));
    final input = calloc<Uint8>(encoded.length);
    Pointer<_Output>? output;
    try {
      input.asTypedList(encoded.length).setAll(0, encoded);
      output = call(input, encoded.length);
      if (output.address == 0 ||
          output.ref.length <= 0 ||
          output.ref.length > 128 * 1024 * 1024) {
        throw StateError('Invalid native MLS response');
      }
      return Map<String, Object?>.from(
        jsonDecode(utf8.decode(output.ref.data.asTypedList(output.ref.length)))
            as Map,
      );
    } finally {
      input.asTypedList(encoded.length).fillRange(0, encoded.length, 0);
      encoded.fillRange(0, encoded.length, 0);
      calloc.free(input);
      if (output != null && output.address != 0) release(output);
      (request['key'] as List<int>).fillRange(0, 32, 0);
    }
  }
}
