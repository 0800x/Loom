import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ids.dart';

final class LoomDeviceAuthorizationV2 {
  LoomDeviceAuthorizationV2({
    required this.accountId,
    required this.deviceId,
    required this.deviceKeyVersion,
    required Uint8List signingPublicKey,
    required Uint8List agreementPublicKey,
    required this.issuedAt,
    required this.expiresAt,
    required List<String> capabilities,
    required Uint8List accountSignature,
  }) : signingPublicKey = Uint8List.fromList(signingPublicKey),
       agreementPublicKey = Uint8List.fromList(agreementPublicKey),
       capabilities = List.unmodifiable(capabilities),
       accountSignature = Uint8List.fromList(accountSignature) {
    validate();
  }

  static const int version = 2;
  static const String domain = 'Loom-DeviceAuthorization-v2';
  static const Duration maximumLifetime = Duration(days: 730);

  final LoomAccountId accountId;
  final LoomDeviceId deviceId;
  final int deviceKeyVersion;
  final Uint8List signingPublicKey;
  final Uint8List agreementPublicKey;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final List<String> capabilities;
  final Uint8List accountSignature;

  void validate() {
    if (deviceKeyVersion < 1 || deviceKeyVersion > 0x7fffffff) {
      throw const FormatException('Invalid device key version');
    }
    if (signingPublicKey.length != 32 || agreementPublicKey.length != 32) {
      throw const FormatException('Invalid device public key length');
    }
    if (accountSignature.length != 64) {
      throw const FormatException('Invalid account authorization signature');
    }
    final start = issuedAt.toUtc();
    final end = expiresAt.toUtc();
    if (!end.isAfter(start) || end.difference(start) > maximumLifetime) {
      throw const FormatException('Invalid device authorization lifetime');
    }
    if (capabilities.length > 64) {
      throw const FormatException('Too many device capabilities');
    }
    final seen = <String>{};
    for (final value in capabilities) {
      if (value.trim() != value ||
          value.isEmpty ||
          value.length > 64 ||
          !RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(value) ||
          !seen.add(value)) {
        throw const FormatException('Invalid device capability');
      }
    }
  }

  bool isValidAt(DateTime now) {
    final current = now.toUtc();
    return !current.isBefore(issuedAt.toUtc()) &&
        current.isBefore(expiresAt.toUtc());
  }

  Uint8List canonicalBytes() {
    validate();
    final writer = _CanonicalWriter(domain);
    writer.uint32(version);
    writer.string(accountId.value);
    writer.string(deviceId.value);
    writer.uint32(deviceKeyVersion);
    writer.bytes(signingPublicKey);
    writer.bytes(agreementPublicKey);
    writer.int64(issuedAt.toUtc().millisecondsSinceEpoch);
    writer.int64(expiresAt.toUtc().millisecondsSinceEpoch);
    final sorted = capabilities.toList()..sort();
    writer.uint32(sorted.length);
    for (final capability in sorted) {
      writer.string(capability);
    }
    return writer.takeBytes();
  }
}

final class LoomDeviceRevocationV2 {
  LoomDeviceRevocationV2({
    required this.accountId,
    required this.deviceId,
    required this.revokedThroughKeyVersion,
    required this.revocationSequence,
    required this.revokedAt,
    required this.reasonCode,
    required Uint8List accountSignature,
  }) : accountSignature = Uint8List.fromList(accountSignature) {
    validate();
  }

  static const int version = 2;
  static const String domain = 'Loom-DeviceRevocation-v2';

  final LoomAccountId accountId;
  final LoomDeviceId deviceId;
  final int revokedThroughKeyVersion;
  final int revocationSequence;
  final DateTime revokedAt;
  final String reasonCode;
  final Uint8List accountSignature;

  void validate() {
    if (revokedThroughKeyVersion < 1 ||
        revokedThroughKeyVersion > 0x7fffffff ||
        revocationSequence < 1 ||
        revocationSequence > 0x7fffffff) {
      throw const FormatException('Invalid device revocation version');
    }
    if (!RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(reasonCode)) {
      throw const FormatException('Invalid device revocation reason');
    }
    if (accountSignature.length != 64) {
      throw const FormatException('Invalid revocation signature');
    }
    final time = revokedAt.toUtc();
    if (time.year < 2020 || time.year >= 2200) {
      throw const FormatException('Invalid device revocation time');
    }
  }

  Uint8List canonicalBytes() {
    validate();
    final writer = _CanonicalWriter(domain);
    writer.uint32(version);
    writer.string(accountId.value);
    writer.string(deviceId.value);
    writer.uint32(revokedThroughKeyVersion);
    writer.uint32(revocationSequence);
    writer.int64(revokedAt.toUtc().millisecondsSinceEpoch);
    writer.string(reasonCode);
    return writer.takeBytes();
  }
}

final class LoomDeviceDirectorySnapshotV2 {
  LoomDeviceDirectorySnapshotV2({
    required this.accountId,
    required this.directoryRevision,
    required this.accountKeyVersion,
    required this.generatedAt,
    required List<LoomDeviceAuthorizationV2> authorizations,
    required List<LoomDeviceRevocationV2> revocations,
    required Uint8List accountSignature,
  }) : authorizations = List.unmodifiable(authorizations),
       revocations = List.unmodifiable(revocations),
       accountSignature = Uint8List.fromList(accountSignature) {
    validate();
  }

  static const int version = 2;
  static const String domain = 'Loom-DeviceDirectorySnapshot-v2';

  final LoomAccountId accountId;
  final int directoryRevision;
  final int accountKeyVersion;
  final DateTime generatedAt;
  final List<LoomDeviceAuthorizationV2> authorizations;
  final List<LoomDeviceRevocationV2> revocations;
  final Uint8List accountSignature;

  void validate() {
    if (directoryRevision < 1 ||
        directoryRevision > 0x7fffffff ||
        accountKeyVersion < 1 ||
        accountKeyVersion > 0x7fffffff) {
      throw const FormatException('Invalid device directory revision');
    }
    final time = generatedAt.toUtc();
    if (time.year < 2020 || time.year >= 2200) {
      throw const FormatException('Invalid directory generation time');
    }
    if (authorizations.length > 256 || revocations.length > 1024) {
      throw const FormatException('Device directory exceeds bounds');
    }
    if (accountSignature.length != 64) {
      throw const FormatException('Invalid device directory signature');
    }
    final authIds = <String>{};
    for (final authorization in authorizations) {
      authorization.validate();
      if (authorization.accountId != accountId ||
          !authIds.add(
            '${authorization.deviceId.value}:${authorization.deviceKeyVersion}',
          )) {
        throw const FormatException(
          'Invalid or duplicate device authorization',
        );
      }
    }
    final revocationIds = <String>{};
    for (final revocation in revocations) {
      revocation.validate();
      if (revocation.accountId != accountId ||
          !revocationIds.add(
            '${revocation.deviceId.value}:${revocation.revocationSequence}',
          )) {
        throw const FormatException('Invalid or duplicate device revocation');
      }
    }
  }

  Uint8List canonicalBytes() {
    validate();
    final writer = _CanonicalWriter(domain);
    writer.uint32(version);
    writer.string(accountId.value);
    writer.uint32(directoryRevision);
    writer.uint32(accountKeyVersion);
    writer.int64(generatedAt.toUtc().millisecondsSinceEpoch);

    final authorizationsSorted =
        authorizations.toList()..sort((a, b) {
          final byId = a.deviceId.value.compareTo(b.deviceId.value);
          return byId != 0
              ? byId
              : a.deviceKeyVersion.compareTo(b.deviceKeyVersion);
        });
    writer.uint32(authorizationsSorted.length);
    for (final authorization in authorizationsSorted) {
      writer.bytes(
        _signedObjectDigest(
          authorization.canonicalBytes(),
          authorization.accountSignature,
        ),
      );
    }

    final revocationsSorted =
        revocations.toList()..sort((a, b) {
          final byId = a.deviceId.value.compareTo(b.deviceId.value);
          return byId != 0
              ? byId
              : a.revocationSequence.compareTo(b.revocationSequence);
        });
    writer.uint32(revocationsSorted.length);
    for (final revocation in revocationsSorted) {
      writer.bytes(
        _signedObjectDigest(
          revocation.canonicalBytes(),
          revocation.accountSignature,
        ),
      );
    }
    return writer.takeBytes();
  }
}

abstract interface class LoomAccountSignatureVerifierV2 {
  Future<bool> verifyAccountSignature({
    required LoomAccountId accountId,
    required int accountKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  });
}

final class LoomVerifiedDeviceDirectorySnapshotV2 {
  LoomVerifiedDeviceDirectorySnapshotV2._(this.snapshot);
  final LoomDeviceDirectorySnapshotV2 snapshot;
}

final class LoomDeviceDirectoryVerifierV2 {
  const LoomDeviceDirectoryVerifierV2({required this.signatureVerifier});

  final LoomAccountSignatureVerifierV2 signatureVerifier;

  Future<LoomVerifiedDeviceDirectorySnapshotV2> verify(
    LoomDeviceDirectorySnapshotV2 snapshot, {
    required DateTime now,
  }) async {
    snapshot.validate();
    final current = now.toUtc();
    if (snapshot.generatedAt.toUtc().isAfter(
      current.add(const Duration(minutes: 10)),
    )) {
      throw const FormatException('Device directory is from the future');
    }
    for (final authorization in snapshot.authorizations) {
      if (!await signatureVerifier.verifyAccountSignature(
        accountId: snapshot.accountId,
        accountKeyVersion: snapshot.accountKeyVersion,
        canonicalPayload: authorization.canonicalBytes(),
        signature: authorization.accountSignature,
        now: current,
      )) {
        throw const FormatException('Invalid device authorization signature');
      }
    }
    for (final revocation in snapshot.revocations) {
      if (!await signatureVerifier.verifyAccountSignature(
        accountId: snapshot.accountId,
        accountKeyVersion: snapshot.accountKeyVersion,
        canonicalPayload: revocation.canonicalBytes(),
        signature: revocation.accountSignature,
        now: current,
      )) {
        throw const FormatException('Invalid device revocation signature');
      }
    }
    if (!await signatureVerifier.verifyAccountSignature(
      accountId: snapshot.accountId,
      accountKeyVersion: snapshot.accountKeyVersion,
      canonicalPayload: snapshot.canonicalBytes(),
      signature: snapshot.accountSignature,
      now: current,
    )) {
      throw const FormatException(
        'Invalid device directory snapshot signature',
      );
    }
    return LoomVerifiedDeviceDirectorySnapshotV2._(snapshot);
  }
}

Uint8List _signedObjectDigest(Uint8List canonicalBytes, Uint8List signature) {
  final builder =
      BytesBuilder(copy: false)
        ..add(canonicalBytes)
        ..add(signature);
  return Uint8List.fromList(sha256.convert(builder.takeBytes()).bytes);
}

final class _CanonicalWriter {
  _CanonicalWriter(String domain) {
    string(domain);
  }

  final BytesBuilder _builder = BytesBuilder(copy: false);

  void uint32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw const FormatException('Canonical uint32 out of range');
    }
    final data = ByteData(4)..setUint32(0, value, Endian.big);
    _builder.add(data.buffer.asUint8List());
  }

  void int64(int value) {
    final data = ByteData(8)..setInt64(0, value, Endian.big);
    _builder.add(data.buffer.asUint8List());
  }

  void string(String value) => bytes(Uint8List.fromList(utf8.encode(value)));

  void bytes(List<int> value) {
    if (value.length > 1024 * 1024) {
      throw const FormatException('Canonical field exceeds bounds');
    }
    uint32(value.length);
    _builder.add(value);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}
