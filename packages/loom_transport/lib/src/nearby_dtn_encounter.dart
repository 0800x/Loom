import 'dart:async';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';

import 'direct_node_delivery.dart';
import 'dtn_nearby_v2.dart';
import 'nearby_dtn_peer_bootstrap.dart';
import 'nearby_transport.dart';
import 'nearby_recipient_probe.dart';

typedef LoomNearbyDtnDurableAccept = FutureOr<LoomDtnHopAck> Function({
  required String transmissionId,
  required Uint8List exactOuterEnvelopeBytes,
});

final class LoomNearbyDtnEncounterResult {
  const LoomNearbyDtnEncounterResult({
    required this.attempted,
    required this.accepted,
    required this.failed,
    this.received = 0,
  });

  final int attempted;
  final int accepted;
  final int failed;
  final int received;
}

/// Executes authenticated store-carry-forward DTN work over one Nearby link.
///
/// The scanner/initiator forwards eligible durable packets to the advertising
/// peer. The receiver acknowledges only after [durablyAccept] commits custody.
/// Generic peers are never promoted to destination or verified-gateway routes;
/// that classification must come from separately verified routing evidence.
/// A destination Node domain may travel as an untrusted hop-local route sidecar
/// so a carrying peer can later verify and reach that Node after reconnecting.
final class LoomNearbyDtnEncounterCoordinator {
  LoomNearbyDtnEncounterCoordinator({
    required this.packetStore,
    required this.transferExecutor,
    required this.durablyAccept,
    this.routeStore,
    this.durablyAcceptRouted,
    LoomNearbyDtnPeerBootstrap? bootstrap,
    DateTime Function()? clock,
  })  : bootstrap = bootstrap ?? LoomNearbyDtnPeerBootstrap(),
        _clock = clock ?? DateTime.now;

  final LoomPacketStore packetStore;
  final LoomDtnTransferExecutor transferExecutor;
  final LoomNearbyDtnDurableAccept durablyAccept;
  final LoomPacketRouteStore? routeStore;
  final LoomNearbyDtnRoutedDurableAccept? durablyAcceptRouted;
  final LoomNearbyDtnPeerBootstrap bootstrap;
  final DateTime Function() _clock;
  int _transmissionSequence = 0;
  LoomNearbyRecipientProbeAcceptor? recipientProbeAcceptor;
  final _recentProbes = <String, DateTime>{};
  Future<void> Function()? onInboxChanged;
  void Function(LoomStoredDtnPacket packet)? onPacketForwarded;

  Future<LoomNearbyDtnEncounterResult> forwardOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    bool localCanStoreCarry = false,
    int maxPackets = 8,
    bool supportsRecipientProbe = false,
    bool supportsDuplex = false,
  }) async {
    if (maxPackets < 1 || maxPackets > 50) {
      throw ArgumentError.value(maxPackets, 'maxPackets');
    }
    LoomNearbyDtnPeerSession? session;
    try {
      session = await bootstrap.establishAsInitiator(
        link: link,
        signer: signer,
        canStoreCarry: localCanStoreCarry,
      );
      final result = await _forwardSession(
        session,
        maxPackets: maxPackets,
        supportsRecipientProbe: supportsRecipientProbe || supportsDuplex,
      );
      var received = 0;
      if (supportsDuplex) {
        await session.connection.send(_turnFrame(maxPackets));
        received = await _acceptSession(
          session,
          localCanStoreCarry: localCanStoreCarry,
          maxPackets: maxPackets,
          allowReverse: false,
        );
      }
      return LoomNearbyDtnEncounterResult(
        attempted: result.attempted,
        accepted: result.accepted,
        failed: result.failed,
        received: received,
      );
    } finally {
      if (session != null) {
        await session.connection.close();
      } else {
        try {
          await link.close();
        } catch (_) {}
      }
    }
  }

  Future<LoomNearbyDtnEncounterResult> _forwardSession(
    LoomNearbyDtnPeerSession session, {
    required int maxPackets,
    required bool supportsRecipientProbe,
    Set<String> excludePackets = const {},
  }) async {
    if (!session.opportunity.canStoreCarry && !supportsRecipientProbe) {
      return const LoomNearbyDtnEncounterResult(
        attempted: 0,
        accepted: 0,
        failed: 0,
      );
    }

    var attempted = 0;
    var accepted = 0;
    var failed = 0;
    final attemptedPackets = <String>{...excludePackets};
    final sender = LoomNearbyDtnTransferSender(
      connection: session.connection,
      destinationRoute: (packetId) =>
          routeStore?.readDestinationRoute(packetId)?.destinationNodeDomain,
      clock: _clock,
    );

    final allPrepared = transferExecutor.transferStore.listPreparedTransfers(
      limit: 500,
    );
    final prepared = allPrepared
        .where(
          (transfer) =>
              transfer.opportunityId == session.opportunity.opportunityId,
        )
        .toList(growable: false);
    for (final transfer in prepared) {
      if (attempted >= maxPackets) break;
      if (!attemptedPackets.add(transfer.packetId)) continue;
      final result = await transferExecutor.executePrepared(
        transmissionId: transfer.transmissionId,
        sender: sender,
      );
      attempted++;
      if (result.status == LoomDtnExecutionStatus.accepted ||
          result.status == LoomDtnExecutionStatus.alreadyAccepted) {
        accepted++;
        _reportForwarded(result.packet);
      } else {
        failed++;
      }
    }

    if (attempted < maxPackets) {
      final now = _clock().toUtc();
      final source = packetStore;
      final eligible = source is LoomNearbyPacketSource
          ? (source as LoomNearbyPacketSource).listNearbyCandidates(
              now,
              limit: 500,
            )
          : source.listEligible(now, limit: 500);
      _recentProbes.removeWhere(
        (_, time) => now.difference(time) >= const Duration(seconds: 30),
      );
      for (final packet in eligible) {
        if (attempted >= maxPackets) break;
        if (!attemptedPackets.add(packet.packetId)) continue;
        if (allPrepared.any(
          (transfer) =>
              transfer.packetId == packet.packetId &&
              transfer.opportunityId != session.opportunity.opportunityId,
        )) {
          continue;
        }
        if (supportsRecipientProbe &&
            (packet.copiesRemaining <= 1 ||
                !packet.isEligibleForForwarding ||
                !session.opportunity.canStoreCarry)) {
          final key = '${packet.packetId}:${session.remoteFingerprint}';
          if (_recentProbes.containsKey(key)) continue;
          if (_recentProbes.length >= 2000) {
            _recentProbes.remove(_recentProbes.keys.first);
          }
          _recentProbes[key] = now;
          attempted++;
          // No transfer is prepared and no copy/receipt state is changed.
          // Only the application that opens the recipient seal may take it.
          if (await LoomNearbyRecipientProbe.send(
            session.connection,
            packet.wireBytes,
          )) {
            accepted++;
            _reportForwarded(packet);
          }
          continue;
        }
        if (!packet.isEligibleForForwarding) continue;
        final preparedTransfer = transferExecutor.prepareNext(
          packetId: packet.packetId,
          opportunities: <LoomDtnOpportunity>[session.opportunity],
          transmissionId: _nextTransmissionId(now),
          now: now,
        );
        if (preparedTransfer == null) continue;
        final result = await transferExecutor.executePrepared(
          transmissionId: preparedTransfer.transmissionId,
          sender: sender,
        );
        attempted++;
        if (result.status == LoomDtnExecutionStatus.accepted ||
            result.status == LoomDtnExecutionStatus.alreadyAccepted) {
          accepted++;
          _reportForwarded(result.packet);
        } else {
          failed++;
        }
      }
    }

    return LoomNearbyDtnEncounterResult(
      attempted: attempted,
      accepted: accepted,
      failed: failed,
    );
  }

  Future<int> acceptOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    required bool localCanStoreCarry,
    int maxPackets = 8,
    Duration idleTimeout = const Duration(seconds: 20),
    Duration burstIdleTimeout = const Duration(seconds: 1),
  }) async {
    if (maxPackets < 1 || maxPackets > 50) {
      throw ArgumentError.value(maxPackets, 'maxPackets');
    }
    if (idleTimeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout');
    }
    if (burstIdleTimeout <= Duration.zero) {
      throw ArgumentError.value(burstIdleTimeout, 'burstIdleTimeout');
    }
    LoomNearbyDtnPeerSession? session;
    try {
      session = await bootstrap.establishAsResponder(
        link: link,
        signer: signer,
        canStoreCarry: localCanStoreCarry,
      );
      return await _acceptSession(
        session,
        localCanStoreCarry: localCanStoreCarry,
        maxPackets: maxPackets,
        idleTimeout: idleTimeout,
        burstIdleTimeout: burstIdleTimeout,
        allowReverse: true,
      );
    } finally {
      if (session != null) {
        await session.connection.close();
      } else {
        try {
          await link.close();
        } catch (_) {}
      }
    }
  }

  // Versioned control frames live inside the authenticated encrypted link.
  // A turn grants an opportunity to send, never recipient/custody authority.
  static List<int> _turnFrame(int budget) => [
        0x43,
        0x4e,
        0x44,
        0x58,
        1,
        budget,
      ];
  static bool _isTurnFrame(List<int> bytes) =>
      bytes.length == 6 &&
      bytes[0] == 0x43 &&
      bytes[1] == 0x4e &&
      bytes[2] == 0x44 &&
      bytes[3] == 0x58 &&
      bytes[4] == 1 &&
      bytes[5] <= 50;

  Future<int> _acceptSession(
    LoomNearbyDtnPeerSession session, {
    required bool localCanStoreCarry,
    required int maxPackets,
    required bool allowReverse,
    Duration idleTimeout = const Duration(seconds: 20),
    Duration burstIdleTimeout = const Duration(seconds: 1),
  }) async {
    final receiver = LoomNearbyDtnTransferReceiver(
      connection: session.connection,
      durablyAccept: durablyAccept,
      durablyAcceptRouted: durablyAcceptRouted,
    );
    var accepted = 0;
    var processed = 0;
    final receivedPackets = <String>{};
    while (processed <= maxPackets) {
      try {
        final bytes = await session.connection.receive(
          timeout: processed == 0 ? idleTimeout : burstIdleTimeout,
        );
        if (_isTurnFrame(bytes)) {
          final budget = bytes.last;
          if (allowReverse && budget > 0) {
            await _forwardSession(
              session,
              maxPackets: budget < maxPackets ? budget : maxPackets,
              supportsRecipientProbe: true,
              excludePackets: receivedPackets,
            );
            await session.connection.send(_turnFrame(0));
          }
          break;
        }
        if (processed >= maxPackets) {
          throw const FormatException('Nearby packet budget exceeded');
        }
        processed++;
        if (LoomNearbyRecipientProbe.isRequest(bytes)) {
          if (await LoomNearbyRecipientProbe.accept(
            session.connection,
            bytes,
            recipientProbeAcceptor,
          )) accepted++;
        } else {
          if (!localCanStoreCarry)
            throw StateError('Relay custody is disabled');
          final ack = await receiver.acknowledgeFrame(bytes);
          receivedPackets.add(ack.packetId);
          accepted++;
        }
        // Surface committed packets while the round is still running.
        try {
          final update = onInboxChanged?.call();
          if (update != null) unawaited(update.catchError((Object _) {}));
        } catch (_) {}
      } on TimeoutException {
        break;
      } catch (_) {
        if (processed == 0) rethrow;
        break;
      }
    }
    return accepted;
  }

  void _reportForwarded(LoomStoredDtnPacket packet) {
    try {
      onPacketForwarded?.call(packet);
    } catch (_) {}
  }

  String _nextTransmissionId(DateTime now) =>
      'nearby-${now.microsecondsSinceEpoch}-${_transmissionSequence++}';
}
