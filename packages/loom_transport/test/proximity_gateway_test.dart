import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_transport/loom_transport.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

final class _Signer implements LoomDirectTransportSigner {
  _Signer(this.keyPair, this.publicKey);

  final KeyPair keyPair;
  final SimplePublicKey publicKey;

  static Future<_Signer> create() async {
    final algorithm = Ed25519();
    final pair = await algorithm.newKeyPair();
    final public = await pair.extractPublicKey();
    return _Signer(pair, public);
  }

  @override
  Future<Uint8List> ed25519PublicKey() async =>
      Uint8List.fromList(publicKey.bytes);

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async {
    final signature = await Ed25519().sign(canonicalBytes, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }
}

void main() {
  test('recipient lease binds destination and both ephemeral keys', () async {
    final signer = await _Signer.create();
    final gateway = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final gatewayEphemeral = Uint8List.fromList(
      List<int>.generate(32, (i) => 100 + i),
    );
    final recipientEphemeral = Uint8List.fromList(
      List<int>.generate(32, (i) => 200 + i),
    );
    final now = DateTime.utc(2026, 9, 7, 12);

    final lease = await LoomProximityGatewayLease.create(
      recipientSigner: signer,
      sessionId: 'session-test-0123456789',
      recipientIdentityId: 'chn:recipient-test',
      recipientDeviceId: 'device-recipient-012345',
      recipientNodeId: 'node:test-node-012345',
      recipientNodeDomain: 'chat.example.test',
      gatewayDevicePublicKey: gateway,
      gatewayEphemeralPublicKey: gatewayEphemeral,
      recipientEphemeralPublicKey: recipientEphemeral,
      bearer: LoomProximityGatewayBearer.ble,
      now: now,
    );

    expect(lease.recipientNodeDomain, 'chat.example.test');
    expect(
      lease.gatewayEphemeralPublicKey,
      base64UrlEncode(gatewayEphemeral).replaceAll('=', ''),
    );
    expect(
      lease.recipientEphemeralPublicKey,
      base64UrlEncode(recipientEphemeral).replaceAll('=', ''),
    );
    expect(
      lease.expiresAt.difference(lease.issuedAt),
      const Duration(seconds: 90),
    );

    final signature = base64Url.decode(base64Url.normalize(lease.signature));
    final valid = await Ed25519().verify(
      lease.canonicalBytes(),
      signature: Signature(signature, publicKey: signer.publicKey),
    );
    expect(valid, isTrue);

    final json = lease.toJson();
    expect(LoomProximityGatewayLease.fromJson(json).sessionId, lease.sessionId);
  });

  test('lease rejects unsafe lifetime', () async {
    final signer = await _Signer.create();
    final bytes = Uint8List(32);
    await expectLater(
      LoomProximityGatewayLease.create(
        recipientSigner: signer,
        sessionId: 'session-test-0123456789',
        recipientIdentityId: 'chn:recipient-test',
        recipientDeviceId: 'device-recipient-012345',
        recipientNodeId: 'node:test-node-012345',
        recipientNodeDomain: 'chat.example.test',
        gatewayDevicePublicKey: bytes,
        gatewayEphemeralPublicKey: bytes,
        recipientEphemeralPublicKey: bytes,
        bearer: LoomProximityGatewayBearer.ble,
        lifetime: const Duration(minutes: 3),
      ),
      throwsFormatException,
    );
  });

  test('offline round advertises without scanning and holds the window', () async {
    final radio = _ScriptedRadio();
    final runner = LoomProximityGatewayRoundRunner(
      clock: () => DateTime.utc(2026, 11, 8, 12),
      rendezvousIdFactory: () => 'offline-rendezvous-0123456789',
    );
    final watch = Stopwatch()..start();
    final result = await runner.run(
      radio: radio,
      bearer: LoomNearbyBearer.bluetoothLowEnergy,
      signer: await _Signer.create(),
      recipientIdentityId: 'chn:recipient-test',
      recipientDeviceId: 'device-recipient-012345',
      recipientNodeId: 'node:test-node-012345',
      recipientNodeDomain: 'chat.example.test',
      acceptLegacyDelivery: (_) async => false,
      hasInternetUpstream: false,
      advertisementLifetime: const Duration(milliseconds: 150),
      scanTimeout: const Duration(seconds: 30),
    );
    watch.stop();

    expect(radio.advertiseCalls, 1);
    expect(radio.scanCalls, 0);
    expect(radio.session.closed, isTrue);
    expect(
      radio.advertisement!.rendezvousId,
      'pg1-offline-rendezvous-0123456789',
    );
    // The accept window must span the full declared lifetime.
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(140));
    expect(result.discoveredCandidates, 0);
    expect(result.inboundSessions, 0);
  });

  test('offline round yields the radio when a priority signal fires', () async {
    final radio = _ScriptedRadio();
    final yieldSignal = Completer<void>();
    final runner = LoomProximityGatewayRoundRunner(
      clock: () => DateTime.utc(2026, 11, 8, 12),
    );
    final watch = Stopwatch()..start();
    final running = runner.run(
      radio: radio,
      bearer: LoomNearbyBearer.bluetoothLowEnergy,
      signer: await _Signer.create(),
      recipientIdentityId: 'chn:recipient-test',
      recipientDeviceId: 'device-recipient-012345',
      recipientNodeId: 'node:test-node-012345',
      recipientNodeDomain: 'chat.example.test',
      acceptLegacyDelivery: (_) async => false,
      hasInternetUpstream: false,
      yieldSignal: yieldSignal.future,
      advertisementLifetime: const Duration(seconds: 20),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    yieldSignal.complete();
    await running;
    watch.stop();

    expect(radio.advertiseCalls, 1);
    expect(radio.session.closed, isTrue);
    // Far below the 20-second window: the passive advertisement is aborted.
    expect(watch.elapsedMilliseconds, lessThan(5000));
  });

  test('online round scans for recipients without advertising', () async {
    final radio = _ScriptedRadio();
    final runner = LoomProximityGatewayRoundRunner(
      clock: () => DateTime.utc(2026, 11, 8, 12),
    );
    final result = await runner.run(
      radio: radio,
      bearer: LoomNearbyBearer.bluetoothLowEnergy,
      signer: await _Signer.create(),
      recipientIdentityId: 'chn:recipient-test',
      recipientDeviceId: 'device-recipient-012345',
      recipientNodeId: 'node:test-node-012345',
      recipientNodeDomain: 'chat.example.test',
      acceptLegacyDelivery: (_) async => false,
      hasInternetUpstream: true,
      scanTimeout: const Duration(milliseconds: 40),
      advertisementLifetime: const Duration(seconds: 20),
    );

    expect(radio.advertiseCalls, 0);
    expect(radio.scanCalls, 1);
    expect(result.discoveredCandidates, 0);
    expect(result.failedEncounters, 0);
  });

  test('unknown connectivity keeps both roles for the full window', () async {
    final radio = _ScriptedRadio();
    final runner = LoomProximityGatewayRoundRunner(
      clock: () => DateTime.utc(2026, 11, 8, 12),
    );
    final watch = Stopwatch()..start();
    await runner.run(
      radio: radio,
      bearer: LoomNearbyBearer.bluetoothLowEnergy,
      signer: await _Signer.create(),
      recipientIdentityId: 'chn:recipient-test',
      recipientDeviceId: 'device-recipient-012345',
      recipientNodeId: 'node:test-node-012345',
      recipientNodeDomain: 'chat.example.test',
      acceptLegacyDelivery: (_) async => false,
      scanTimeout: const Duration(milliseconds: 30),
      advertisementLifetime: const Duration(milliseconds: 160),
    );
    watch.stop();

    expect(radio.advertiseCalls, 1);
    expect(radio.scanCalls, 1);
    // The advertisement must outlive the short scan, not close with it.
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(150));
    expect(radio.session.closed, isTrue);
  });
}

final class _ScriptedRadio implements LoomNearbyRadioAdapter {
  final _ScriptedAdvertisingSession session = _ScriptedAdvertisingSession();
  int advertiseCalls = 0;
  int scanCalls = 0;
  LoomNearbyAdvertisement? advertisement;

  @override
  Set<LoomNearbyBearer> get supportedBearers => const <LoomNearbyBearer>{
    LoomNearbyBearer.bluetoothLowEnergy,
  };

  @override
  Future<LoomNearbyAdvertisingSession> advertise(
    LoomNearbyAdvertisement advertisement,
  ) async {
    advertiseCalls++;
    this.advertisement = advertisement;
    return session;
  }

  @override
  Stream<LoomNearbyCandidate> scan({
    Duration timeout = const Duration(seconds: 8),
  }) {
    scanCalls++;
    return const Stream<LoomNearbyCandidate>.empty();
  }

  @override
  Future<LoomNearbyLink> connect(LoomNearbyCandidate candidate) =>
      throw StateError('no candidate expected');
}

final class _ScriptedAdvertisingSession
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
