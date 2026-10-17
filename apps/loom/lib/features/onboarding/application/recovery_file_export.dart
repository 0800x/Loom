import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum LoomRecoveryExportResult { saved, cancelled, downloadStarted }

Future<LoomRecoveryExportResult> saveLoomRecoveryFile(
  Uint8List bytes, {
  required bool pdf,
  bool Function()? isCurrent,
}) async {
  bool current() => isCurrent?.call() ?? true;
  if (!current()) return LoomRecoveryExportResult.cancelled;
  final name = pdf ? 'Loom-recovery.pdf' : 'Loom-recovery.loom';
  final mime = pdf ? 'application/pdf' : 'application/json';
  // The picker may outlive the caller or an AppLock transition. Own a copy so
  // clearing the caller's buffer cannot produce a zero-filled "saved" file.
  final exportBytes = Uint8List.fromList(bytes);
  try {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      if (!current()) return LoomRecoveryExportResult.cancelled;
      final saved =
          await const MethodChannel(
            'loom/recovery_export',
          ).invokeMethod<bool>('save', {
            'name': name,
            'mime': mime,
            'bytes': exportBytes,
          }) ??
          false;
      return saved && current()
          ? LoomRecoveryExportResult.saved
          : LoomRecoveryExportResult.cancelled;
    }
    // file_selector has no iOS save-location support. Do not silently write a
    // secret into Downloads/cache or misreport an unsupported export as success.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      throw UnsupportedError('Write the words down on this device instead.');
    }
    final file = XFile.fromData(exportBytes, name: name, mimeType: mime);
    if (kIsWeb) {
      if (!current()) return LoomRecoveryExportResult.cancelled;
      await file.saveTo(name);
      return current()
          ? LoomRecoveryExportResult.downloadStarted
          : LoomRecoveryExportResult.cancelled;
    }
    if (!current()) return LoomRecoveryExportResult.cancelled;
    final location = await getSaveLocation(suggestedName: name);
    if (location == null || !current()) {
      return LoomRecoveryExportResult.cancelled;
    }
    await file.saveTo(location.path);
    return current()
        ? LoomRecoveryExportResult.saved
        : LoomRecoveryExportResult.cancelled;
  } finally {
    exportBytes.fillRange(0, exportBytes.length, 0);
  }
}
