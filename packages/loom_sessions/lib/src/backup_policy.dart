import 'session_contracts.dart';

/// Architecture-v2 rule for backup/restore of session-security state.
///
/// A live ratchet must never be copied into a generic account backup. Restoring
/// the same send chain on two endpoints can cause state/key reuse and fork the
/// peer's view of the session. Recovery therefore restores identity/device
/// authorization material separately and establishes fresh sessions.
enum LoomSessionBackupDisposition { excludedLiveState, receiveOnlyArchive }

abstract final class LoomSessionBackupPolicy {
  /// Live provider/session state is excluded from ordinary backups by default.
  static LoomSessionBackupDisposition dispositionFor(
    LoomSessionRecord session,
  ) {
    session.validate();
    switch (session.mode) {
      case LoomCryptoSessionMode.active:
      case LoomCryptoSessionMode.establishing:
      case LoomCryptoSessionMode.noSession:
      case LoomCryptoSessionMode.resetRequired:
        return LoomSessionBackupDisposition.excludedLiveState;
      case LoomCryptoSessionMode.receiveOnly:
      case LoomCryptoSessionMode.revoked:
      case LoomCryptoSessionMode.expired:
        return LoomSessionBackupDisposition.receiveOnlyArchive;
    }
  }

  static bool mayRestoreAsSendable(LoomCryptoSessionMode mode) => false;

  /// Historical session material may only be restored under an explicit
  /// receive-only/archive path. It may never silently become `active` after a
  /// device restore, clone, or migration.
  static LoomCryptoSessionMode restoredModeForArchive(
    LoomCryptoSessionMode sourceMode,
  ) {
    switch (sourceMode) {
      case LoomCryptoSessionMode.receiveOnly:
      case LoomCryptoSessionMode.revoked:
      case LoomCryptoSessionMode.expired:
        return LoomCryptoSessionMode.receiveOnly;
      case LoomCryptoSessionMode.active:
      case LoomCryptoSessionMode.establishing:
      case LoomCryptoSessionMode.noSession:
      case LoomCryptoSessionMode.resetRequired:
        throw const FormatException(
          'Live Loom session state must not be restored from backup',
        );
    }
  }
}
