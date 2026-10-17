import 'package:sqlite3/sqlite3.dart';

/// Local-only maintenance helpers for the encrypted messaging database.
///
/// These operations never contact a Home Node and therefore do not mean
/// "delete for everyone". They are primarily useful during pre-alpha testing
/// and diagnostics. Pending sends for deleted local records are cancelled so a
/// message removed by the user cannot later be transmitted by the local retry
/// queue.
abstract final class LoomLocalMessagingCleanup {
  static int deleteMessageByClientId({
    required String databasePath,
    required String clientId,
  }) {
    if (clientId.trim().isEmpty) {
      throw ArgumentError.value(clientId, 'clientId');
    }
    final db = sqlite3.open(databasePath);
    try {
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute(
          'DELETE FROM pending_operations WHERE client_id = ?',
          <Object?>[clientId],
        );
        db.execute('DELETE FROM messages WHERE client_id = ?', <Object?>[
          clientId,
        ]);
        final changed = db.updatedRows;
        db.execute('COMMIT');
        return changed;
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      db.dispose();
    }
  }

  static int clearConversation({
    required String databasePath,
    required String conversationId,
  }) {
    if (conversationId.trim().isEmpty) {
      throw ArgumentError.value(conversationId, 'conversationId');
    }
    final db = sqlite3.open(databasePath);
    try {
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute(
          'DELETE FROM pending_operations WHERE conversation_id = ?',
          <Object?>[conversationId],
        );
        db.execute('DELETE FROM messages WHERE conversation_id = ?', <Object?>[
          conversationId,
        ]);
        final changed = db.updatedRows;
        db.execute(
          'UPDATE conversations SET unread_count = 0 WHERE id = ?',
          <Object?>[conversationId],
        );
        db.execute('COMMIT');
        return changed;
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      db.dispose();
    }
  }
}
