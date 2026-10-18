import 'dart:async';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  test('DTN round advertises only short-lived rendezvous metadata', () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final coordinator = LoomNearbyDtnEncounterCoordinator(
      packetStore: store,
      transferExecutor: LoomDtnTransferExecutor(
        packetStore: store,
        transferStore: store,
      ),
      durablyAccept: ({
        required transmissionId,
        required exactOuterEnvelopeBytes,
      }) =>
          throw StateError('no incoming links expected'),
    );
    final radio = _RecordingRadio();
    final now = DateTime.utc(2026, 9, 10, 12);
    final runner = LoomNearbyDtnRoundRunner(
      coordinator: coordinator,
      signer: _UnusedSigner(),
      clock: () => now,
      rendezvousIdFactory: () => 'ephemeral-rendezvous-id-12345678',
    );

    final result = await runner.run(
      radio: radio,
      bearer: LoomNearbyBearer.bluetoothLowEnergy,
      allowStoreCarry: true,
      scanTimeout: const Duration(milliseconds: 1),
      advertisementLifetime: const Duration(seconds: 15),
    );

    expect(result.discoveredCandidates, 0);
    expect(result.connectedCandidates, 0);
    expect(result.outboundPacketsAccepted, 0);
    expect(result.inboundPacketsAccepted, 0);
    expect(result.failedEncounters, 0);
    expect(radio.advertisement, isNotNull);
    expect(
      radio.advertisement!.rendezvousId,
      'dtn-dx1-ephemeral-rendezvous-id-12345678',
    );
    expect(radio.advertisement!.bearers, <LoomNearbyBearer>[
      LoomNearbyBearer.bluetoothLowEnergy,
    ]);
    expect(
      radio.advertisement!.expiresAt,
      now.add(const Duration(seconds: 15)),
    );
    final wire = radio.advertisement!.toJson().toString().toLowerCase();
    expect(wire, isNot(contains('username')));
    expect(wire, isNot(contains('address')));
    expect(wire, isNot(contains('node')));
    expect(wire, isNot(contains('deviceid')));
    expect(radio.session.closed, isTrue);
  });
}

final class _RecordingRadio implements LoomNearbyRadioAdapter {
  LoomNearbyAdvertisement? advertisement;
  final _RecordingAdvertisingSession session = _RecordingAdvertisingSession();

  @override
  Set<LoomNearbyBearer> get supportedBearers => const <LoomNearbyBearer>{
        LoomNearbyBearer.bluetoothLowEnergy,
      };

  @override
  Future<LoomNearbyAdvertisingSession> advertise(
    LoomNearbyAdvertisement advertisement,
  ) async {
    this.advertisement = advertisement;
    return session;
  }

  @override
  Stream<LoomNearbyCandidate> scan({
    Duration timeout = const Duration(seconds: 8),
  }) =>
      const Stream<LoomNearbyCandidate>.empty();

  @override
  Future<LoomNearbyLink> connect(LoomNearbyCandidate candidate) =>
      throw StateError('no candidate expected');
}

final class _RecordingAdvertisingSession
    implements LoomNearbyAdvertisingSession {
  final StreamController<LoomNearbyLink> _incoming =
      StreamController<LoomNearbyLink>.broadcast();
  bool closed = false;

  @override
  Stream<LoomNearbyLink> get incomingLinks => _incoming.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }
}

final class _UnusedSigner implements LoomDirectTransportSigner {
  @override
  Future<Uint8List> ed25519PublicKey() =>
      throw StateError('signer should not be used');

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) =>
      throw StateError('signer should not be used');
}
