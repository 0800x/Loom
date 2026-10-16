import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class LoomLanAnnouncement {
  const LoomLanAnnouncement({
    required this.schemaVersion,
    required this.nodeId,
    required this.domain,
    required this.endpoint,
    required this.publicKey,
    required this.fingerprint,
    required this.timestamp,
    required this.nonce,
    required this.signature,
  });

  final int schemaVersion;
  final String nodeId;
  final String domain;
  final Uri endpoint;
  final String publicKey;
  final String fingerprint;
  final DateTime timestamp;
  final String nonce;
  final String signature;

  factory LoomLanAnnouncement.fromJson(Map<String, Object?> json) {
    String req(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty)
        throw FormatException('Invalid LAN announcement $key');
      return value.trim();
    }

    final version = json['schemaVersion'];
    if (version != 1)
      throw FormatException('Unsupported LAN announcement schema: $version');
    final endpoint = Uri.tryParse(req('endpoint'));
    final timestamp = DateTime.tryParse(req('timestamp'))?.toUtc();
    if (endpoint == null ||
        !endpoint.hasAuthority ||
        endpoint.scheme != 'https') {
      throw const FormatException('LAN endpoint must be HTTPS');
    }
    if (timestamp == null)
      throw const FormatException('Invalid LAN announcement timestamp');
    return LoomLanAnnouncement(
      schemaVersion: version as int,
      nodeId: req('nodeId'),
      domain: req('domain').toLowerCase(),
      endpoint: endpoint,
      publicKey: req('publicKey'),
      fingerprint: req('fingerprint'),
      timestamp: timestamp,
      nonce: req('nonce'),
      signature: req('signature'),
    );
  }

  String canonicalPayload() => [
        'loom-lan-announcement-v1',
        nodeId,
        domain,
        endpoint.toString(),
        publicKey,
        fingerprint,
        timestamp.toIso8601String(),
        nonce,
      ].join('\n');
}

class LoomLanAnnouncementVerifier {
  LoomLanAnnouncementVerifier({DateTime Function()? now})
      : _now = now ?? (() => DateTime.now().toUtc());

  final DateTime Function() _now;
  final Ed25519 _ed25519 = Ed25519();

  Future<void> verify(
    LoomLanAnnouncement announcement, {
    required String expectedNodeId,
    required String expectedPublicKey,
    Duration maxAge = const Duration(minutes: 2),
  }) async {
    if (announcement.nodeId != expectedNodeId ||
        announcement.publicKey != expectedPublicKey) {
      throw const FormatException(
        'LAN announcement identity does not match the trusted Node',
      );
    }
    final delta = _now().difference(announcement.timestamp);
    final age = Duration(microseconds: delta.inMicroseconds.abs());
    if (age > maxAge) throw const FormatException('LAN announcement is stale');
    final keyBytes = base64Decode(announcement.publicKey);
    final signatureBytes = base64Decode(announcement.signature);
    if (keyBytes.length != 32 || signatureBytes.length != 64) {
      throw const FormatException('Invalid LAN signature material');
    }
    final ok = await _ed25519.verify(
      utf8.encode(announcement.canonicalPayload()),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) throw const FormatException('Invalid LAN announcement signature');
  }
}
