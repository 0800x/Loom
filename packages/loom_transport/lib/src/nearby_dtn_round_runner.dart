import 'dart:async';
import 'dart:math';

import 'direct_node_delivery.dart';
import 'nearby_dtn_encounter.dart';
import 'nearby_transport.dart';

final class LoomNearbyDtnRoundResult {
  const LoomNearbyDtnRoundResult({
    required this.discoveredCandidates,
    required this.connectedCandidates,
    required this.outboundPacketsAccepted,
    required this.inboundPacketsAccepted,
    required this.failedEncounters,
  });

  final int discoveredCandidates;
  final int connectedCandidates;
  final int outboundPacketsAccepted;
  final int inboundPacketsAccepted;
  final int failedEncounters;
}

/// Runs one bounded privacy-preserving Nearby DTN discovery round.
///
/// The local beacon contains only a fresh random rendezvous id, supported
/// bearer names and a short expiry. Identity proof and relay consent are
/// exchanged only after a link exists inside the authenticated DTN bootstrap.
final class LoomNearbyDtnRoundRunner {
  LoomNearbyDtnRoundRunner({
    required this.coordinator,
    required this.signer,
    DateTime Function()? clock,
    String Function()? rendezvousIdFactory,
  }) : _clock = clock ?? DateTime.now,
       _rendezvousIdFactory = rendezvousIdFactory ?? _createRandomRendezvousId;

  final LoomNearbyDtnEncounterCoordinator coordinator;
  final LoomDirectTransportSigner signer;
  final DateTime Function() _clock;
  final String Function() _rendezvousIdFactory;

  Future<LoomNearbyDtnRoundResult> run({
    required LoomNearbyRadioAdapter radio,
    required LoomNearbyBearer bearer,
    required bool allowStoreCarry,
    Duration scanTimeout = const Duration(seconds: 8),
    Duration advertisementLifetime = const Duration(seconds: 15),
    int maxCandidates = 4,
    int maxPacketsPerLink = 8,
  }) async {
    if (!radio.supportedBearers.contains(bearer)) {
      throw StateError('Nearby radio does not support ${bearer.name}');
    }
    if (scanTimeout <= Duration.zero ||
        advertisementLifetime <= Duration.zero) {
      throw ArgumentError('Nearby DTN round durations must be positive');
    }
    if (maxCandidates < 1 || maxCandidates > 16) {
      throw ArgumentError.value(maxCandidates, 'maxCandidates');
    }
    if (maxPacketsPerLink < 1 || maxPacketsPerLink > 50) {
      throw ArgumentError.value(maxPacketsPerLink, 'maxPacketsPerLink');
    }

    final now = _clock().toUtc();
    final advertisement = LoomNearbyAdvertisement(
      protocolVersion: 1,
      rendezvousId: 'dtn-dx1-${_rendezvousIdFactory()}',
      bearers: <LoomNearbyBearer>[bearer],
      expiresAt: now.add(advertisementLifetime),
    );
    final advertising = await radio.advertise(advertisement);
    final inboundTasks = <Future<int>>[];
    var failedEncounters = 0;
    final incomingSubscription = advertising.incomingLinks.listen((link) {
      final task = coordinator
          .acceptOverLink(
            link: link,
            signer: signer,
            localCanStoreCarry: allowStoreCarry,
            maxPackets: maxPacketsPerLink,
          )
          .catchError((Object _) {
            failedEncounters++;
            return 0;
          });
      inboundTasks.add(task);
    });

    var discovered = 0;
    var connected = 0;
    var outboundAccepted = 0;
    var reverseAccepted = 0;
    final seenHandles = <String>{};
    try {
      await for (final candidate in radio.scan(timeout: scanTimeout)) {
        if (discovered >= maxCandidates) break;
        if (candidate.bearer != bearer ||
            candidate.advertisement.protocolVersion != 1 ||
            candidate.advertisement.rendezvousId.startsWith('pg1-') ||
            candidate.advertisement.rendezvousId.startsWith('msg-gw-v1-') ||
            !candidate.advertisement.expiresAt.isAfter(_clock().toUtc()) ||
            !seenHandles.add(candidate.nativeHandle)) {
          continue;
        }
        discovered++;
        try {
          final link = await radio.connect(candidate);
          connected++;
          final result = await coordinator.forwardOverLink(
            link: link,
            signer: signer,
            localCanStoreCarry: allowStoreCarry,
            maxPackets: maxPacketsPerLink,
            supportsRecipientProbe:
                candidate.advertisement.rendezvousId.startsWith('dtn-rp1-') ||
                candidate.advertisement.rendezvousId.startsWith('dtn-dx1-'),
            supportsDuplex: candidate.advertisement.rendezvousId.startsWith(
              'dtn-dx1-',
            ),
          );
          outboundAccepted += result.accepted;
          reverseAccepted += result.received;
          failedEncounters += result.failed;
        } catch (_) {
          failedEncounters++;
        }
      }
    } finally {
      await advertising.close();
      await incomingSubscription.cancel();
    }

    var inboundAccepted = reverseAccepted;
    for (final task in List<Future<int>>.from(inboundTasks)) {
      inboundAccepted += await task;
    }
    return LoomNearbyDtnRoundResult(
      discoveredCandidates: discovered,
      connectedCandidates: connected,
      outboundPacketsAccepted: outboundAccepted,
      inboundPacketsAccepted: inboundAccepted,
      failedEncounters: failedEncounters,
    );
  }

  static String _createRandomRendezvousId() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final random = Random.secure();
    return List<String>.generate(
      32,
      (_) => alphabet[random.nextInt(alphabet.length)],
      growable: false,
    ).join();
  }
}
