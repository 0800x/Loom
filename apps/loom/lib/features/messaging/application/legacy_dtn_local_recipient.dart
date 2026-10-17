import 'dart:convert';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_dtn/loom_dtn.dart';

import 'legacy_dtn_delivery_intake.dart';
import 'nearby_message_receipts.dart';

/// Promotes a carried generic DTN packet into the ordinary inbox when this
/// device is the packet's actual recipient.
///
/// Generic store-carry-forward peers intentionally exchange only opaque routing
/// hints, so the peer protocol does not reveal recipient identity. After a
/// packet is durably accepted, the local device can privately compare the
/// rotating mailbox token against its own recent recipient tags. A match is
/// then opened with the device agreement key and committed through the normal
/// production-E2EE intake path.
final class LoomLegacyDtnLocalRecipientSweeper {
  const LoomLegacyDtnLocalRecipientSweeper({
    this.historySlots = 28,
    this.futureClockSkewSlots = 1,
  });

  final int historySlots;
  final int futureClockSkewSlots;

  Future<int> consume({
    required String applicationSupportPath,
    required String ownAddress,
    required String identityId,
    required String deviceId,
    required LoomDeviceSecurityCore deviceSecurity,
    DateTime? now,
  }) async {
    await LoomNearbyMessageReceipts.flush(
      applicationSupportPath: applicationSupportPath,
      ownAddress: ownAddress,
      identityId: identityId,
      deviceId: deviceId,
      deviceSecurity: deviceSecurity,
    );
    if (historySlots < 0 || historySlots > 32) {
      throw ArgumentError.value(historySlots, 'historySlots');
    }
    if (futureClockSkewSlots < 0 || futureClockSkewSlots > 2) {
      throw ArgumentError.value(futureClockSkewSlots, 'futureClockSkewSlots');
    }

    final device = await deviceSecurity.readDevice(
      identityId: identityId,
      deviceId: deviceId,
    );
    if (device == null) return 0;

    final current = (now ?? DateTime.now()).toUtc();
    final sealer = LoomRelaySealer();
    final currentSlot = _slotNumber(current);
    final localTokens = <String>{};
    for (var offset = -historySlots; offset <= futureClockSkewSlots; offset++) {
      localTokens.add(
        await sealer.recipientTag(
          recipientAgreementPublicKey: device.agreementPublicKey,
          time: _timeForSlot(currentSlot + offset),
        ),
      );
    }

    final store = LoomSqlitePacketStore.openFile(
      '$applicationSupportPath/loom-dtn-v2.sqlite3',
    );
    try {
      store.expireDue(current);
      final candidates = store.listEligible(current, limit: 500);
      var acceptedCount = 0;
      for (final packet in candidates) {
        final token = base64UrlEncode(packet.mailboxToken).replaceAll('=', '');
        if (!localTokens.contains(token)) continue;

        final accepted = await LoomLegacyDtnDeliveryIntake.acceptEnvelope(
          applicationSupportPath: applicationSupportPath,
          ownAddress: ownAddress,
          identityId: identityId,
          deviceId: deviceId,
          deviceSecurity: deviceSecurity,
          expectedPacketId: packet.packetId,
          expectedMailboxToken: packet.mailboxToken,
          exactOuterEnvelopeBytes: packet.wireBytes,
          fallbackCreatedAt: packet.storedAt,
        );
        if (!accepted) continue;

        store.markRecipientConfirmed(packet.packetId, current);
        acceptedCount++;
      }
      return acceptedCount;
    } finally {
      store.close();
    }
  }

  static const Duration _slot = Duration(hours: 6);

  static int _slotNumber(DateTime time) =>
      time.toUtc().millisecondsSinceEpoch ~/ _slot.inMilliseconds;

  static DateTime _timeForSlot(int slot) => DateTime.fromMillisecondsSinceEpoch(
    slot * _slot.inMilliseconds,
    isUtc: true,
  );
}
