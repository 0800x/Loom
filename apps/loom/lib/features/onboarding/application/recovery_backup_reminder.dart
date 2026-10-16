import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import 'recovery_file_export.dart';

enum LoomRecoveryBackupStatus { deferred, saved, manuallyConfirmed }

/// Only a hash of the public identity ID and backup status are persisted.
/// Recovery words, entropy, passwords and export paths never belong here.
class LoomRecoveryBackupReminderStore {
  LoomRecoveryBackupReminderStore({this.directory});

  final Directory? directory;
  static Future<void> _writes = Future<void>.value();

  Future<File> _file(String identityId) async {
    if (identityId.isEmpty) throw ArgumentError.value(identityId, 'identityId');
    final digest = await Sha256().hash(utf8.encode(identityId));
    final key = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final root = directory ?? await getApplicationSupportDirectory();
    return File('${root.path}/loom-recovery-reminders/$key.json');
  }

  Future<LoomRecoveryBackupStatus?> load(String identityId) async {
    await _writes;
    return _read(await _file(identityId));
  }

  Future<LoomRecoveryBackupStatus?> _read(File file) async {
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic> || data['version'] != 1) return null;
      return LoomRecoveryBackupStatus.values
          .where((value) => value.name == data['status'])
          .firstOrNull;
    } catch (_) {
      // Missing/damaged UI metadata must never change account startup.
      return null;
    }
  }

  Future<bool> defer(String identityId) =>
      _write(identityId, LoomRecoveryBackupStatus.deferred);

  Future<bool> confirmManualBackup(String identityId) =>
      _write(identityId, LoomRecoveryBackupStatus.manuallyConfirmed);

  /// Cancellation, browser download initiation and exceptions do not prove
  /// that a durable backup exists, so they cannot clear a deferred reminder.
  Future<bool> recordExport(
    String identityId,
    LoomRecoveryExportResult result,
  ) => result == LoomRecoveryExportResult.saved
      ? _write(identityId, LoomRecoveryBackupStatus.saved)
      : Future<bool>.value(false);

  Future<bool> _write(String identityId, LoomRecoveryBackupStatus status) {
    var success = false;
    final operation = _writes.then((_) async {
      try {
        final file = await _file(identityId);
        final previous = await _read(file);
        // Revisiting setup must not discard evidence of an earlier backup.
        if (status == LoomRecoveryBackupStatus.deferred &&
            (previous == LoomRecoveryBackupStatus.saved ||
                previous == LoomRecoveryBackupStatus.manuallyConfirmed)) {
          success = true;
          return;
        }
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(
          jsonEncode({'version': 1, 'status': status.name}),
          flush: true,
        );
        await temporary.rename(file.path);
        success = true;
      } catch (_) {
        // Report failure; never claim that a reminder or backup was saved.
      }
    });
    _writes = operation;
    return operation.then((_) => success);
  }
}
