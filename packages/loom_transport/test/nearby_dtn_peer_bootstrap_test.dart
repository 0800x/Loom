import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 10, 10);

  test(
    'nearby DTN peers mutually authenticate and derive a secure link',
    () async {
      final pair = _DuplexNearbyPair();
      final initiatorSigner = await _CryptoSigner.create();
      final responderSigner = await _CryptoSigner.create();
      final bootstrap = LoomNearbyDtnPeerBootstrap(clock: () => now);

      final responderFuture = bootstrap.establishAsResponder(
        link: pair.right,
        signer: responderSigner,
        canStoreCarry: true,
      );
      final initiatorFuture = bootstrap.establishAsInitiator(
        link: pair.left,
        signer: initiatorSigner,
        canStoreCarry: true,
      );

      final initiator = await initiatorFuture;
      final responder = await responderFuture;
      addTearDown(initiator.connection.close);
      addTearDown(responder.connection.close);

      expect(initiator.opportunity.authenticated, isTrue);
      expect(initiator.opportunity.canStoreCarry, isTrue);
      expect(initiator.opportunity.directRecipient, isFalse);
      expect(initiator.opportunity.gatewayClaim, LoomGatewayClaimState.none);
      expect(responder.opportunity.authenticated, isTrue);
      expect(responder.opportunity.gatewayClaim, LoomGatewayClaimState.none);
      expect(initiator.remoteFingerprint, isNot(responder.remoteFingerprint));

      await initiator.connection.send(<int>[10, 20, 30, 40]);
      expect(await responder.connection.receive(), <int>[10, 20, 30, 40]);

      await responder.connection.send(<int>[50, 60]);
      expect(await initiator.connection.receive(), <int>[50, 60]);
    },
  );

  test(
    'peer relay consent is authenticated but never grants gateway trust',
    () async {
      final pair = _DuplexNearbyPair();
      final initiatorSigner = await _CryptoSigner.create();
      final responderSigner = await _CryptoSigner.create();
      final bootstrap = LoomNearbyDtnPeerBootstrap(clock: () => now);

      final responderFuture = bootstrap.establishAsResponder(
        link: pair.right,
        signer: responderSigner,
        canStoreCarry: false,
      );
      final initiatorFuture = bootstrap.establishAsInitiator(
        link: pair.left,
        signer: initiatorSigner,
        canStoreCarry: true,
      );

      final initiator = await initiatorFuture;
      final responder = await responderFuture;
      addTearDown(initiator.connection.close);
      addTearDown(responder.connection.close);

      expect(initiator.opportunity.canStoreCarry, isFalse);
      expect(initiator.opportunity.gatewayClaim, LoomGatewayClaimState.none);
      expect(initiator.opportunity.directRecipient, isFalse);
      expect(responder.opportunity.canStoreCarry, isTrue);
      expect(responder.opportunity.gatewayClaim, LoomGatewayClaimState.none);
    },
  );
}

final class _CryptoSigner implements LoomDirectTransportSigner {
  _CryptoSigner(this._keyPair);

  final KeyPair _keyPair;
  static final Ed25519 _algorithm = Ed25519();

  static Future<_CryptoSigner> create() async =>
      _CryptoSigner(await _algorithm.newKeyPair());

  @override
  Future<Uint8List> ed25519PublicKey() async => Uint8List.fromList(
        (await _keyPair.extractPublicKey() as SimplePublicKey).bytes,
      );

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async => Uint8List.fromList(
        (await _algorithm.sign(canonicalBytes, keyPair: _keyPair)).bytes,
      );
}

final class _DuplexNearbyPair {
  _DuplexNearbyPair() {
    left = _DuplexNearbyLink(_rightIncoming);
    right = _DuplexNearbyLink(_leftIncoming);
    left._incoming = _leftIncoming;
    right._incoming = _rightIncoming;
  }

  final Queue<List<int>> _leftIncoming = Queue<List<int>>();
  final Queue<List<int>> _rightIncoming = Queue<List<int>>();
  late final _DuplexNearbyLink left;
  late final _DuplexNearbyLink right;
}

final class _DuplexNearbyLink implements LoomNearbyLink {
  _DuplexNearbyLink(this._remoteIncoming);

  Queue<List<int>> _incoming = Queue<List<int>>();
  final Queue<List<int>> _remoteIncoming;
  bool _closed = false;

  @override
  LoomNearbyBearer get bearer => LoomNearbyBearer.localPeer;

  @override
  Future<List<int>> receive({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!_closed && _incoming.isEmpty) {
      if (!DateTime.now().isBefore(deadline)) {
        throw TimeoutException('duplex nearby timeout', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (_closed) throw StateError('duplex nearby link is closed');
    return List<int>.from(_incoming.removeFirst());
  }

  @override
  Future<void> send(List<int> bytes) async {
    if (_closed) throw StateError('duplex nearby link is closed');
    _remoteIncoming.add(List<int>.from(bytes));
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
