import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum LoomAuthorizedPrekeyKind {
  oneTime('one_time'),
  fallback('fallback');

  const LoomAuthorizedPrekeyKind(this.wireName);
  final String wireName;
}

/// Canonical statement signed by an already-authorized Loom device key before
/// provider prekey material is uploaded to an untrusted delivery service.
///
/// This is intentionally not Protobuf-signing. [canonicalBytes] uses a pinned,
/// length-prefixed binary encoding with a domain separator so serialization
/// differences cannot change what the signature means.
final class LoomPrekeyAuthorizationStatement {
  LoomPrekeyAuthorizationStatement({
    required this.accountId,
    required this.deviceId,
    required this.deviceKeyVersion,
    required this.providerProtocolVersion,
    required this.prekeyId,
    required this.keyKind,
    required Uint8List providerBundle,
    required this.notBefore,
    required this.expiresAt,
  }) : providerBundleSha256 = Uint8List.fromList(
          sha256.convert(providerBundle).bytes,
        ) {
    validate();
  }

  LoomPrekeyAuthorizationStatement.fromDigest({
    required this.accountId,
    required this.deviceId,
    required this.deviceKeyVersion,
    required this.providerProtocolVersion,
    required this.prekeyId,
    required this.keyKind,
    required Uint8List providerBundleSha256,
    required this.notBefore,
    required this.expiresAt,
  }) : providerBundleSha256 = Uint8List.fromList(providerBundleSha256) {
    validate();
  }

  static const int version = 1;
  static const String domain = 'Loom-DevicePrekeyAuthorization-v1';
  static const Duration maximumLifetime = Duration(days: 31);

  final String accountId;
  final String deviceId;
  final int deviceKeyVersion;
  final String providerProtocolVersion;
  final String prekeyId;
  final LoomAuthorizedPrekeyKind keyKind;
  final Uint8List providerBundleSha256;
  final DateTime notBefore;
  final DateTime expiresAt;

  void validate() {
    _requireIdentifier(accountId, 'account id', min: 3, max: 256);
    _requireIdentifier(deviceId, 'device id', min: 3, max: 256);
    _requireIdentifier(
      providerProtocolVersion,
      'provider protocol version',
      min: 3,
      max: 128,
    );
    _requireIdentifier(prekeyId, 'prekey id', min: 8, max: 128);
    if (deviceKeyVersion < 1 || deviceKeyVersion > 0x7fffffff) {
      throw const FormatException('Invalid device key version');
    }
    if (providerBundleSha256.length != 32) {
      throw const FormatException('Invalid provider prekey bundle digest');
    }
    final start = notBefore.toUtc();
    final end = expiresAt.toUtc();
    if (!end.isAfter(start) || end.difference(start) > maximumLifetime) {
      throw const FormatException('Invalid prekey authorization lifetime');
    }
  }

  bool authorizesBundle(Uint8List providerBundle) {
    final digest = sha256.convert(providerBundle).bytes;
    if (digest.length != providerBundleSha256.length) return false;
    var difference = 0;
    for (var i = 0; i < digest.length; i += 1) {
      difference |= digest[i] ^ providerBundleSha256[i];
    }
    return difference == 0;
  }

  bool isValidAt(DateTime now, {Duration clockSkew = Duration.zero}) {
    if (clockSkew.isNegative || clockSkew > const Duration(minutes: 10)) {
      throw ArgumentError.value(clockSkew, 'clockSkew');
    }
    final current = now.toUtc();
    return !current.isBefore(notBefore.toUtc().subtract(clockSkew)) &&
        current.isBefore(expiresAt.toUtc().add(clockSkew));
  }

  Uint8List canonicalBytes() {
    validate();
    final builder = BytesBuilder(copy: false);
    _writeString(builder, domain);
    _writeUint32(builder, version);
    _writeString(builder, accountId);
    _writeString(builder, deviceId);
    _writeUint32(builder, deviceKeyVersion);
    _writeString(builder, providerProtocolVersion);
    _writeString(builder, prekeyId);
    _writeString(builder, keyKind.wireName);
    _writeBytes(builder, providerBundleSha256);
    _writeInt64(builder, notBefore.toUtc().millisecondsSinceEpoch);
    _writeInt64(builder, expiresAt.toUtc().millisecondsSinceEpoch);
    return builder.takeBytes();
  }

  static void _requireIdentifier(
    String value,
    String label, {
    required int min,
    required int max,
  }) {
    if (value.trim() != value ||
        value.length < min ||
        value.length > max ||
        value.contains('\u0000') ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw FormatException('Invalid $label');
    }
  }

  static void _writeString(BytesBuilder builder, String value) =>
      _writeBytes(builder, Uint8List.fromList(utf8.encode(value)));

  static void _writeBytes(BytesBuilder builder, List<int> value) {
    if (value.length > 1024 * 1024) {
      throw const FormatException('Canonical prekey field exceeds bounds');
    }
    _writeUint32(builder, value.length);
    builder.add(value);
  }

  static void _writeUint32(BytesBuilder builder, int value) {
    if (value < 0 || value > 0xffffffff) {
      throw const FormatException('Canonical uint32 out of range');
    }
    final data = ByteData(4)..setUint32(0, value, Endian.big);
    builder.add(data.buffer.asUint8List());
  }

  static void _writeInt64(BytesBuilder builder, int value) {
    final data = ByteData(8)..setInt64(0, value, Endian.big);
    builder.add(data.buffer.asUint8List());
  }
}

final class LoomAuthorizedPrekeyBundle {
  LoomAuthorizedPrekeyBundle({
    required this.statement,
    required Uint8List providerBundle,
    required Uint8List deviceSignature,
  })  : providerBundle = Uint8List.fromList(providerBundle),
        deviceSignature = Uint8List.fromList(deviceSignature) {
    statement.validate();
    if (!statement.authorizesBundle(this.providerBundle)) {
      throw const FormatException(
        'Authorized prekey statement does not match provider bundle',
      );
    }
    if (this.providerBundle.isEmpty || this.providerBundle.length > 64 * 1024) {
      throw const FormatException('Invalid provider prekey bundle size');
    }
    if (this.deviceSignature.isEmpty || this.deviceSignature.length > 512) {
      throw const FormatException('Invalid device prekey signature size');
    }
  }

  final LoomPrekeyAuthorizationStatement statement;
  final Uint8List providerBundle;
  final Uint8List deviceSignature;
}

/// Result handed to a session provider only after the device trust layer has
/// verified the signing key, revocation state, signature, validity interval,
/// and exact provider-bundle digest.
final class LoomVerifiedPrekeyBundle {
  LoomVerifiedPrekeyBundle._({
    required this.remoteAccountId,
    required this.remoteDeviceId,
    required this.remoteDeviceKeyVersion,
    required this.providerProtocolVersion,
    required this.prekeyId,
    required this.keyKind,
    required Uint8List providerBundle,
  }) : providerBundle = Uint8List.fromList(providerBundle);

  final String remoteAccountId;
  final String remoteDeviceId;
  final int remoteDeviceKeyVersion;
  final String providerProtocolVersion;
  final String prekeyId;
  final LoomAuthorizedPrekeyKind keyKind;
  final Uint8List providerBundle;
}

/// Implementations resolve the exact authorized device signing key/version and
/// return false for revoked, superseded, or unknown devices. This keeps
/// directory/trust-store policy outside the session provider without letting a
/// caller self-assert `verified=true`.
abstract interface class LoomAuthorizedDeviceSignatureVerifier {
  Future<bool> verifyAuthorizedDeviceSignature({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  });
}

final class LoomPrekeyAuthorizationVerifierV1 {
  const LoomPrekeyAuthorizationVerifierV1({
    required this.deviceSignatureVerifier,
    this.allowedClockSkew = const Duration(minutes: 2),
  });

  final LoomAuthorizedDeviceSignatureVerifier deviceSignatureVerifier;
  final Duration allowedClockSkew;

  Future<LoomVerifiedPrekeyBundle> verify({
    required LoomAuthorizedPrekeyBundle authorization,
    required DateTime now,
    required String expectedProviderProtocolVersion,
  }) async {
    final statement = authorization.statement;
    statement.validate();
    if (allowedClockSkew.isNegative ||
        allowedClockSkew > const Duration(minutes: 10)) {
      throw const FormatException('Invalid prekey verifier clock skew policy');
    }
    if (statement.providerProtocolVersion != expectedProviderProtocolVersion) {
      throw const FormatException(
        'Unexpected prekey provider protocol version',
      );
    }
    if (!statement.authorizesBundle(authorization.providerBundle)) {
      throw const FormatException('Prekey provider bundle digest mismatch');
    }
    if (!statement.isValidAt(now, clockSkew: allowedClockSkew)) {
      throw const FormatException(
        'Prekey authorization is not currently valid',
      );
    }
    final trusted =
        await deviceSignatureVerifier.verifyAuthorizedDeviceSignature(
      accountId: statement.accountId,
      deviceId: statement.deviceId,
      deviceKeyVersion: statement.deviceKeyVersion,
      canonicalPayload: statement.canonicalBytes(),
      signature: authorization.deviceSignature,
      now: now.toUtc(),
    );
    if (!trusted) {
      throw const FormatException(
        'Prekey device authorization verification failed',
      );
    }
    return LoomVerifiedPrekeyBundle._(
      remoteAccountId: statement.accountId,
      remoteDeviceId: statement.deviceId,
      remoteDeviceKeyVersion: statement.deviceKeyVersion,
      providerProtocolVersion: statement.providerProtocolVersion,
      prekeyId: statement.prekeyId,
      keyKind: statement.keyKind,
      providerBundle: authorization.providerBundle,
    );
  }
}

abstract interface class LoomPrekeyAuthorizationSigner {
  Future<LoomAuthorizedPrekeyBundle> authorize({
    required LoomPrekeyAuthorizationStatement statement,
    required Uint8List providerBundle,
  });
}
