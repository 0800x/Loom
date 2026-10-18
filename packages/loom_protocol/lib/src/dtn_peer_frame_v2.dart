import 'dart:convert';
import 'dart:typed_data';

import 'loom_address.dart';
import 'envelope_v2_codec.dart';
import 'protocol_versions.dart';

sealed class LoomDtnPeerFrameV2 {
  const LoomDtnPeerFrameV2();

  int get version => LoomProtocolVersions.peerProtocolV2;
}

final class LoomDtnPacketTransferFrameV2 extends LoomDtnPeerFrameV2 {
  LoomDtnPacketTransferFrameV2({
    required this.transmissionId,
    required Uint8List outerEnvelopeBytes,
    String? destinationNodeDomain,
  })  : outerEnvelopeBytes = Uint8List.fromList(outerEnvelopeBytes),
        destinationNodeDomain = destinationNodeDomain == null
            ? null
            : LoomAddress.normalizeHomeNode(destinationNodeDomain);

  final String transmissionId;
  final Uint8List outerEnvelopeBytes;

  /// Optional hop-local route sidecar. It is not part of the immutable outer
  /// envelope and is never trusted as Node identity; receivers must still
  /// verify the destination Node before uplink. Older peers can continue to
  /// send frames without it.
  final String? destinationNodeDomain;

  String get packetId =>
      LoomEnvelopeV2Codec.decodeOuter(outerEnvelopeBytes).packetId;

  void validate() {
    _validateOpaqueId(transmissionId, 'transmission id', maxLength: 256);
    if (outerEnvelopeBytes.isEmpty ||
        outerEnvelopeBytes.length > LoomEnvelopeV2Codec.maxWireBytes) {
      throw const FormatException('Invalid DTN packet-transfer envelope size');
    }
    final destination = destinationNodeDomain;
    if (destination != null &&
        LoomAddress.normalizeHomeNode(destination) != destination) {
      throw const FormatException('Invalid DTN destination Node route');
    }
    LoomEnvelopeV2Codec.decodeOuter(outerEnvelopeBytes);
  }
}

final class LoomDtnHopAckFrameV2 extends LoomDtnPeerFrameV2 {
  const LoomDtnHopAckFrameV2({
    required this.transmissionId,
    required this.packetId,
    required this.acceptedAt,
    required this.duplicate,
  });

  final String transmissionId;
  final String packetId;
  final DateTime acceptedAt;
  final bool duplicate;

  bool get recipientDeliveryConfirmed => false;

  void validate() {
    _validateOpaqueId(transmissionId, 'transmission id', maxLength: 256);
    _validateOpaqueId(packetId, 'packet id');
    final utc = acceptedAt.toUtc();
    if (utc.year < 2020 || utc.year >= 2200) {
      throw const FormatException('Invalid DTN hop-ack time');
    }
  }
}

/// Strict protobuf-wire-compatible codec for hop-local DTN peer frames.
///
/// The `.proto` schema pins field numbers for interoperability, but this parser
/// intentionally accepts a narrower profile than generic protobuf: unknown
/// fields, duplicate singular fields, duplicate oneof bodies, malformed UTF-8,
/// non-minimal varints and missing required fields are rejected.
abstract final class LoomDtnPeerFrameV2Codec {
  static const int maxFrameBytes = LoomEnvelopeV2Codec.maxWireBytes + 4096;
  static const int _wireVarint = 0;
  static const int _wireLengthDelimited = 2;
  static final int _minAckUnixMs = DateTime.utc(2020).millisecondsSinceEpoch;
  static final int _maxAckUnixMsExclusive =
      DateTime.utc(2200).millisecondsSinceEpoch;

  static Uint8List encode(LoomDtnPeerFrameV2 frame) {
    final writer = _Writer();
    writer.varintField(1, LoomProtocolVersions.peerProtocolV2);

    switch (frame) {
      case LoomDtnPacketTransferFrameV2 transfer:
        transfer.validate();
        writer.bytesField(2, _encodeTransfer(transfer));
        break;
      case LoomDtnHopAckFrameV2 ack:
        ack.validate();
        writer.bytesField(3, _encodeAck(ack));
        break;
    }

    final bytes = writer.takeBytes();
    if (bytes.isEmpty || bytes.length > maxFrameBytes) {
      throw const FormatException('Encoded DTN peer frame exceeds bounds');
    }
    return bytes;
  }

  static LoomDtnPeerFrameV2 decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxFrameBytes) {
      throw const FormatException('DTN peer frame exceeds bounds');
    }
    final reader = _Reader(bytes);
    int? version;
    LoomDtnPeerFrameV2? body;

    while (!reader.isDone) {
      final tag = reader.readTag();
      switch (tag.fieldNumber) {
        case 1:
          _expectWire(tag, _wireVarint);
          if (version != null) {
            throw const FormatException('Duplicate peer-frame version');
          }
          version = reader.readVarint(maxBytes: 5);
          break;
        case 2:
          _expectWire(tag, _wireLengthDelimited);
          if (body != null) {
            throw const FormatException('Duplicate peer-frame oneof body');
          }
          body = _decodeTransfer(reader.readBytes(maxLength: maxFrameBytes));
          break;
        case 3:
          _expectWire(tag, _wireLengthDelimited);
          if (body != null) {
            throw const FormatException('Duplicate peer-frame oneof body');
          }
          body = _decodeAck(reader.readBytes(maxLength: 4096));
          break;
        default:
          throw FormatException(
            'Unknown DTN peer-frame field ${tag.fieldNumber}',
          );
      }
    }

    if (version != LoomProtocolVersions.peerProtocolV2) {
      throw const FormatException('Unsupported DTN peer-frame version');
    }
    if (body == null) {
      throw const FormatException('Missing DTN peer-frame body');
    }
    return body;
  }

  static Uint8List _encodeTransfer(LoomDtnPacketTransferFrameV2 transfer) {
    final writer = _Writer();
    writer.stringField(1, transfer.transmissionId);
    writer.bytesField(2, transfer.outerEnvelopeBytes);
    final destination = transfer.destinationNodeDomain;
    if (destination != null) writer.stringField(3, destination);
    return writer.takeBytes();
  }

  static LoomDtnPacketTransferFrameV2 _decodeTransfer(Uint8List bytes) {
    final reader = _Reader(bytes);
    String? transmissionId;
    Uint8List? outerEnvelope;
    String? destinationNodeDomain;

    while (!reader.isDone) {
      final tag = reader.readTag();
      switch (tag.fieldNumber) {
        case 1:
          _expectWire(tag, _wireLengthDelimited);
          if (transmissionId != null) {
            throw const FormatException('Duplicate DTN transmission id');
          }
          transmissionId = reader.readString(maxLength: 256);
          break;
        case 2:
          _expectWire(tag, _wireLengthDelimited);
          if (outerEnvelope != null) {
            throw const FormatException('Duplicate DTN outer envelope');
          }
          outerEnvelope = reader.readBytes(
            maxLength: LoomEnvelopeV2Codec.maxWireBytes,
          );
          break;
        case 3:
          _expectWire(tag, _wireLengthDelimited);
          if (destinationNodeDomain != null) {
            throw const FormatException('Duplicate DTN destination Node route');
          }
          destinationNodeDomain = reader.readString(maxLength: 320);
          break;
        default:
          throw FormatException(
            'Unknown DTN packet-transfer field ${tag.fieldNumber}',
          );
      }
    }

    if (transmissionId == null || outerEnvelope == null) {
      throw const FormatException('Incomplete DTN packet-transfer frame');
    }
    final frame = LoomDtnPacketTransferFrameV2(
      transmissionId: transmissionId,
      outerEnvelopeBytes: outerEnvelope,
      destinationNodeDomain: destinationNodeDomain,
    );
    frame.validate();
    return frame;
  }

  static Uint8List _encodeAck(LoomDtnHopAckFrameV2 ack) {
    final writer = _Writer();
    writer.stringField(1, ack.transmissionId);
    writer.stringField(2, ack.packetId);
    writer.varintField(3, ack.acceptedAt.toUtc().millisecondsSinceEpoch);
    writer.varintField(4, ack.duplicate ? 1 : 0);
    return writer.takeBytes();
  }

  static LoomDtnHopAckFrameV2 _decodeAck(Uint8List bytes) {
    final reader = _Reader(bytes);
    String? transmissionId;
    String? packetId;
    int? acceptedAtMs;
    int? duplicateValue;

    while (!reader.isDone) {
      final tag = reader.readTag();
      switch (tag.fieldNumber) {
        case 1:
          _expectWire(tag, _wireLengthDelimited);
          if (transmissionId != null) {
            throw const FormatException('Duplicate DTN ack transmission id');
          }
          transmissionId = reader.readString(maxLength: 256);
          break;
        case 2:
          _expectWire(tag, _wireLengthDelimited);
          if (packetId != null) {
            throw const FormatException('Duplicate DTN ack PacketId');
          }
          packetId = reader.readString(maxLength: 128);
          break;
        case 3:
          _expectWire(tag, _wireVarint);
          if (acceptedAtMs != null) {
            throw const FormatException('Duplicate DTN ack time');
          }
          acceptedAtMs = reader.readVarint(maxBytes: 8);
          break;
        case 4:
          _expectWire(tag, _wireVarint);
          if (duplicateValue != null) {
            throw const FormatException('Duplicate DTN ack duplicate flag');
          }
          duplicateValue = reader.readVarint(maxBytes: 1);
          if (duplicateValue != 0 && duplicateValue != 1) {
            throw const FormatException('Invalid DTN ack duplicate flag');
          }
          break;
        default:
          throw FormatException('Unknown DTN hop-ack field ${tag.fieldNumber}');
      }
    }

    if (transmissionId == null ||
        packetId == null ||
        acceptedAtMs == null ||
        duplicateValue == null) {
      throw const FormatException('Incomplete DTN hop-ack frame');
    }
    if (acceptedAtMs < _minAckUnixMs ||
        acceptedAtMs >= _maxAckUnixMsExclusive) {
      throw const FormatException('DTN hop-ack timestamp is outside policy');
    }

    final acceptedAt = DateTime.fromMillisecondsSinceEpoch(
      acceptedAtMs,
      isUtc: true,
    );
    final frame = LoomDtnHopAckFrameV2(
      transmissionId: transmissionId,
      packetId: packetId,
      acceptedAt: acceptedAt,
      duplicate: duplicateValue == 1,
    );
    frame.validate();
    return frame;
  }

  static void _expectWire(_Tag tag, int expected) {
    if (tag.wireType != expected) {
      throw FormatException(
        'Invalid wire type ${tag.wireType} for field ${tag.fieldNumber}',
      );
    }
  }
}

void _validateOpaqueId(
  String value,
  String label, {
  int minLength = 8,
  int maxLength = 128,
}) {
  if (value.trim() != value ||
      value.length < minLength ||
      value.length > maxLength ||
      value.contains('\r') ||
      value.contains('\n')) {
    throw FormatException('Invalid $label');
  }
}

final class _Tag {
  const _Tag(this.fieldNumber, this.wireType);

  final int fieldNumber;
  final int wireType;
}

final class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void varintField(int fieldNumber, int value) {
    if (value < 0) throw const FormatException('Negative protobuf varint');
    _writeVarint((fieldNumber << 3) | LoomDtnPeerFrameV2Codec._wireVarint);
    _writeVarint(value);
  }

  void stringField(int fieldNumber, String value) {
    bytesField(fieldNumber, Uint8List.fromList(utf8.encode(value)));
  }

  void bytesField(int fieldNumber, List<int> bytes) {
    _writeVarint(
      (fieldNumber << 3) | LoomDtnPeerFrameV2Codec._wireLengthDelimited,
    );
    _writeVarint(bytes.length);
    _builder.add(bytes);
  }

  void _writeVarint(int value) {
    var remaining = value;
    while (remaining >= 0x80) {
      _builder.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _builder.addByte(remaining);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

final class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int _offset = 0;

  bool get isDone => _offset == bytes.length;

  _Tag readTag() {
    final raw = readVarint(maxBytes: 5);
    final fieldNumber = raw >> 3;
    final wireType = raw & 0x07;
    if (fieldNumber < 1) {
      throw const FormatException('Invalid protobuf field number');
    }
    if (wireType != LoomDtnPeerFrameV2Codec._wireVarint &&
        wireType != LoomDtnPeerFrameV2Codec._wireLengthDelimited) {
      throw const FormatException('Unsupported protobuf wire type');
    }
    return _Tag(fieldNumber, wireType);
  }

  int readVarint({required int maxBytes}) {
    if (maxBytes < 1 || maxBytes > 10) {
      throw ArgumentError.value(maxBytes, 'maxBytes');
    }
    var result = 0;
    var shift = 0;
    var count = 0;
    while (true) {
      if (_offset >= bytes.length) {
        throw const FormatException('Truncated protobuf varint');
      }
      final byte = bytes[_offset++];
      count += 1;
      if (count > maxBytes) {
        throw const FormatException('Protobuf varint exceeds bound');
      }
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        if (count > 1 && (byte & 0x7f) == 0) {
          throw const FormatException('Non-minimal protobuf varint');
        }
        return result;
      }
      shift += 7;
    }
  }

  Uint8List readBytes({required int maxLength}) {
    final length = readVarint(maxBytes: 5);
    if (length < 0 || length > maxLength) {
      throw const FormatException(
        'Length-delimited protobuf field exceeds bound',
      );
    }
    final end = _offset + length;
    if (end < _offset || end > bytes.length) {
      throw const FormatException('Truncated length-delimited protobuf field');
    }
    final value = Uint8List.fromList(bytes.sublist(_offset, end));
    _offset = end;
    return value;
  }

  String readString({required int maxLength}) {
    final raw = readBytes(maxLength: maxLength * 4);
    final value = utf8.decode(raw, allowMalformed: false);
    if (value.length > maxLength) {
      throw const FormatException('UTF-8 string exceeds bound');
    }
    return value;
  }
}
