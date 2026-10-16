import 'dart:async';
import 'dart:io';

import 'package:loom_next/features/onboarding/application/recovery_file_export.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('loom/recovery_export');
  for (final saved in [true, false]) {
    test(
      'Android export reports ${saved ? "saved" : "cancelled"} truthfully',
      () async {
        final previous = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (_) async => saved);
        try {
          expect(
            await saveLoomRecoveryFile(Uint8List.fromList([1]), pdf: false),
            saved
                ? LoomRecoveryExportResult.saved
                : LoomRecoveryExportResult.cancelled,
          );
        } finally {
          messenger.setMockMethodCallHandler(channel, null);
          debugDefaultTargetPlatformOverride = previous;
        }
      },
    );
  }
  test(
    'failed export propagates the failure instead of reporting saved',
    () async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'write_failed'),
      );
      try {
        await expectLater(
          saveLoomRecoveryFile(Uint8List.fromList([1]), pdf: true),
          throwsA(isA<PlatformException>()),
        );
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = previous;
      }
    },
  );

  test(
    'a revoked desktop picker never writes a zero-filled recovery file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'loom-export-test-',
      );
      final destination = File('${directory.path}/recovery.loom');
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousSelector = FileSelectorPlatform.instance;
      final selector = _DeferredFileSelector();
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      FileSelectorPlatform.instance = selector;
      var current = true;
      final bytes = Uint8List.fromList([1, 2, 3]);
      try {
        final export = saveLoomRecoveryFile(
          bytes,
          pdf: false,
          isCurrent: () => current,
        );
        await selector.opened.future;
        // AppLock/disposal revokes the operation while the OS picker is open.
        current = false;
        bytes.fillRange(0, bytes.length, 0);
        selector.location.complete(FileSaveLocation(destination.path));
        expect(await export, LoomRecoveryExportResult.cancelled);
        expect(await destination.exists(), isFalse);
      } finally {
        FileSelectorPlatform.instance = previousSelector;
        debugDefaultTargetPlatformOverride = previousPlatform;
        await directory.delete(recursive: true);
      }
    },
  );

  test('desktop exporter owns bytes across the asynchronous picker', () async {
    final directory = await Directory.systemTemp.createTemp(
      'loom-export-test-',
    );
    final destination = File('${directory.path}/recovery.loom');
    final previousPlatform = debugDefaultTargetPlatformOverride;
    final previousSelector = FileSelectorPlatform.instance;
    final selector = _DeferredFileSelector();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    FileSelectorPlatform.instance = selector;
    final bytes = Uint8List.fromList([1, 2, 3]);
    try {
      final export = saveLoomRecoveryFile(bytes, pdf: false);
      await selector.opened.future;
      bytes.fillRange(0, bytes.length, 0);
      selector.location.complete(FileSaveLocation(destination.path));
      expect(await export, LoomRecoveryExportResult.saved);
      expect(await destination.readAsBytes(), [1, 2, 3]);
    } finally {
      FileSelectorPlatform.instance = previousSelector;
      debugDefaultTargetPlatformOverride = previousPlatform;
      await directory.delete(recursive: true);
    }
  });

  test('revoked Android operation cannot invoke the native exporter', () async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return true;
    });
    try {
      expect(
        await saveLoomRecoveryFile(
          Uint8List.fromList([1]),
          pdf: false,
          isCurrent: () => false,
        ),
        LoomRecoveryExportResult.cancelled,
      );
      expect(calls, 0);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = previous;
    }
  });

  test(
    'revocation during native save cannot report a confirmed backup',
    () async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var current = true;
      messenger.setMockMethodCallHandler(channel, (_) async {
        current = false;
        return true;
      });
      try {
        expect(
          await saveLoomRecoveryFile(
            Uint8List.fromList([1]),
            pdf: false,
            isCurrent: () => current,
          ),
          LoomRecoveryExportResult.cancelled,
        );
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = previous;
      }
    },
  );
}

class _DeferredFileSelector extends FileSelectorPlatform {
  final opened = Completer<void>();
  final location = Completer<FileSaveLocation?>();

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) {
    opened.complete();
    return location.future;
  }
}
