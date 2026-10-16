import 'dart:convert';
import 'dart:typed_data';

import 'prekey_authorization.dart';

/// Versioned transport serialization for a device-authorized provider prekey.
///
/// These bytes are NOT the bytes signed by the device. The signature covers
/// [LoomPrekeyAuthorizationStatement.canonicalBytes], while this envelope is
/// only a strict carrier suitable for an untrusted delivery service.
final class LoomAuthorizedPrekeyWireV1 {
  const LoomAuthorizedPrekeyWireV1._();

  static const int version = 1;
  static const int maxWireBytes = 128 * 1024;

  static Uint8List encode(LoomAuthorizedPrekeyBundle authorization) {
    final statement = authorization.statement;
    statement.validate();
    if (!statement.authorizesBundle(authorization.providerBundle)) {
      throw const FormatException(
        'Prekey authorization bundle digest mismatch',
      );
    }
    final value = <String, Object?>{
      'version': version,
      'accountId': statement.accountId,
      'deviceId': statement.deviceId,
      'deviceKeyVersion': statement.deviceKeyVersion,
      'providerProtocolVersion': statement.providerProtocolVersion,
      'prekeyId': statement.prekeyId,
      'keyKind': statement.keyKind.wireName,
      'providerBundleSha256': _base64UrlNoPadding(
        statement.providerBundleSha256,
      ),
      'notBeforeMs': statement.notBefore.toUtc().millisecondsSinceEpoch,
      'expiresAtMs': statement.expiresAt.toUtc().millisecondsSinceEpoch,
      'providerBundle': _base64UrlNoPadding(authorization.providerBundle),
      'deviceSignature': _base64UrlNoPadding(authorization.deviceSignature),
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    if (bytes.isEmpty || bytes.length > maxWireBytes) {
      throw const FormatException(
        'Authorized prekey wire envelope exceeds bounds',
      );
    }
    return bytes;
  }

  static LoomAuthorizedPrekeyBundle decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxWireBytes) {
      throw const FormatException('Invalid authorized prekey wire size');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Authorized prekey wire root must be an object',
      );
    }
    const allowed = <String>{
      'version',
      'accountId',
      'deviceId',
      'deviceKeyVersion',
      'providerProtocolVersion',
      'prekeyId',
      'keyKind',
      'providerBundleSha256',
      'notBeforeMs',
      'expiresAtMs',
      'providerBundle',
      'deviceSignature',
    };
    if (decoded.length != allowed.length ||
        decoded.keys.any((key) => !allowed.contains(key)) ||
        decoded['version'] != version) {
      throw const FormatException(
        'Unsupported authorized prekey wire envelope',
      );
    }

    String requiredString(String key, {int max = 4096}) {
      final value = decoded[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid authorized prekey field: $key');
      }
      return value;
    }

    int requiredInt(String key) {
      final value = decoded[key];
      if (value is! int) {
        throw FormatException('Invalid authorized prekey field: $key');
      }
      return value;
    }

    final kindName = requiredString('keyKind', max: 16);
    final kind = LoomAuthorizedPrekeyKind.values.where(
      (candidate) => candidate.wireName == kindName,
    );
    if (kind.length != 1) {
      throw const FormatException('Invalid authorized prekey kind');
    }
    final digest = _decodeBase64Url(
      requiredString('providerBundleSha256', max: 64),
      maxBytes: 32,
    );
    if (digest.length != 32) {
      throw const FormatException('Invalid authorized prekey digest');
    }
    final providerBundle = _decodeBase64Url(
      requiredString('providerBundle', max: 96 * 1024),
      maxBytes: 64 * 1024,
    );
    final signature = _decodeBase64Url(
      requiredString('deviceSignature', max: 1024),
      maxBytes: 512,
    );

    final statement = LoomPrekeyAuthorizationStatement.fromDigest(
      accountId: requiredString('accountId', max: 256),
      deviceId: requiredString('deviceId', max: 256),
      deviceKeyVersion: requiredInt('deviceKeyVersion'),
      providerProtocolVersion: requiredString(
        'providerProtocolVersion',
        max: 128,
      ),
      prekeyId: requiredString('prekeyId', max: 128),
      keyKind: kind.single,
      providerBundleSha256: digest,
      notBefore: DateTime.fromMillisecondsSinceEpoch(
        requiredInt('notBeforeMs'),
        isUtc: true,
      ),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        requiredInt('expiresAtMs'),
        isUtc: true,
      ),
    );
    return LoomAuthorizedPrekeyBundle(
      statement: statement,
      providerBundle: providerBundle,
      deviceSignature: signature,
    );
  }

  static String _base64UrlNoPadding(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  static Uint8List _decodeBase64Url(String value, {required int maxBytes}) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw const FormatException('Invalid authorized prekey base64url');
    }
    final paddingLength = (4 - value.length % 4) % 4;
    final padded = '$value${List<String>.filled(paddingLength, '=').join()}';
    final decoded = base64Url.decode(padded);
    if (decoded.isEmpty || decoded.length > maxBytes) {
      throw const FormatException(
        'Authorized prekey binary field exceeds bounds',
      );
    }
    return Uint8List.fromList(decoded);
  }
}
