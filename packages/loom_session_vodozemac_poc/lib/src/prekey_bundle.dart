import 'dart:convert';
import 'dart:typed_data';

enum LoomVodozemacPocPrekeyKind {
  oneTime('one_time'),
  fallback('fallback');

  const LoomVodozemacPocPrekeyKind(this.wireName);
  final String wireName;

  static LoomVodozemacPocPrekeyKind parse(Object? value) {
    for (final kind in values) {
      if (value == kind.wireName) return kind;
    }
    throw const FormatException('Invalid vodozemac PoC prekey kind');
  }
}

final class LoomVodozemacPocPrekeyBundle {
  const LoomVodozemacPocPrekeyBundle({
    required this.identityKey,
    required this.oneTimeKey,
    this.keyKind = LoomVodozemacPocPrekeyKind.oneTime,
  });

  /// Version 1 had no explicit key kind and is decoded as `one_time`.
  static const int wireVersion = 2;
  static const int legacyWireVersion = 1;
  static const String protocol = 'Loom-Vodozemac-Olm-v1-poc';

  final Object identityKey;

  /// Historical field name retained for source compatibility. For a version-2
  /// bundle this is the public asynchronous prekey and may be either a one-time
  /// key or a fallback key as indicated by [keyKind].
  final Object oneTimeKey;
  final LoomVodozemacPocPrekeyKind keyKind;

  Uint8List encode() {
    final bytes = utf8.encode(
      jsonEncode(<String, Object?>{
        'version': wireVersion,
        'protocol': protocol,
        'keyKind': keyKind.wireName,
        'identityKey': identityKey,
        'oneTimeKey': oneTimeKey,
      }),
    );
    if (bytes.isEmpty || bytes.length > 16 * 1024) {
      throw const FormatException('Vodozemac PoC prekey bundle exceeds bounds');
    }
    return Uint8List.fromList(bytes);
  }

  static LoomVodozemacPocPrekeyBundle decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 16 * 1024) {
      throw const FormatException('Invalid vodozemac PoC prekey bundle size');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> || decoded['protocol'] != protocol) {
      throw const FormatException('Unsupported vodozemac PoC prekey bundle');
    }
    final version = decoded['version'];
    if (version != legacyWireVersion && version != wireVersion) {
      throw const FormatException('Unsupported vodozemac PoC prekey bundle');
    }
    final identity = decoded['identityKey'];
    final oneTime = decoded['oneTimeKey'];
    _validateJsonKey(identity);
    _validateJsonKey(oneTime);
    final kind = version == legacyWireVersion
        ? LoomVodozemacPocPrekeyKind.oneTime
        : LoomVodozemacPocPrekeyKind.parse(decoded['keyKind']);
    return LoomVodozemacPocPrekeyBundle(
      identityKey: identity as Object,
      oneTimeKey: oneTime as Object,
      keyKind: kind,
    );
  }

  static void _validateJsonKey(Object? value) {
    if (value is String) {
      if (value.isEmpty || value.length > 4096) {
        throw const FormatException('Invalid vodozemac PoC public key');
      }
      return;
    }
    if (value is List &&
        value.length == 32 &&
        value.every((byte) => byte is int && byte >= 0 && byte <= 255)) {
      return;
    }
    if (value is num || value is bool) return;
    throw const FormatException('Invalid vodozemac PoC public key');
  }
}
