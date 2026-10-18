import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

import 'relay_sealing.dart';

typedef LoomDirectMessageSigner = Future<List<int>> Function(List<int> payload);

typedef LoomDirectMessageOpener = Future<Uint8List> Function({
  required LoomRelaySealedPayload payload,
  required List<int> associatedData,
});

class LoomDirectMessageHeader {
  const LoomDirectMessageHeader({
    required this.senderAddress,
    required this.senderIdentityId,
    required this.senderDeviceId,
    required this.conversationId,
    this.replyToMessageId,
  });

  final String senderAddress;
  final String senderIdentityId;
  final String senderDeviceId;

  /// Stable E2EE conversation binding derived from participant identity IDs.
  /// It is intentionally not a Node-local conversation row ID.
  final String conversationId;
  final String? replyToMessageId;
}

/// Auditable one-to-one Loom message envelope.
///
/// The same plaintext is independently sealed to every active destination
/// device (including the sender's own devices for sent-history sync). The
/// outer envelope is signed by the sending device. Nodes only ever receive
/// this opaque JSON string and do not have the keys required to open a box.
class LoomDirectMessageCodec {
  LoomDirectMessageCodec({
    required LoomDirectMessageSigner signer,
    required LoomDirectMessageOpener opener,
    LoomRelaySealer? sealer,
  })  : _signer = signer,
        _opener = opener,
        _sealer = sealer ?? LoomRelaySealer();

  static const String protocolVersion = 'Loom-Direct-v1';
  static const int _maxDevices = 128;
  static const int _maxEnvelopeBytes = 1024 * 1024;
  static const int _maxPlaintextBytes = 64 * 1024;

  final LoomDirectMessageSigner _signer;
  final LoomDirectMessageOpener _opener;
  final LoomRelaySealer _sealer;
  final Ed25519 _ed25519 = Ed25519();

  Future<String> encryptText({
    required String conversationId,
    required String plaintext,
    required String senderAddress,
    required String senderIdentityId,
    required String senderDeviceId,
    required List<LoomDeviceKeyBundle> recipientDevices,
    String? replyToMessageId,
  }) async {
    if (conversationId.trim().isEmpty || conversationId.length > 256) {
      throw ArgumentError.value(conversationId, 'conversationId');
    }
    final normalizedText = plaintext.trim();
    if (normalizedText.isEmpty) {
      throw ArgumentError('Direct message plaintext cannot be empty');
    }
    final clear = utf8.encode(
      jsonEncode(<String, Object?>{
        'v': 1,
        'kind': 'text',
        'text': normalizedText,
        if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
      }),
    );
    if (clear.length > _maxPlaintextBytes) {
      throw ArgumentError(
        'Direct message plaintext exceeds the supported limit',
      );
    }

    final unique = <String, LoomDeviceKeyBundle>{};
    for (final bundle in recipientDevices) {
      if (bundle.identityId.isEmpty || bundle.deviceId.isEmpty) {
        throw const FormatException('Invalid direct-message recipient device');
      }
      unique['${bundle.identityId}\u0000${bundle.deviceId}'] = bundle;
    }
    if (unique.isEmpty || unique.length > _maxDevices) {
      throw StateError(
        'Direct message requires 1..$_maxDevices recipient devices',
      );
    }
    final devices = unique.values.toList(growable: false)
      ..sort((a, b) {
        final identity = a.identityId.compareTo(b.identityId);
        return identity != 0 ? identity : a.deviceId.compareTo(b.deviceId);
      });
    final binding = _conversationBinding(
      senderIdentityId,
      devices.map((device) => device.identityId),
    );

    final boxes = <_DirectRecipientBox>[];
    for (final device in devices) {
      final aad = _associatedData(
        conversationId: binding,
        senderAddress: senderAddress,
        senderIdentityId: senderIdentityId,
        senderDeviceId: senderDeviceId,
        recipientIdentityId: device.identityId,
        recipientDeviceId: device.deviceId,
      );
      final sealed = await _sealer.seal(
        plaintext: clear,
        recipientAgreementPublicKey: device.agreementPublicKey,
        associatedData: aad,
      );
      boxes.add(
        _DirectRecipientBox(
          identityId: device.identityId,
          deviceId: device.deviceId,
          sealed: sealed,
        ),
      );
    }

    final unsigned = _unsignedMap(
      senderAddress: senderAddress,
      senderIdentityId: senderIdentityId,
      senderDeviceId: senderDeviceId,
      conversationId: binding,
      replyToMessageId: replyToMessageId,
      boxes: boxes,
    );
    final signature = await _signer(utf8.encode(jsonEncode(unsigned)));
    if (signature.length != 64) {
      throw StateError('Device signer returned an invalid Ed25519 signature');
    }
    final envelope = jsonEncode(<String, Object?>{
      ...unsigned,
      'signature': base64Encode(signature),
    });
    if (utf8.encode(envelope).length > _maxEnvelopeBytes) {
      throw StateError(
        'Direct message envelope exceeds the Node message limit',
      );
    }
    return envelope;
  }

  LoomDirectMessageHeader inspect(String envelope) {
    final parsed = _parse(envelope);
    return LoomDirectMessageHeader(
      senderAddress: parsed.senderAddress,
      senderIdentityId: parsed.senderIdentityId,
      senderDeviceId: parsed.senderDeviceId,
      conversationId: parsed.conversationId,
      replyToMessageId: parsed.replyToMessageId,
    );
  }

  Future<String> decryptText({
    required String envelope,
    required String expectedConversationId,
    required String expectedSenderAddress,
    required String localIdentityId,
    required String localDeviceId,
    required LoomDeviceKeyBundle senderDevice,
    String? expectedReplyToMessageId,
  }) async {
    if (expectedConversationId.trim().isEmpty ||
        expectedConversationId.length > 256) {
      throw const FormatException('Invalid local conversation context');
    }
    final parsed = _parse(envelope);
    if (parsed.senderAddress.toLowerCase() !=
            expectedSenderAddress.toLowerCase() ||
        parsed.replyToMessageId != expectedReplyToMessageId) {
      throw const FormatException('Direct message routing metadata mismatch');
    }
    if (parsed.senderIdentityId != senderDevice.identityId ||
        parsed.senderDeviceId != senderDevice.deviceId) {
      throw const FormatException(
        'Direct message sender-device binding mismatch',
      );
    }
    final expectedBinding = _conversationBinding(
      parsed.senderIdentityId,
      parsed.boxes.map((box) => box.identityId),
    );
    if (parsed.conversationId != expectedBinding) {
      throw const FormatException(
        'Direct message participant binding mismatch',
      );
    }

    final signingKey = base64Decode(senderDevice.signingPublicKey);
    final signature = base64Decode(parsed.signature);
    if (signingKey.length != 32 || signature.length != 64) {
      throw const FormatException('Invalid direct-message signature material');
    }
    final unsigned = _unsignedMap(
      senderAddress: parsed.senderAddress,
      senderIdentityId: parsed.senderIdentityId,
      senderDeviceId: parsed.senderDeviceId,
      conversationId: parsed.conversationId,
      replyToMessageId: parsed.replyToMessageId,
      boxes: parsed.boxes,
    );
    final valid = await _ed25519.verify(
      utf8.encode(jsonEncode(unsigned)),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const FormatException('Invalid direct-message sender signature');
    }

    final target = parsed.boxes.where(
      (box) =>
          box.identityId == localIdentityId && box.deviceId == localDeviceId,
    );
    if (target.length != 1) {
      throw const FormatException(
        'Direct message is not encrypted for this local device',
      );
    }
    final box = target.single;
    final clear = await _opener(
      payload: box.sealed,
      associatedData: _associatedData(
        conversationId: parsed.conversationId,
        senderAddress: parsed.senderAddress,
        senderIdentityId: parsed.senderIdentityId,
        senderDeviceId: parsed.senderDeviceId,
        recipientIdentityId: localIdentityId,
        recipientDeviceId: localDeviceId,
      ),
    );
    if (clear.isEmpty || clear.length > _maxPlaintextBytes) {
      throw const FormatException('Invalid direct-message plaintext size');
    }
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map<String, Object?> ||
        decoded['v'] != 1 ||
        decoded['kind'] != 'text' ||
        decoded['text'] is! String) {
      throw const FormatException('Malformed direct-message plaintext');
    }
    final text = decoded['text'] as String;
    final innerReply = decoded['replyToMessageId'];
    if (text.isEmpty ||
        utf8.encode(text).length > _maxPlaintextBytes ||
        (innerReply != null && innerReply is! String) ||
        innerReply != parsed.replyToMessageId) {
      throw const FormatException('Direct-message plaintext binding mismatch');
    }
    return text;
  }

  _ParsedDirectEnvelope _parse(String envelope) {
    if (envelope.isEmpty || utf8.encode(envelope).length > _maxEnvelopeBytes) {
      throw const FormatException('Invalid direct-message envelope size');
    }
    final decoded = jsonDecode(envelope);
    if (decoded is! Map<String, Object?> ||
        decoded['v'] != 1 ||
        decoded['protocol'] != protocolVersion) {
      throw const FormatException('Unsupported direct-message envelope');
    }
    String stringField(String key, {int max = 512}) {
      final value = decoded[key];
      if (value is! String ||
          value.trim().isEmpty ||
          value.length > max ||
          value.contains(RegExp(r'[\r\n]'))) {
        throw FormatException('Invalid direct-message field: $key');
      }
      return value;
    }

    final rawBoxes = decoded['boxes'];
    if (rawBoxes is! List ||
        rawBoxes.isEmpty ||
        rawBoxes.length > _maxDevices) {
      throw const FormatException('Invalid direct-message recipient boxes');
    }
    final boxes = <_DirectRecipientBox>[];
    final seen = <String>{};
    for (final raw in rawBoxes) {
      if (raw is! Map<String, Object?> ||
          raw['sealed'] is! Map<String, Object?>) {
        throw const FormatException('Malformed direct-message recipient box');
      }
      final identityId = raw['identityId'];
      final deviceId = raw['deviceId'];
      if (identityId is! String ||
          identityId.isEmpty ||
          identityId.length > 512 ||
          deviceId is! String ||
          deviceId.isEmpty ||
          deviceId.length > 256) {
        throw const FormatException('Invalid direct-message recipient binding');
      }
      final key = '$identityId\u0000$deviceId';
      if (!seen.add(key)) {
        throw const FormatException('Duplicate direct-message recipient box');
      }
      boxes.add(
        _DirectRecipientBox(
          identityId: identityId,
          deviceId: deviceId,
          sealed: LoomRelaySealedPayload.fromJson(
            raw['sealed']! as Map<String, Object?>,
          ),
        ),
      );
    }
    boxes.sort((a, b) {
      final identity = a.identityId.compareTo(b.identityId);
      return identity != 0 ? identity : a.deviceId.compareTo(b.deviceId);
    });
    final reply = decoded['replyToMessageId'];
    if (reply != null &&
        (reply is! String || reply.isEmpty || reply.length > 256)) {
      throw const FormatException('Invalid direct-message reply binding');
    }
    return _ParsedDirectEnvelope(
      senderAddress: stringField('senderAddress'),
      senderIdentityId: stringField('senderIdentityId'),
      senderDeviceId: stringField('senderDeviceId', max: 256),
      conversationId: stringField('conversationId', max: 512),
      replyToMessageId: reply as String?,
      boxes: boxes,
      signature: stringField('signature', max: 128),
    );
  }

  Map<String, Object?> _unsignedMap({
    required String senderAddress,
    required String senderIdentityId,
    required String senderDeviceId,
    required String conversationId,
    required String? replyToMessageId,
    required List<_DirectRecipientBox> boxes,
  }) =>
      <String, Object?>{
        'v': 1,
        'protocol': protocolVersion,
        'senderAddress': senderAddress,
        'senderIdentityId': senderIdentityId,
        'senderDeviceId': senderDeviceId,
        'conversationId': conversationId,
        if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
        'boxes': boxes.map((box) => box.toJson()).toList(growable: false),
      };

  String _conversationBinding(
    String senderIdentityId,
    Iterable<String> recipientIdentityIds,
  ) {
    final identities = <String>{
      senderIdentityId,
      ...recipientIdentityIds,
    }.toList()
      ..sort();
    if (identities.length != 2 ||
        identities.any(
          (identity) => identity.isEmpty || identity.length > 512,
        )) {
      throw const FormatException(
        'Direct message must bind exactly two long-term identities',
      );
    }
    return 'Loom-Direct-Participants-v1|${identities.join('|')}';
  }

  List<int> _associatedData({
    required String conversationId,
    required String senderAddress,
    required String senderIdentityId,
    required String senderDeviceId,
    required String recipientIdentityId,
    required String recipientDeviceId,
  }) =>
      utf8.encode(
        'Loom-Direct-Box-v1\n$conversationId\n$senderAddress\n$senderIdentityId\n$senderDeviceId\n$recipientIdentityId\n$recipientDeviceId',
      );
}

class _ParsedDirectEnvelope {
  const _ParsedDirectEnvelope({
    required this.senderAddress,
    required this.senderIdentityId,
    required this.senderDeviceId,
    required this.conversationId,
    required this.replyToMessageId,
    required this.boxes,
    required this.signature,
  });

  final String senderAddress;
  final String senderIdentityId;
  final String senderDeviceId;
  final String conversationId;
  final String? replyToMessageId;
  final List<_DirectRecipientBox> boxes;
  final String signature;
}

class _DirectRecipientBox {
  const _DirectRecipientBox({
    required this.identityId,
    required this.deviceId,
    required this.sealed,
  });

  final String identityId;
  final String deviceId;
  final LoomRelaySealedPayload sealed;

  Map<String, Object?> toJson() => <String, Object?>{
        'identityId': identityId,
        'deviceId': deviceId,
        'sealed': sealed.toJson(),
      };
}
