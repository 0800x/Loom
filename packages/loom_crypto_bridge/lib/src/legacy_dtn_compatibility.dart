import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

import 'relay_sealing.dart';

const _compatKind = 'loom.legacy-dtn.sealed.v1';
const _packetDomain = 'Loom-Legacy-DTN-PacketId-v1';
const _packetGenerationDomain = 'Loom-Legacy-DTN-PacketId-v2';
const _aadDomain = 'Loom-Legacy-DTN-AAD-v1';

String _b64u(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

final class LoomLegacyDtnMessageCapsule {
  const LoomLegacyDtnMessageCapsule({
    required this.conversationId,
    required this.clientId,
    required this.senderAddress,
    required this.type,
    required this.ciphertext,
    required this.protocolVersion,
    required this.createdAt,
    this.replyToMessageId,
    this.metadata = const <String, Object?>{},
  });

  final String conversationId;
  final String clientId;
  final String senderAddress;
  final LoomMessageType type;
  final String ciphertext;
  final String protocolVersion;
  final DateTime createdAt;
  final String? replyToMessageId;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'conversationId': conversationId,
    'clientId': clientId,
    'senderAddress': senderAddress,
    'type': type.name,
    'ciphertext': ciphertext,
    'protocolVersion': protocolVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
    'metadata': metadata,
  };

  factory LoomLegacyDtnMessageCapsule.fromJson(Map<String, Object?> json) {
    String text(String key, {int max = 1024 * 1024}) {
      final value = json[key];
      if (value is! String ||
          value.trim() != value ||
          value.isEmpty ||
          value.length > max ||
          value.contains(RegExp(r'[\x00]'))) {
        throw FormatException('Invalid legacy DTN capsule $key');
      }
      return value;
    }

    if (json['version'] != 1) {
      throw const FormatException('Unsupported legacy DTN capsule version');
    }
    final createdAt = DateTime.tryParse(text('createdAt', max: 64))?.toUtc();
    if (createdAt == null || createdAt.year < 2020 || createdAt.year >= 2200) {
      throw const FormatException('Invalid legacy DTN capsule timestamp');
    }
    final typeRaw = text('type', max: 32);
    LoomMessageType type;
    try {
      type = LoomMessageType.values.byName(typeRaw.toLowerCase());
    } catch (_) {
      throw const FormatException('Invalid legacy DTN capsule message type');
    }
    final metadataRaw = json['metadata'] ?? const <String, Object?>{};
    if (metadataRaw is! Map) {
      throw const FormatException('Invalid legacy DTN capsule metadata');
    }
    final metadata = metadataRaw.map(
      (key, value) => MapEntry(key.toString(), value as Object?),
    );
    final encodedMetadata = utf8.encode(jsonEncode(metadata));
    if (encodedMetadata.length > 32 * 1024) {
      throw const FormatException('Legacy DTN capsule metadata is too large');
    }
    final reply = json['replyToMessageId'];
    if (reply != null &&
        (reply is! String || reply.isEmpty || reply.length > 256)) {
      throw const FormatException('Invalid legacy DTN capsule reply id');
    }
    return LoomLegacyDtnMessageCapsule(
      conversationId: text('conversationId', max: 256),
      clientId: text('clientId', max: 256),
      senderAddress: text('senderAddress', max: 512),
      type: type,
      ciphertext: text('ciphertext', max: 1024 * 1024),
      protocolVersion: text('protocolVersion', max: 128),
      createdAt: createdAt,
      replyToMessageId: reply as String?,
      metadata: metadata,
    );
  }
}

final class LoomLegacyDtnSealedDraft {
  LoomLegacyDtnSealedDraft({
    required this.packetId,
    required Uint8List mailboxToken,
    required Uint8List encryptedPayload,
  }) : mailboxToken = Uint8List.fromList(mailboxToken),
       encryptedPayload = Uint8List.fromList(encryptedPayload);

  final String packetId;
  final Uint8List mailboxToken;
  final Uint8List encryptedPayload;
}

/// Compatibility bridge that keeps the current production E2EE envelope intact
/// while adding a recipient-only outer seal before DTN relays see it.
///
/// Nothing from [LoomLegacyDtnMessageCapsule] is copied into routable packet
/// metadata. Relays see only a stable opaque packet id, rotating mailbox token,
/// coarse expiry/priority and this sealed payload.
final class LoomLegacyDtnCompatibilityCodec {
  LoomLegacyDtnCompatibilityCodec({LoomRelaySealer? sealer})
    : _sealer = sealer ?? LoomRelaySealer();

  final LoomRelaySealer _sealer;

  Future<LoomLegacyDtnSealedDraft> seal({
    required LoomLegacyDtnMessageCapsule capsule,
    required String recipientDeviceId,
    required String recipientAgreementPublicKey,
    required DateTime now,
    int packetGeneration = 0,
  }) async {
    final packetId = await deterministicPacketId(
      clientId: capsule.clientId,
      recipientDeviceId: recipientDeviceId,
      packetGeneration: packetGeneration,
    );
    final mailboxTag = await _sealer.recipientTag(
      recipientAgreementPublicKey: recipientAgreementPublicKey,
      time: now,
    );
    final mailboxToken = Uint8List.fromList(
      base64Url.decode(base64Url.normalize(mailboxTag)),
    );
    final clear = Uint8List.fromList(utf8.encode(jsonEncode(capsule.toJson())));
    if (clear.isEmpty || clear.length > 240 * 1024) {
      throw const FormatException(
        'Legacy DTN compatibility capsule exceeds 240 KiB',
      );
    }
    final sealed = await _sealer.seal(
      plaintext: clear,
      recipientAgreementPublicKey: recipientAgreementPublicKey,
      associatedData: associatedData(
        packetId: packetId,
        mailboxToken: mailboxToken,
        recipientDeviceId: recipientDeviceId,
      ),
    );
    return LoomLegacyDtnSealedDraft(
      packetId: packetId,
      mailboxToken: mailboxToken,
      encryptedPayload: encodeSealedPayload(sealed),
    );
  }

  /// Returns a stable packet id for one local retry generation.
  ///
  /// Generation zero keeps the original v1 derivation for compatibility with
  /// existing callers/tests. Product custody supplies a bounded epoch so a
  /// message that remains queued beyond packet expiry can obtain a fresh id
  /// instead of being permanently pinned to an expired tombstone.
  Future<String> deterministicPacketId({
    required String clientId,
    required String recipientDeviceId,
    int packetGeneration = 0,
  }) async {
    if (clientId.isEmpty ||
        clientId.length > 256 ||
        recipientDeviceId.isEmpty ||
        recipientDeviceId.length > 256 ||
        packetGeneration < 0 ||
        packetGeneration > 0x7fffffff) {
      throw const FormatException('Invalid legacy DTN packet correlation');
    }
    final correlation = packetGeneration == 0
        ? <Object?>[_packetDomain, clientId, recipientDeviceId]
        : <Object?>[
            _packetGenerationDomain,
            packetGeneration,
            clientId,
            recipientDeviceId,
          ];
    final digest = await Sha256().hash(utf8.encode(jsonEncode(correlation)));
    return 'pkt_${_b64u(digest.bytes)}';
  }

  Uint8List associatedData({
    required String packetId,
    required Uint8List mailboxToken,
    required String recipientDeviceId,
  }) => Uint8List.fromList(
    utf8.encode(
      jsonEncode(<Object?>[
        _aadDomain,
        packetId,
        _b64u(mailboxToken),
        recipientDeviceId,
      ]),
    ),
  );

  Uint8List encodeSealedPayload(LoomRelaySealedPayload payload) {
    if (payload.version != 1) {
      throw const FormatException('Unsupported relay sealed payload version');
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'kind': _compatKind,
          'sealed': <String, Object?>{
            'version': payload.version,
            'ephemeralPublicKey': payload.ephemeralPublicKey,
            'nonce': payload.nonce,
            'ciphertext': payload.ciphertext,
            'mac': payload.mac,
          },
        }),
      ),
    );
  }

  LoomRelaySealedPayload decodeSealedPayload(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 1024 * 1024) {
      throw const FormatException('Invalid legacy DTN sealed payload size');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map || decoded['kind'] != _compatKind) {
      throw const FormatException('Not a legacy DTN compatibility payload');
    }
    final sealedRaw = decoded['sealed'];
    if (sealedRaw is! Map) {
      throw const FormatException('Invalid legacy DTN sealed payload');
    }
    final sealed = sealedRaw.map(
      (key, value) => MapEntry(key.toString(), value as Object?),
    );
    String field(String key, {int max = 512 * 1024}) {
      final value = sealed[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid legacy DTN sealed $key');
      }
      return value;
    }

    final version = sealed['version'];
    if (version != 1) {
      throw const FormatException('Unsupported legacy DTN sealed version');
    }
    return LoomRelaySealedPayload(
      version: 1,
      ephemeralPublicKey: field('ephemeralPublicKey', max: 128),
      nonce: field('nonce', max: 128),
      ciphertext: field('ciphertext'),
      mac: field('mac', max: 128),
    );
  }

  LoomLegacyDtnMessageCapsule decodeClearCapsule(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 240 * 1024) {
      throw const FormatException('Invalid legacy DTN clear capsule size');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Invalid legacy DTN clear capsule');
    }
    return LoomLegacyDtnMessageCapsule.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value as Object?)),
    );
  }
}
