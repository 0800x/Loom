import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:test/test.dart';

void main() {
  LoomSessionRecord session(LoomCryptoSessionMode mode) => LoomSessionRecord(
        sessionId: 'session-backup-policy',
        remoteDevice: const LoomRemoteDeviceRef(
          accountId: 'remote-account',
          deviceId: 'remote-device',
          deviceKeyVersion: 1,
        ),
        protocolVersion: 'provider-v1',
        mode: mode,
        revision: 3,
        protectedState: Uint8List.fromList(<int>[1, 2, 3]),
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 5),
      );

  test('active ratchet state is excluded from generic backup', () {
    expect(
      LoomSessionBackupPolicy.dispositionFor(
        session(LoomCryptoSessionMode.active),
      ),
      LoomSessionBackupDisposition.excludedLiveState,
    );
    expect(
      () => LoomSessionBackupPolicy.restoredModeForArchive(
        LoomCryptoSessionMode.active,
      ),
      throwsFormatException,
    );
    expect(
      LoomSessionBackupPolicy.mayRestoreAsSendable(
        LoomCryptoSessionMode.active,
      ),
      isFalse,
    );
  });

  test('receive-only history may restore only as receive-only archive', () {
    expect(
      LoomSessionBackupPolicy.dispositionFor(
        session(LoomCryptoSessionMode.receiveOnly),
      ),
      LoomSessionBackupDisposition.receiveOnlyArchive,
    );
    expect(
      LoomSessionBackupPolicy.restoredModeForArchive(
        LoomCryptoSessionMode.receiveOnly,
      ),
      LoomCryptoSessionMode.receiveOnly,
    );
  });
}
