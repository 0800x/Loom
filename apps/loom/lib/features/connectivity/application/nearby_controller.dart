import 'dart:convert';
import 'dart:math';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_transport/loom_transport.dart';

class LoomAuthenticatedNearbyPeer {
  LoomAuthenticatedNearbyPeer({
    required this.remoteDevice,
    required this.connection,
    required this.bearer,
  });

  final LoomDeviceKeyBundle remoteDevice;
  final LoomNearbySecureConnection connection;
  final LoomNearbyBearer bearer;
}

/// Nearby orchestration is deliberately contact-targeted. A pairwise rotating
/// rendezvous token is derived from the two trusted device agreement keys, so
/// ordinary advertisements do not reveal a stable Loom identity.
class LoomNearbyController {
  LoomNearbyController({
    required this.radio,
    required this.localDevice,
    required this.deviceSecurity,
    Random? random,
  }) : _random = random ?? Random.secure();

  final LoomNearbyRadioAdapter radio;
  final LoomDeviceKeyBundle localDevice;
  final LoomDeviceSecurityCore deviceSecurity;
  final Random _random;

  LoomNearbyPairAuthenticator get _pairAuth => LoomNearbyPairAuthenticator(
    localDevice: localDevice,
    deviceSecurity: deviceSecurity,
  );

  Stream<LoomNearbyCandidate> discoverFor({
    required LoomDeviceKeyBundle remoteDevice,
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    final expected = await _pairAuth.acceptedRendezvousIds(
      remoteDevice: remoteDevice,
    );
    await for (final candidate in radio.scan(timeout: timeout)) {
      if (expected.contains(candidate.advertisement.rendezvousId) &&
          candidate.advertisement.expiresAt.isAfter(DateTime.now().toUtc())) {
        yield candidate;
      }
    }
  }

  Future<LoomAuthenticatedNearbyPeer> connect({
    required LoomNearbyCandidate candidate,
    required LoomDeviceKeyBundle remoteDevice,
  }) async {
    final expectedIds = await _pairAuth.acceptedRendezvousIds(
      remoteDevice: remoteDevice,
    );
    if (!expectedIds.contains(candidate.advertisement.rendezvousId)) {
      throw const FormatException(
        'Nearby candidate does not match trusted peer rendezvous',
      );
    }
    final link = await radio.connect(candidate);
    try {
      final sessionId = _sessionId();
      final preAuth = await _pairAuth.create(
        remoteDevice: remoteDevice,
        sessionId: sessionId,
        rendezvousId: candidate.advertisement.rendezvousId,
        role: LoomNearbyHandshakeRole.initiator,
      );
      await link.send(
        utf8.encode(
          jsonEncode(<String, Object?>{'kind': 'preauth', ...preAuth.toJson()}),
        ),
      );

      final responderPreAuth = _parsePreAuth(
        await link.receive(timeout: const Duration(seconds: 8)),
      );
      final validPreAuth = await _pairAuth.verify(
        packet: responderPreAuth,
        remoteDevice: remoteDevice,
        expectedRole: LoomNearbyHandshakeRole.responder,
        expectedPeerNonce: preAuth.nonce,
      );
      if (!validPreAuth || responderPreAuth.sessionId != sessionId) {
        throw const FormatException('Nearby peer pre-authentication failed');
      }

      final context = await LoomNearbyHandshakeContext.create(
        sessionId: sessionId,
        role: LoomNearbyHandshakeRole.initiator,
        localDevice: localDevice,
        deviceSecurity: deviceSecurity,
      );
      await link.send(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'kind': 'hello',
            ...context.localHello.toJson(),
          }),
        ),
      );
      final remoteHello = _parseHello(
        await link.receive(timeout: const Duration(seconds: 8)),
      );
      final cipher = await context.acceptRemote(
        remote: remoteHello,
        expectedRemoteDevice: remoteDevice,
      );
      return LoomAuthenticatedNearbyPeer(
        remoteDevice: remoteDevice,
        bearer: link.bearer,
        connection: LoomNearbySecureConnection(
          link: link,
          seal: cipher.seal,
          open: cipher.open,
        ),
      );
    } catch (_) {
      await link.close();
      rethrow;
    }
  }

  Future<LoomNearbyAdvertisingSession> advertiseFor({
    required LoomDeviceKeyBundle remoteDevice,
    Duration lifetime = const Duration(minutes: 5),
  }) async {
    if (lifetime.compareTo(const Duration(minutes: 1)) < 0 ||
        lifetime.compareTo(const Duration(minutes: 5)) > 0) {
      throw ArgumentError.value(
        lifetime,
        'lifetime',
        'must be between 1 and 5 minutes',
      );
    }
    final rendezvousId = await _pairAuth.currentRendezvousId(
      remoteDevice: remoteDevice,
    );
    return radio.advertise(
      LoomNearbyAdvertisement(
        protocolVersion: 1,
        rendezvousId: rendezvousId,
        bearers: radio.supportedBearers.toList(growable: false),
        expiresAt: DateTime.now().toUtc().add(lifetime),
      ),
    );
  }

  /// Accepts a link from an advertising session that was explicitly created for
  /// [remoteDevice]. This target binding is what lets pre-auth happen before
  /// stable identity fields are disclosed.
  Future<LoomAuthenticatedNearbyPeer> accept({
    required LoomNearbyLink link,
    required LoomDeviceKeyBundle remoteDevice,
  }) async {
    try {
      final initiatorPreAuth = _parsePreAuth(
        await link.receive(timeout: const Duration(seconds: 8)),
      );
      final validInitiator = await _pairAuth.verify(
        packet: initiatorPreAuth,
        remoteDevice: remoteDevice,
        expectedRole: LoomNearbyHandshakeRole.initiator,
      );
      if (!validInitiator) {
        throw const FormatException(
          'Nearby initiator pre-authentication failed',
        );
      }

      final responderPreAuth = await _pairAuth.create(
        remoteDevice: remoteDevice,
        sessionId: initiatorPreAuth.sessionId,
        rendezvousId: initiatorPreAuth.rendezvousId,
        role: LoomNearbyHandshakeRole.responder,
        peerNonce: initiatorPreAuth.nonce,
      );
      await link.send(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'kind': 'preauth',
            ...responderPreAuth.toJson(),
          }),
        ),
      );

      final initiatorHello = _parseHello(
        await link.receive(timeout: const Duration(seconds: 8)),
      );
      final context = await LoomNearbyHandshakeContext.create(
        sessionId: initiatorPreAuth.sessionId,
        role: LoomNearbyHandshakeRole.responder,
        localDevice: localDevice,
        deviceSecurity: deviceSecurity,
      );
      await link.send(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'kind': 'hello',
            ...context.localHello.toJson(),
          }),
        ),
      );
      final cipher = await context.acceptRemote(
        remote: initiatorHello,
        expectedRemoteDevice: remoteDevice,
      );
      return LoomAuthenticatedNearbyPeer(
        remoteDevice: remoteDevice,
        bearer: link.bearer,
        connection: LoomNearbySecureConnection(
          link: link,
          seal: cipher.seal,
          open: cipher.open,
        ),
      );
    } catch (_) {
      await link.close();
      rethrow;
    }
  }

  LoomNearbyPreAuth _parsePreAuth(List<int> bytes) {
    final decoded = _decodeHandshakeObject(bytes, 'preauth');
    return LoomNearbyPreAuth.fromJson(decoded);
  }

  LoomNearbyHello _parseHello(List<int> bytes) {
    final decoded = _decodeHandshakeObject(bytes, 'hello');
    return LoomNearbyHello.fromJson(decoded);
  }

  Map<String, Object?> _decodeHandshakeObject(
    List<int> bytes,
    String expectedKind,
  ) {
    if (bytes.isEmpty || bytes.length > 16 * 1024) {
      throw const FormatException('Nearby handshake frame exceeds bounds');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?> || decoded['kind'] != expectedKind) {
      throw FormatException('Expected nearby $expectedKind frame');
    }
    final copy = Map<String, Object?>.from(decoded)..remove('kind');
    return copy;
  }

  String _sessionId() {
    final bytes = List<int>.generate(18, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
