import 'dart:convert';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> attachment() => {
    'kind': 'audio',
    'url':
        'https://sender.test/api/v1/attachments/att_${List.filled(64, 'a').join()}',
    'key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    'bytes': 100,
    'music': true,
    'name': 'song.flac',
    'waveform': [0.0, 0.3, 1.0],
  };
  test(
    'music name and captured waveform survive rich encrypted-content decoding',
    () {
      final original = LoomMessageContent(attachment: attachment());
      final decoded = LoomMessageContent.decode(original.encode());
      expect(decoded.attachment!['name'], 'song.flac');
      expect(decoded.attachment!['waveform'], [0.0, 0.3, 1.0]);
      expect(decoded.attachment!['music'], true);
    },
  );
  test('malformed or oversized waveform is rejected before UI casts', () {
    for (final bad in <Object>[
      [1.1],
      [-0.1],
      ['bad'],
      List.filled(65, .5),
      'bad',
    ]) {
      final data = attachment()..['waveform'] = bad;
      expect(
        () => LoomMessageContent.decode(
          '${LoomMessageContent.prefix}${jsonEncode({'v': 1, 'text': '', 'attachment': data})}',
        ),
        throwsFormatException,
      );
    }
  });
  test('legacy audio without optional metadata still decodes', () {
    final data = attachment()
      ..remove('music')
      ..remove('name')
      ..remove('waveform');
    expect(
      LoomMessageContent.decode(
        LoomMessageContent(attachment: data).encode(),
      ).attachment!['kind'],
      'audio',
    );
  });
  test(
    'accent reaches message palette and Material controls in all themes',
    () {
      for (final build in [
        LoomTheme.light,
        LoomTheme.dark,
        LoomTheme.oled,
      ]) {
        final theme = build(accent: const Color(0xFFE91E63));
        final palette = theme.extension<LoomPalette>()!;
        expect(palette.primary, theme.colorScheme.primary);
        expect(palette.onPrimary, theme.colorScheme.onPrimary);
        expect(
          palette.primary,
          isNot(build().extension<LoomPalette>()!.primary),
        );
      }
    },
  );
}
