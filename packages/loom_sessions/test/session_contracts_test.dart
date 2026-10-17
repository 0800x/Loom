import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:test/test.dart';

void main() {
  test('session records require a protected state and valid remote device', () {
    final record = LoomSessionRecord(
      sessionId: 'session-1',
      remoteDevice: const LoomRemoteDeviceRef(
        accountId: 'account-1',
        deviceId: 'device-1',
        deviceKeyVersion: 1,
      ),
      protocolVersion: 'Loom-Session-v2',
      mode: LoomCryptoSessionMode.active,
      revision: 3,
      protectedState: Uint8List.fromList(<int>[1, 2, 3]),
      createdAt: DateTime.utc(2026, 9, 5),
      updatedAt: DateTime.utc(2026, 9, 5),
    );

    expect(record.validate, returnsNormally);
  });

  test('empty protected session state fails closed', () {
    final record = LoomSessionRecord(
      sessionId: 'session-1',
      remoteDevice: const LoomRemoteDeviceRef(
        accountId: 'account-1',
        deviceId: 'device-1',
        deviceKeyVersion: 1,
      ),
      protocolVersion: 'Loom-Session-v2',
      mode: LoomCryptoSessionMode.active,
      revision: 0,
      protectedState: Uint8List(0),
      createdAt: DateTime.utc(2026, 9, 5),
      updatedAt: DateTime.utc(2026, 9, 5),
    );

    expect(record.validate, throwsFormatException);
  });

  test('crypto outbox accepts an initial committed session revision', () {
    final ciphertext = LoomSessionCiphertext(
      protocolVersion: 'Loom-Session-v2',
      sessionLocator: 'opaque-session-locator',
      bytes: Uint8List.fromList(<int>[7, 8, 9]),
    );
    final record = LoomCryptoOutboxRecord(
      operationId: 'op-1',
      sessionId: 'session-1',
      sessionRevision: 0,
      messageId: 'message-1',
      packetId: 'packet-1',
      ciphertext: ciphertext,
      createdAt: DateTime.utc(2026, 9, 5),
    );

    expect(record.validate, returnsNormally);
  });

  test('negative crypto outbox revision fails closed', () {
    final record = LoomCryptoOutboxRecord(
      operationId: 'op-1',
      sessionId: 'session-1',
      sessionRevision: -1,
      messageId: 'message-1',
      packetId: 'packet-1',
      ciphertext: LoomSessionCiphertext(
        protocolVersion: 'Loom-Session-v2',
        sessionLocator: 'opaque-session-locator',
        bytes: Uint8List.fromList(<int>[7]),
      ),
      createdAt: DateTime.utc(2026, 9, 5),
    );

    expect(record.validate, throwsFormatException);
  });

  test('empty packet id fails closed', () {
    final record = LoomCryptoOutboxRecord(
      operationId: 'op-1',
      sessionId: 'session-1',
      sessionRevision: 0,
      messageId: 'message-1',
      packetId: '',
      ciphertext: LoomSessionCiphertext(
        protocolVersion: 'Loom-Session-v2',
        sessionLocator: 'opaque-session-locator',
        bytes: Uint8List.fromList(<int>[7]),
      ),
      createdAt: DateTime.utc(2026, 9, 5),
    );

    expect(record.validate, throwsFormatException);
  });
}
