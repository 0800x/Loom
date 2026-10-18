import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

final class LoomAccountId {
  const LoomAccountId._(this.value);

  static final RegExp _pattern = RegExp(r'^acc2_[A-Za-z0-9_-]{43}$');
  final String value;

  factory LoomAccountId.parse(String value) {
    if (!_pattern.hasMatch(value)) {
      throw const FormatException('Invalid Architecture-v2 AccountId');
    }
    return LoomAccountId._(value);
  }

  factory LoomAccountId.generate() =>
      LoomAccountId._('acc2_${_randomToken(32)}');

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is LoomAccountId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class LoomDeviceId {
  const LoomDeviceId._(this.value);

  static final RegExp _pattern = RegExp(r'^dev2_[A-Za-z0-9_-]{22}$');
  final String value;

  factory LoomDeviceId.parse(String value) {
    if (!_pattern.hasMatch(value)) {
      throw const FormatException('Invalid Architecture-v2 DeviceId');
    }
    return LoomDeviceId._(value);
  }

  factory LoomDeviceId.generate() => LoomDeviceId._('dev2_${_randomToken(16)}');

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is LoomDeviceId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

String _randomToken(int byteCount) {
  final random = Random.secure();
  final bytes = Uint8List(byteCount);
  for (var i = 0; i < bytes.length; i += 1) {
    bytes[i] = random.nextInt(256);
  }
  return base64UrlEncode(bytes).replaceAll('=', '');
}
