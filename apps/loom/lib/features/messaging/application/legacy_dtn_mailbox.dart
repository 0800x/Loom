import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_protocol/loom_protocol.dart';

import 'legacy_dtn_delivery_intake.dart';

/// Maintains the rotating opaque mailbox window used by the production-E2EE
/// compatibility bridge.
///
/// A device pre-registers one week of six-hour recipient tags while online so
/// senders can route packets even after this device goes offline. On reconnect,
/// the device sweeps the previous week of tags, durably accepts packets into the
/// ordinary message DB, then ACKs the Home Node copy.
final class LoomLegacyDtnMailboxCoordinator {
  LoomLegacyDtnMailboxCoordinator({
    required this.client,
    required this.deviceSecurity,
    required this.identityId,
    required this.deviceId,
    required this.ownAddress,
    required this.applicationSupportPath,
    LoomRelaySealer? sealer,
  }) : _sealer = sealer ?? LoomRelaySealer();

  static const Duration _slot = Duration(hours: 6);
  static const int _historySlots = 28;

  // Current slot + 27 future slots is exactly one week of six-hour tags.
  // Keeping this at 27 also guarantees that slotEnd + 7 days stays within the
  // Node's strict 14-day mailbox lifetime cap, even for the furthest tag.
  static const int _futureSlots = 27;

  final LoomV2DeliveryClient client;
  final LoomDeviceSecurityCore deviceSecurity;
  final String identityId;
  final String deviceId;
  final String ownAddress;
  final String applicationSupportPath;
  final LoomRelaySealer _sealer;

  int? _registeredFromSlot;
  DateTime? _lastPullSweepAt;
  bool _syncing = false;

  Future<int> synchronize({bool force = false}) async {
    if (_syncing) return 0;
    _syncing = true;
    try {
      final bundle = await deviceSecurity.readDevice(
        identityId: identityId,
        deviceId: deviceId,
      );
      if (bundle == null) {
        throw StateError('Local device agreement key is unavailable');
      }
      final now = DateTime.now().toUtc();
      final slot = _slotNumber(now);
      if (force || _registeredFromSlot != slot) {
        await _registerFutureWindow(
          agreementPublicKey: bundle.agreementPublicKey,
          currentSlot: slot,
        );
        _registeredFromSlot = slot;
      }
      if (!force &&
          _lastPullSweepAt != null &&
          now.difference(_lastPullSweepAt!) < const Duration(minutes: 10)) {
        return 0;
      }
      final accepted = await _pullHistoryWindow(
        agreementPublicKey: bundle.agreementPublicKey,
        currentSlot: slot,
      );
      _lastPullSweepAt = now;
      return accepted;
    } finally {
      _syncing = false;
    }
  }

  Future<void> _registerFutureWindow({
    required String agreementPublicKey,
    required int currentSlot,
  }) async {
    for (var offset = 0; offset <= _futureSlots; offset++) {
      final slot = currentSlot + offset;
      final token = await _tokenForSlot(agreementPublicKey, slot);
      final slotEnd = _timeForSlot(slot + 1);
      // Packets are capped below seven days. Keeping each rotating token valid
      // seven days past its slot end leaves a clean delivery margin while
      // remaining below the server's fourteen-day mailbox cap.
      final expiresAt = slotEnd.add(const Duration(days: 7));
      await client.registerMailbox(mailboxToken: token, expiresAt: expiresAt);
    }
  }

  Future<int> _pullHistoryWindow({
    required String agreementPublicKey,
    required int currentSlot,
  }) async {
    var acceptedCount = 0;
    for (var offset = -_historySlots; offset <= 0; offset++) {
      final token = await _tokenForSlot(
        agreementPublicKey,
        currentSlot + offset,
      );
      List<LoomV2MailboxPacket> packets;
      try {
        packets = await client.pullPackets(mailboxToken: token, limit: 50);
      } catch (_) {
        // Old tags may never have been registered (for example after a fresh
        // install). One missing mailbox must not block the rest of the sweep.
        continue;
      }
      for (final packet in packets) {
        final accepted = await LoomLegacyDtnDeliveryIntake.acceptMailboxPacket(
          applicationSupportPath: applicationSupportPath,
          ownAddress: ownAddress,
          identityId: identityId,
          deviceId: deviceId,
          deviceSecurity: deviceSecurity,
          packet: packet,
        );
        if (!accepted) continue;
        await client.acknowledgePacket(packet.packetId);
        acceptedCount++;
      }
    }
    return acceptedCount;
  }

  Future<Uint8List> _tokenForSlot(String agreementPublicKey, int slot) async {
    final encoded = await _sealer.recipientTag(
      recipientAgreementPublicKey: agreementPublicKey,
      time: _timeForSlot(slot),
    );
    return Uint8List.fromList(base64Url.decode(base64Url.normalize(encoded)));
  }

  static int _slotNumber(DateTime time) =>
      time.toUtc().millisecondsSinceEpoch ~/ _slot.inMilliseconds;

  static DateTime _timeForSlot(int slot) => DateTime.fromMillisecondsSinceEpoch(
    slot * _slot.inMilliseconds,
    isUtc: true,
  );

  void close() => client.close(force: true);
}
