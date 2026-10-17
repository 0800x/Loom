import 'dart:convert';
import 'dart:typed_data';

class LoomPublicAvatar {
  const LoomPublicAvatar({required this.png, required this.color});
  final String? png;
  final int color;

  static LoomPublicAvatar? parseOptional(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! Map) {
      throw const FormatException('Invalid public avatar');
    }
    final color = value['color'];
    final png = value['png'];
    if (color is! int ||
        color < 0 ||
        color > 5 ||
        (png != null && (png is! String || png.length > 450000))) {
      throw const FormatException('Invalid public avatar');
    }
    if (png is String) {
      final bytes = base64Decode(png);
      if (bytes.length < 45 || base64Encode(bytes) != png) {
        throw const FormatException('Invalid avatar PNG');
      }
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      for (var i = 0; i < 8; i++) {
        if (bytes[i] != signature[i]) {
          throw const FormatException('Invalid avatar PNG');
        }
      }
      final header = ByteData.sublistView(bytes);
      final width = header.getUint32(16), height = header.getUint32(20);
      if (width < 1 || width > 256 || height < 1 || height > 256) {
        throw const FormatException('Invalid avatar dimensions');
      }
    }
    return LoomPublicAvatar(png: png as String?, color: color);
  }

  Map<String, Object?> toJson() => {'png': png, 'color': color};
}
