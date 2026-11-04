import 'dart:convert';
import 'dart:typed_data';

import 'envelope_v2.dart';
import 'protocol_versions.dart';

/// Strict Protocol Buffers wire codec for Loom Architecture v2 envelopes.
///
/// The field numbers are pinned in `proto/loom_envelope_v2.proto`. This codec
/// intentionally implements a strict application profile on top of the
/// protobuf wire format:
///
/// - singular fields may not be duplicated;
/// - unknown fields fail closed for the current v2 profile;
/// - lengths, nesting and varints are bounded;
/// - enum zero/unknown values fail closed;
/// - model validation runs after decoding.
///
/// This encoding is NOT canonical and MUST NOT be used as a signing format.
abstract final class LoomEnvelopeV2Codec {
  static const int maxWireBytes = 1024 * 1024 + 4096;
  static const int _maxStringBytes = 1024;
  static const int _maxNestedBytes = 1024 * 1024 + 2048;

  static Uint8List encodeInner(LoomInnerEnvelopeV2 envelope) {
    envelope.validate();
    final writer = _ProtoWriter();
    writer.writeVarintField(1, envelope.version);
    writer.writeStringField(2, envelope.messageId);
    writer.writeStringField(3, envelope.conversationRef);
    writer.writeStringField(4, envelope.senderAccountId);
    writer.writeStringField(5, envelope.senderDeviceId);
    writer.writeStringField(6, envelope.recipientAccountId);
    writer.writeStringField(7, envelope.recipientDeviceId);
    writer.writeVarintField(8, _encodeContentKind(envelope.contentKind));
    writer.writeBytesField(9, envelope.contentPayload);
    writer.writeVarintField(
      10,
      envelope.createdAt.toUtc().millisecondsSinceEpoch,
    );
    final replyTo = envelope.replyToMessageId;
    if (replyTo != null) writer.writeStringField(11, replyTo);
    writer.writeVarintField(12, _encodeReceiptPolicy(envelope.receiptPolicy));
    return writer.takeBytes(maxBytes: maxWireBytes);
  }

  static LoomInnerEnvelopeV2 decodeInner(Uint8List bytes) {
    final reader = _ProtoReader(bytes, maxBytes: maxWireBytes);
    int? version;
    String? messageId;
    String? conversationRef;
    String? senderAccountId;
    String? senderDeviceId;
    String? recipientAccountId;
    String? recipientDeviceId;
    LoomInnerContentKindV2? contentKind;
    Uint8List? contentPayload;
    int? createdAtMs;
    String? replyToMessageId;
    LoomReceiptPolicyV2? receiptPolicy;
    final seen = <int>{};

    while (!reader.isDone) {
      final tag = reader.readTag();
      _rejectDuplicate(seen, tag.fieldNumber);
      switch (tag.fieldNumber) {
        case 1:
          tag.requireWireType(_WireType.varint);
          version = reader.readVarint();
          break;
        case 2:
          tag.requireWireType(_WireType.lengthDelimited);
          messageId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 3:
          tag.requireWireType(_WireType.lengthDelimited);
          conversationRef = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 4:
          tag.requireWireType(_WireType.lengthDelimited);
          senderAccountId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 5:
          tag.requireWireType(_WireType.lengthDelimited);
          senderDeviceId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 6:
          tag.requireWireType(_WireType.lengthDelimited);
          recipientAccountId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 7:
          tag.requireWireType(_WireType.lengthDelimited);
          recipientDeviceId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 8:
          tag.requireWireType(_WireType.varint);
          contentKind = _decodeContentKind(reader.readVarint());
          break;
        case 9:
          tag.requireWireType(_WireType.lengthDelimited);
          contentPayload = reader.readBytes(maxBytes: 1024 * 1024);
          break;
        case 10:
          tag.requireWireType(_WireType.varint);
          createdAtMs = reader.readVarint();
          break;
        case 11:
          tag.requireWireType(_WireType.lengthDelimited);
          replyToMessageId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 12:
          tag.requireWireType(_WireType.varint);
          receiptPolicy = _decodeReceiptPolicy(reader.readVarint());
          break;
        default:
          throw FormatException(
            'Unknown InnerEnvelopeV2 field ${tag.fieldNumber}',
          );
      }
    }

    _requireVersion(version, LoomProtocolVersions.innerEnvelopeV2, 'inner');
    final envelope = LoomInnerEnvelopeV2(
      messageId: _requireField(messageId, 'message_id'),
      conversationRef: _requireField(conversationRef, 'conversation_ref'),
      senderAccountId: _requireField(senderAccountId, 'sender_account_id'),
      senderDeviceId: _requireField(senderDeviceId, 'sender_device_id'),
      recipientAccountId: _requireField(
        recipientAccountId,
        'recipient_account_id',
      ),
      recipientDeviceId: _requireField(
        recipientDeviceId,
        'recipient_device_id',
      ),
      contentKind: _requireField(contentKind, 'content_kind'),
      contentPayload: _requireField(contentPayload, 'content_payload'),
      createdAt: _dateFromUnixMs(
        _requireField(createdAtMs, 'created_at_unix_ms'),
        'created_at_unix_ms',
      ),
      replyToMessageId: replyToMessageId,
      receiptPolicy: _requireField(receiptPolicy, 'receipt_policy'),
    );
    envelope.validate();
    return envelope;
  }

  static Uint8List encodeSessionCiphertext(
    LoomSessionCiphertextWireV2 ciphertext,
  ) {
    ciphertext.validate();
    final writer = _ProtoWriter();
    writer.writeVarintField(1, ciphertext.version);
    writer.writeStringField(2, ciphertext.protocolVersion);
    writer.writeStringField(3, ciphertext.sessionLocator);
    writer.writeBytesField(4, ciphertext.ciphertext);
    return writer.takeBytes(maxBytes: maxWireBytes);
  }

  static LoomSessionCiphertextWireV2 decodeSessionCiphertext(Uint8List bytes) {
    final reader = _ProtoReader(bytes, maxBytes: maxWireBytes);
    int? version;
    String? protocolVersion;
    String? sessionLocator;
    Uint8List? ciphertext;
    final seen = <int>{};

    while (!reader.isDone) {
      final tag = reader.readTag();
      _rejectDuplicate(seen, tag.fieldNumber);
      switch (tag.fieldNumber) {
        case 1:
          tag.requireWireType(_WireType.varint);
          version = reader.readVarint();
          break;
        case 2:
          tag.requireWireType(_WireType.lengthDelimited);
          protocolVersion = reader.readString(maxBytes: 128);
          break;
        case 3:
          tag.requireWireType(_WireType.lengthDelimited);
          sessionLocator = reader.readString(maxBytes: 256);
          break;
        case 4:
          tag.requireWireType(_WireType.lengthDelimited);
          ciphertext = reader.readBytes(maxBytes: 1024 * 1024);
          break;
        default:
          throw FormatException(
            'Unknown SessionCiphertextV2 field ${tag.fieldNumber}',
          );
      }
    }

    _requireVersion(
      version,
      LoomProtocolVersions.sessionCiphertextEnvelopeV2,
      'session ciphertext',
    );
    final value = LoomSessionCiphertextWireV2(
      protocolVersion: _requireField(protocolVersion, 'protocol_version'),
      sessionLocator: _requireField(sessionLocator, 'session_locator'),
      ciphertext: _requireField(ciphertext, 'ciphertext'),
    );
    value.validate();
    return value;
  }

  static Uint8List encodeOuter(LoomOuterEnvelopeV2 envelope) {
    envelope.validate();
    final writer = _ProtoWriter();
    writer.writeVarintField(1, envelope.version);
    writer.writeStringField(2, envelope.packetId);
    writer.writeMessageField(3, _encodeRoutingHint(envelope.routingHint));
    writer.writeVarintField(
      4,
      envelope.expiresAtBucket.toUtc().millisecondsSinceEpoch,
    );
    writer.writeVarintField(5, _encodePriority(envelope.priority));
    writer.writeVarintField(6, envelope.initialHopLimit);
    writer.writeMessageField(
      7,
      _encodeForwardingState(envelope.forwardingState),
    );
    writer.writeBytesField(8, envelope.encryptedPayload);
    return writer.takeBytes(maxBytes: maxWireBytes);
  }

  static LoomOuterEnvelopeV2 decodeOuter(Uint8List bytes) {
    final reader = _ProtoReader(bytes, maxBytes: maxWireBytes);
    int? version;
    String? packetId;
    LoomRoutingHintV2? routingHint;
    int? expiresAtMs;
    LoomPriorityClassV2? priority;
    int? initialHopLimit;
    LoomForwardingStateV2? forwardingState;
    Uint8List? encryptedPayload;
    final seen = <int>{};

    while (!reader.isDone) {
      final tag = reader.readTag();
      _rejectDuplicate(seen, tag.fieldNumber);
      switch (tag.fieldNumber) {
        case 1:
          tag.requireWireType(_WireType.varint);
          version = reader.readVarint();
          break;
        case 2:
          tag.requireWireType(_WireType.lengthDelimited);
          packetId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 3:
          tag.requireWireType(_WireType.lengthDelimited);
          routingHint = _decodeRoutingHint(
            reader.readBytes(maxBytes: _maxNestedBytes),
          );
          break;
        case 4:
          tag.requireWireType(_WireType.varint);
          expiresAtMs = reader.readVarint();
          break;
        case 5:
          tag.requireWireType(_WireType.varint);
          priority = _decodePriority(reader.readVarint());
          break;
        case 6:
          tag.requireWireType(_WireType.varint);
          initialHopLimit = reader.readVarint();
          break;
        case 7:
          tag.requireWireType(_WireType.lengthDelimited);
          forwardingState = _decodeForwardingState(
            reader.readBytes(maxBytes: _maxNestedBytes),
          );
          break;
        case 8:
          tag.requireWireType(_WireType.lengthDelimited);
          encryptedPayload = reader.readBytes(maxBytes: 1024 * 1024);
          break;
        default:
          throw FormatException(
            'Unknown OuterEnvelopeV2 field ${tag.fieldNumber}',
          );
      }
    }

    _requireVersion(version, LoomProtocolVersions.outerEnvelopeV2, 'outer');
    final envelope = LoomOuterEnvelopeV2(
      packetId: _requireField(packetId, 'packet_id'),
      routingHint: _requireField(routingHint, 'routing_hint'),
      expiresAtBucket: _dateFromUnixMs(
        _requireField(expiresAtMs, 'expires_at_bucket_unix_ms'),
        'expires_at_bucket_unix_ms',
      ),
      priority: _requireField(priority, 'priority'),
      initialHopLimit: _requireField(initialHopLimit, 'initial_hop_limit'),
      forwardingState: _requireField(forwardingState, 'forwarding_state'),
      encryptedPayload: _requireField(encryptedPayload, 'encrypted_payload'),
    );
    envelope.validate();
    return envelope;
  }

  static Uint8List encodeDeliveryReceipt(LoomDeliveryReceiptV2 receipt) {
    receipt.validate();
    final writer = _ProtoWriter();
    writer.writeVarintField(1, receipt.version);
    writer.writeStringField(2, receipt.forMessageId);
    writer.writeStringField(3, receipt.recipientDeviceId);
    writer.writeVarintField(4, _encodeDeliveryStatus(receipt.status));
    final receivedAt = receipt.receivedAt;
    if (receivedAt != null) {
      writer.writeVarintField(5, receivedAt.toUtc().millisecondsSinceEpoch);
    }
    return writer.takeBytes(maxBytes: 4096);
  }

  static LoomDeliveryReceiptV2 decodeDeliveryReceipt(Uint8List bytes) {
    final reader = _ProtoReader(bytes, maxBytes: 4096);
    int? version;
    String? forMessageId;
    String? recipientDeviceId;
    LoomDeliveryReceiptStatusV2? status;
    int? receivedAtMs;
    final seen = <int>{};

    while (!reader.isDone) {
      final tag = reader.readTag();
      _rejectDuplicate(seen, tag.fieldNumber);
      switch (tag.fieldNumber) {
        case 1:
          tag.requireWireType(_WireType.varint);
          version = reader.readVarint();
          break;
        case 2:
          tag.requireWireType(_WireType.lengthDelimited);
          forMessageId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 3:
          tag.requireWireType(_WireType.lengthDelimited);
          recipientDeviceId = reader.readString(maxBytes: _maxStringBytes);
          break;
        case 4:
          tag.requireWireType(_WireType.varint);
          status = _decodeDeliveryStatus(reader.readVarint());
          break;
        case 5:
          tag.requireWireType(_WireType.varint);
          receivedAtMs = reader.readVarint();
          break;
        default:
          throw FormatException(
            'Unknown DeliveryReceiptV2 field ${tag.fieldNumber}',
          );
      }
    }

    _requireVersion(
      version,
      LoomProtocolVersions.deliveryReceiptV2,
      'delivery receipt',
    );
    final receipt = LoomDeliveryReceiptV2(
      forMessageId: _requireField(forMessageId, 'for_message_id'),
      recipientDeviceId: _requireField(
        recipientDeviceId,
        'recipient_device_id',
      ),
      status: _requireField(status, 'status'),
      receivedAt: receivedAtMs == null
          ? null
          : _dateFromUnixMs(receivedAtMs, 'received_at_unix_ms'),
    );
    receipt.validate();
    return receipt;
  }

  static Uint8List _encodeRoutingHint(LoomRoutingHintV2 hint) {
    hint.validate();
    final writer = _ProtoWriter();
    writer.writeVarintField(1, _encodeRoutingScope(hint.scope));
    writer.writeBytesField(2, hint.mailboxToken);
    return writer.takeBytes(maxBytes: 256);
  }

  static LoomRoutingHintV2 _decodeRoutingHint(Uint8List bytes) {
    final reader = _ProtoReader(bytes, maxBytes: 256);
    LoomRoutingScopeV2? scope;
    Uint8List? mailboxToken;
    final seen = <int>{};
    while (!reader.isDone) {
      final tag = reader.readTag();
      _rejectDuplicate(seen, tag.fieldNumber);
      switch (tag.fieldNumber) {
        case 1:
          tag.requireWireType(_WireType.varint);
          scope = _decodeRoutingScope(reader.readVarint());
          break;
        case 2:
          tag.requireWireType(_WireType.lengthDelimited);
          mailboxToken = reader.readBytes(maxBytes: 128);
          break;
        default:
          throw FormatException(
            'Unknown RoutingHintV2 field ${tag.fieldNumber}',
          );
      }
    }
    final hint = LoomRoutingHintV2(
      scope: _requireField(scope, 'routing scope'),
      mailboxToken: _requireField(mailboxToken, 'mailbox token'),
    );
    hint.validate();
    return hint;
  }

  static Uint8List _encodeForwardingState(LoomForwardingStateV2 state) {
    final writer = _ProtoWriter();
    writer.writeVarintField(1, state.hopsUsed);
    writer.writeVarintField(2, state.copiesRemaining);
    return writer.takeBytes(maxBytes: 32);
  }

  static LoomForwardingStateV2 _decodeForwardingState(Uint8List bytes) {
    final reader = _ProtoReader(bytes, maxBytes: 32);
    int? hopsUsed;
    int? copiesRemaining;
    final seen = <int>{};
    while (!reader.isDone) {
      final tag = reader.readTag();
      _rejectDuplicate(seen, tag.fieldNumber);
      switch (tag.fieldNumber) {
        case 1:
          tag.requireWireType(_WireType.varint);
          hopsUsed = reader.readVarint();
          break;
        case 2:
          tag.requireWireType(_WireType.varint);
          copiesRemaining = reader.readVarint();
          break;
        default:
          throw FormatException(
            'Unknown ForwardingStateV2 field ${tag.fieldNumber}',
          );
      }
    }
    return LoomForwardingStateV2(
      hopsUsed: _requireField(hopsUsed, 'hops_used'),
      copiesRemaining: _requireField(copiesRemaining, 'copies_remaining'),
    );
  }

  static int _encodeContentKind(LoomInnerContentKindV2 value) =>
      switch (value) {
        LoomInnerContentKindV2.text => 1,
        LoomInnerContentKindV2.deliveryReceipt => 2,
        LoomInnerContentKindV2.sessionControl => 3,
        LoomInnerContentKindV2.attachmentReference => 4,
      };

  static LoomInnerContentKindV2 _decodeContentKind(int value) =>
      switch (value) {
        1 => LoomInnerContentKindV2.text,
        2 => LoomInnerContentKindV2.deliveryReceipt,
        3 => LoomInnerContentKindV2.sessionControl,
        4 => LoomInnerContentKindV2.attachmentReference,
        _ => throw FormatException('Unknown inner content kind $value'),
      };

  static int _encodeReceiptPolicy(LoomReceiptPolicyV2 value) => switch (value) {
    LoomReceiptPolicyV2.none => 1,
    LoomReceiptPolicyV2.delivered => 2,
    LoomReceiptPolicyV2.deliveredAndRead => 3,
  };

  static LoomReceiptPolicyV2 _decodeReceiptPolicy(int value) => switch (value) {
    1 => LoomReceiptPolicyV2.none,
    2 => LoomReceiptPolicyV2.delivered,
    3 => LoomReceiptPolicyV2.deliveredAndRead,
    _ => throw FormatException('Unknown receipt policy $value'),
  };

  static int _encodeRoutingScope(LoomRoutingScopeV2 value) => switch (value) {
    LoomRoutingScopeV2.localDevice => 1,
    LoomRoutingScopeV2.domesticRelay => 2,
    LoomRoutingScopeV2.globalRelay => 3,
  };

  static LoomRoutingScopeV2 _decodeRoutingScope(int value) => switch (value) {
    1 => LoomRoutingScopeV2.localDevice,
    2 => LoomRoutingScopeV2.domesticRelay,
    3 => LoomRoutingScopeV2.globalRelay,
    _ => throw FormatException('Unknown routing scope $value'),
  };

  static int _encodePriority(LoomPriorityClassV2 value) => switch (value) {
    LoomPriorityClassV2.normal => 1,
    LoomPriorityClassV2.urgent => 2,
  };

  static LoomPriorityClassV2 _decodePriority(int value) => switch (value) {
    1 => LoomPriorityClassV2.normal,
    2 => LoomPriorityClassV2.urgent,
    _ => throw FormatException('Unknown priority class $value'),
  };

  static int _encodeDeliveryStatus(LoomDeliveryReceiptStatusV2 value) =>
      switch (value) {
        LoomDeliveryReceiptStatusV2.delivered => 1,
      };

  static LoomDeliveryReceiptStatusV2 _decodeDeliveryStatus(int value) =>
      switch (value) {
        1 => LoomDeliveryReceiptStatusV2.delivered,
        _ => throw FormatException('Unknown delivery receipt status $value'),
      };

  static void _rejectDuplicate(Set<int> seen, int fieldNumber) {
    if (!seen.add(fieldNumber)) {
      throw FormatException('Duplicate protobuf field $fieldNumber');
    }
  }

  static void _requireVersion(int? actual, int expected, String label) {
    if (actual == null) throw FormatException('Missing $label version');
    if (actual != expected) {
      throw FormatException(
        'Unsupported $label version $actual; expected $expected',
      );
    }
  }

  static T _requireField<T>(T? value, String fieldName) {
    if (value == null)
      throw FormatException('Missing required field $fieldName');
    return value;
  }

  static DateTime _dateFromUnixMs(int value, String fieldName) {
    if (value < 0 || value > 7258118400000) {
      throw FormatException('Invalid $fieldName');
    }
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
}

enum _WireType {
  varint(0),
  fixed64(1),
  lengthDelimited(2),
  startGroup(3),
  endGroup(4),
  fixed32(5);

  const _WireType(this.code);
  final int code;

  static _WireType fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    throw FormatException('Invalid protobuf wire type $code');
  }
}

final class _ProtoTag {
  const _ProtoTag(this.fieldNumber, this.wireType);

  final int fieldNumber;
  final _WireType wireType;

  void requireWireType(_WireType expected) {
    if (wireType != expected) {
      throw FormatException(
        'Field $fieldNumber has wire type ${wireType.code}; '
        'expected ${expected.code}',
      );
    }
  }
}

final class _ProtoWriter {
  final List<int> _bytes = <int>[];

  void writeVarintField(int fieldNumber, int value) {
    _writeKey(fieldNumber, _WireType.varint);
    _writeVarint(value);
  }

  void writeStringField(int fieldNumber, String value) {
    writeBytesField(fieldNumber, Uint8List.fromList(utf8.encode(value)));
  }

  void writeBytesField(int fieldNumber, List<int> value) {
    _writeKey(fieldNumber, _WireType.lengthDelimited);
    _writeVarint(value.length);
    _bytes.addAll(value);
  }

  void writeMessageField(int fieldNumber, Uint8List value) {
    writeBytesField(fieldNumber, value);
  }

  Uint8List takeBytes({required int maxBytes}) {
    if (_bytes.length > maxBytes) {
      throw const FormatException('Encoded protobuf message exceeds limit');
    }
    return Uint8List.fromList(_bytes);
  }

  void _writeKey(int fieldNumber, _WireType wireType) {
    if (fieldNumber < 1 || fieldNumber > 536870911) {
      throw ArgumentError.value(fieldNumber, 'fieldNumber');
    }
    _writeVarint((fieldNumber << 3) | wireType.code);
  }

  void _writeVarint(int value) {
    if (value < 0 || value > 0x7fffffffffffffff) {
      throw ArgumentError.value(value, 'value', 'must fit positive int64');
    }
    var remaining = value;
    while (remaining >= 0x80) {
      _bytes.add((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.add(remaining);
  }
}

final class _ProtoReader {
  _ProtoReader(Uint8List bytes, {required int maxBytes}) : _bytes = bytes {
    if (bytes.length > maxBytes) {
      throw const FormatException('Protobuf message exceeds limit');
    }
  }

  final Uint8List _bytes;
  int _offset = 0;

  bool get isDone => _offset == _bytes.length;

  _ProtoTag readTag() {
    final key = readVarint();
    final fieldNumber = key >> 3;
    if (fieldNumber < 1 || fieldNumber > 536870911) {
      throw FormatException('Invalid protobuf field number $fieldNumber');
    }
    return _ProtoTag(fieldNumber, _WireType.fromCode(key & 0x07));
  }

  int readVarint() {
    var result = 0;
    var shift = 0;
    for (var index = 0; index < 9; index++) {
      if (_offset >= _bytes.length) {
        throw const FormatException('Truncated protobuf varint');
      }
      final byte = _bytes[_offset++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        if (index > 0 && byte == 0) {
          throw const FormatException('Non-minimal protobuf varint');
        }
        return result;
      }
      shift += 7;
    }
    throw const FormatException('Protobuf varint exceeds positive int64');
  }

  Uint8List readBytes({required int maxBytes}) {
    final length = readVarint();
    if (length < 0 || length > maxBytes) {
      throw const FormatException(
        'Length-delimited protobuf field exceeds limit',
      );
    }
    final end = _offset + length;
    if (end < _offset || end > _bytes.length) {
      throw const FormatException('Truncated length-delimited protobuf field');
    }
    final result = Uint8List.fromList(_bytes.sublist(_offset, end));
    _offset = end;
    return result;
  }

  String readString({required int maxBytes}) {
    final bytes = readBytes(maxBytes: maxBytes);
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const FormatException('Invalid UTF-8 protobuf string');
    }
  }
}
