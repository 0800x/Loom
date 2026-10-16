import 'dart:convert';
import 'dart:typed_data';

/// Carried only inside MLS application plaintext and sealed local history.
/// A bounded, static PNG prevents oversized/animated profile decodes.
class LoomGroupProfile {
  const LoomGroupProfile({this.png});
  static const maxBytes = 20 * 1024;
  static const maxDimension = 128;
  final String? png;
  Map<String, Object?> toJson() => {'v': 1, 'png': png};

  factory LoomGroupProfile.fromJson(Map<String, Object?> json) {
    if (json['v'] != 1 ||
        !json.containsKey('png') ||
        (json['png'] != null && json['png'] is! String)) {
      throw const FormatException('Invalid group profile');
    }
    final encoded = json['png'] as String?;
    if (encoded != null) {
      if (encoded.length > ((maxBytes + 2) ~/ 3) * 4) {
        throw const FormatException('Group photo too large');
      }
      final bytes = base64Decode(encoded);
      try {
        validatePng(bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    }
    return LoomGroupProfile(png: encoded);
  }

  static void validatePng(Uint8List bytes) {
    if (bytes.length < 45 ||
        bytes.length > maxBytes ||
        base64Encode(bytes.sublist(0, 8)) != 'iVBORw0KGgo=') {
      throw const FormatException('Invalid group photo');
    }
    final data = ByteData.sublistView(bytes);
    var offset = 8, header = false, ended = false, image = false;
    while (offset + 12 <= bytes.length) {
      final length = data.getUint32(offset);
      if (length > bytes.length - offset - 12)
        throw const FormatException('Invalid PNG chunk');
      final kind = ascii.decode(bytes.sublist(offset + 4, offset + 8));
      if (!header && kind != 'IHDR')
        throw const FormatException('Missing PNG header');
      if (kind == 'IHDR') {
        if (header || length != 13)
          throw const FormatException('Invalid PNG header');
        final width = data.getUint32(offset + 8),
            height = data.getUint32(offset + 12);
        if (width < 1 ||
            height < 1 ||
            width > maxDimension ||
            height > maxDimension ||
            bytes[offset + 16] > 8)
          throw const FormatException('Invalid PNG dimensions');
        header = true;
      } else if (kind == 'IDAT') {
        image = true;
      } else if (kind == 'IEND') {
        if (length != 0 || !image || offset + 12 != bytes.length)
          throw const FormatException('Invalid PNG ending');
        ended = true;
      } else if (!['PLTE', 'tRNS'].contains(kind)) {
        throw const FormatException('Unsupported PNG chunk');
      }
      offset += length + 12;
    }
    if (!ended || offset != bytes.length)
      throw const FormatException('Incomplete group photo');
  }
}
