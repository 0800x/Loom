import 'dart:convert';

import 'package:loom_next/features/onboarding/application/recovery_backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Standard 256-bit BIP39 zero-entropy phrase. IdentityCore checks its checksum
  // when imported; the portable envelope must preserve its exact word order.
  final words = [...List<String>.filled(23, 'abandon'), 'art'];

  test('downloaded recovery envelope preserves all words and their order', () {
    final backup = LoomRecoveryBackup(words: words);
    final restored = LoomRecoveryBackup.parse(utf8.decode(backup.fileBytes));
    expect(restored.words, words);
    expect(restored.sentence, '${List.filled(23, 'abandon').join(' ')} art');
    final value = jsonDecode(backup.encoded) as Map<String, dynamic>;
    expect(value.keys.toSet(), {
      'format',
      'version',
      'identityVersion',
      'words',
    });
  });

  test(
    'server/device QR, future formats and incomplete files cannot import',
    () {
      for (final raw in [
        'https://server.test/?loom-node=1',
        jsonEncode({
          'format': 'loom-device-link',
          'version': 1,
          'words': words,
        }),
        jsonEncode({
          'format': 'loom-recovery',
          'version': 2,
          'identityVersion': 1,
          'words': words,
        }),
        jsonEncode({
          'format': 'loom-recovery',
          'version': 1,
          'identityVersion': 2,
          'words': words,
        }),
        jsonEncode({
          'format': 'loom-recovery',
          'version': 1,
          'identityVersion': 1,
          'words': words.take(23).toList(),
        }),
        jsonEncode({
          'format': 'loom-recovery',
          'version': 1,
          'identityVersion': 1,
          'words': [...words.take(23), 42],
        }),
        ' ' * 4097,
      ]) {
        expect(() => LoomRecoveryBackup.parse(raw), throwsFormatException);
      }
    },
  );

  test(
    'PDF contains a complete human-readable backup and valid object offsets',
    () {
      final pdf = ascii.decode(LoomRecoveryBackup(words: words).printablePdf());
      expect(pdf, startsWith('%PDF-1.4'));
      expect(pdf, contains('/MediaBox [0 0 595 842]'));
      expect(pdf, contains('NOT ENCRYPTED'));
      expect(pdf, contains('(24. art)'));
      expect(
        pdf,
        contains('re f'),
      ); // QR is vector, rather than a missing asset.
      final xref = int.parse(
        RegExp(r'startxref\n(\d+)').firstMatch(pdf)!.group(1)!,
      );
      expect(pdf.substring(xref), startsWith('xref\n'));
      final offsets = RegExp(
        r'^(\d{10}) 00000 n ',
        multiLine: true,
      ).allMatches(pdf).toList();
      expect(offsets, hasLength(5));
      for (var i = 0; i < offsets.length; i++) {
        final offset = int.parse(offsets[i].group(1)!);
        expect(pdf.substring(offset), startsWith('${i + 1} 0 obj'));
      }
      final stream = RegExp(r'/Length (\d+) >>\nstream\n([\s\S]*?)endstream')
          .firstMatch(pdf)!;
      expect(
        ascii.encode(stream.group(2)!).length,
        int.parse(stream.group(1)!),
      );
    },
  );
}
