import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client iconography is Amicons-only through LoomIcons', () {
    final roots = <Directory>[
      Directory('lib'),
      Directory('../../packages/loom_design/lib'),
    ];
    final violations = <String>[];

    for (final root in roots) {
      expect(
        root.existsSync(),
        isTrue,
        reason: 'Missing source root: ${root.path}',
      );
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }

        final source = entity.readAsStringSync();
        final normalizedPath = entity.path.replaceAll('\\', '/');
        final isCatalog = normalizedPath.endsWith(
          'packages/loom_design/lib/src/loom_icons.dart',
        );

        if (source.contains('CupertinoIcons.')) {
          violations.add('${entity.path}: CupertinoIcons');
        }

        final withoutApprovedCatalog = source.replaceAll('LoomIcons.', '');
        if (withoutApprovedCatalog.contains('Icons.')) {
          violations.add('${entity.path}: Material Icons');
        }

        if (!isCatalog && source.contains('Amicons.')) {
          violations.add(
            '${entity.path}: direct Amicons use outside LoomIcons',
          );
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'All explicit Loom UI glyphs must resolve through the '
          'Amicons-backed LoomIcons catalog:\n${violations.join('\n')}',
    );
  });
}
