import 'dart:convert';
import 'dart:typed_data';

import 'package:qr_flutter/qr_flutter.dart';

/// Portable Identity v1 recovery, deliberately local-only. No passwords,
/// session tokens, device agreement secrets, or message history are exported.
class LoomRecoveryBackup {
  LoomRecoveryBackup({required List<String> words})
    : words = List.unmodifiable(words) {
    if (words.length != 24 ||
        words.any((word) => !RegExp(r'^[a-z]{1,16}$').hasMatch(word))) {
      throw const FormatException('Invalid recovery words');
    }
  }

  final List<String> words;
  String get sentence => words.join(' ');
  String get encoded => jsonEncode({
    'format': 'loom-recovery',
    'version': 1,
    'identityVersion': 1,
    'words': words,
  });
  Uint8List get fileBytes => Uint8List.fromList(utf8.encode(encoded));

  /// Structural parsing only. IdentityCore remains responsible for mnemonic
  /// checksum/word-list validation before any identity is committed.
  factory LoomRecoveryBackup.parse(String raw) {
    if (raw.length > 4096) {
      throw const FormatException('Recovery file is too large');
    }
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value['format'] != 'loom-recovery' ||
        value['version'] != 1 ||
        value['identityVersion'] != 1 ||
        value['words'] is! List ||
        (value['words'] as List).any((word) => word is! String)) {
      throw const FormatException('Unsupported recovery file');
    }
    return LoomRecoveryBackup(words: (value['words'] as List).cast<String>());
  }

  /// One self-contained A4 page. Vector QR with a four-module quiet zone and
  /// numbered words stays legible when printed; no network or temporary file.
  /// ASCII wording is intentional: PDF base fonts do not support Persian.
  Uint8List printablePdf() {
    final image = QrImage(
      QrCode.fromData(data: encoded, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final stream = StringBuffer();
    void text(String value, double x, double y, int size) {
      final escaped = value
          .replaceAll(r'\', r'\\')
          .replaceAll('(', r'\(')
          .replaceAll(')', r'\)');
      stream.writeln('BT /F1 $size Tf $x $y Td ($escaped) Tj ET');
    }

    text('Loom | Recovery kit', 48, 790, 24);
    text('PRIVATE - NOT ENCRYPTED', 48, 758, 12);
    text(
      'Anyone with these words or this QR can recover your identity.',
      48,
      734,
      11,
    );
    text(
      'Keep this page somewhere safe. Do not send it in a chat or upload it.',
      48,
      716,
      11,
    );
    text(
      'Print at actual size. Keep a second copy away from this device.',
      48,
      698,
      11,
    );
    for (var i = 0; i < words.length; i++) {
      text(
        '${i + 1}. ${words[i]}',
        48 + (i ~/ 8) * 168.0,
        660 - (i % 8) * 25.0,
        12,
      );
    }
    const side = 246.0;
    final unit = side / (image.moduleCount + 8);
    const left = (595 - side) / 2;
    const bottom = 164.0;
    stream.writeln('0 0 0 rg');
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (image.isDark(row, col)) {
          final x = left + (col + 4) * unit;
          final y = bottom + (image.moduleCount + 3 - row) * unit;
          stream.writeln(
            '${x.toStringAsFixed(4)} ${y.toStringAsFixed(4)} '
            '${unit.toStringAsFixed(4)} ${unit.toStringAsFixed(4)} re f',
          );
        }
      }
    }
    text('Restore: Loom > Restore account > Scan recovery QR', 48, 136, 11);
    text(
      'Or import the .loom file, or enter all 24 words in order.',
      48,
      116,
      11,
    );
    text(
      'Restores identity only. Sign in to the original server afterwards.',
      48,
      84,
      10,
    );
    text(
      'This kit does not include your server password or message history.',
      48,
      66,
      10,
    );
    final content = stream.toString();
    final objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
          '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
      '<< /Length ${ascii.encode(content).length} >>\nstream\n${content}endstream',
    ];
    final pdf = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[0];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(pdf.length);
      pdf.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
    }
    final xref = pdf.length;
    pdf.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
    for (final offset in offsets.skip(1)) {
      pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    pdf.write(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    );
    return Uint8List.fromList(ascii.encode(pdf.toString()));
  }
}
