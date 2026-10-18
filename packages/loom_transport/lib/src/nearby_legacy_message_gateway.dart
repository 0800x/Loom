import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';

import 'direct_node_delivery.dart';
import 'nearby_dtn_peer_bootstrap.dart';
import 'nearby_transport.dart';

const _gatewayKind = 'nearby.legacy-message-gateway.request.v1';
const _responseKind = 'nearby.legacy-message-gateway.response.v1';
const _proofDomain = 'loom-nearby-message-gateway-v1';
const _rendezvousPrefix = 'msg-gw-v1-';

String _b64u(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

String _iso(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
      value.toUtc().millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map) throw FormatException('Invalid $label');
  return value.map((key, value) => MapEntry(key.toString(), value as Object?));
}

String _text(Object? value, String label, {int max = 512}) {
  if (value is! String ||
      value.trim() != value ||
      value.isEmpty ||
      value.length > max ||
      value.contains('\r') ||
      value.contains('\n') ||
      value.contains('\x00')) {
    throw FormatException('Invalid $label');
  }
  return value;
}

final class LoomNearbyLegacyMessageGateway {
  LoomNearbyLegacyMessageGateway({
    LoomNearbyDtnPeerBootstrap? bootstrap,
    LoomDirectHttpPoster? poster,
    Future<LoomWellKnownNode> Function(String domain)? discoverNode,
    DateTime Function()? clock,
  })  : bootstrap = bootstrap ?? LoomNearbyDtnPeerBootstrap(),
        poster = poster ?? LoomIoDirectHttpPoster(),
        _discoverNode = discoverNode ?? LoomNodeClient().discoverDomain,
        _clock = clock ?? DateTime.now;

  final LoomNearbyDtnPeerBootstrap bootstrap;
  final LoomDirectHttpPoster poster;
  final Future<LoomWellKnownNode> Function(String domain) _discoverNode;
  final DateTime Function() _clock;

  Future<LoomSendReceipt> sendViaRadio({
    required LoomNearbyRadioAdapter radio,
    required LoomNearbyBearer bearer,
    required LoomDirectTransportSigner signer,
    required String homeNodeDomain,
    required String accountId,
    required String identityId,
    required String deviceId,
    required String senderAddress,
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
    Duration scanTimeout = const Duration(seconds: 8),
  }) async {
    if (!radio.supportedBearers.contains(bearer)) {
      throw StateError('Nearby radio does not support ${bearer.name}');
    }
    Object? lastError;
    await for (final candidate in radio.scan(timeout: scanTimeout)) {
      if (candidate.bearer != bearer ||
          !candidate.advertisement.rendezvousId.startsWith(_rendezvousPrefix) ||
          !candidate.advertisement.expiresAt.isAfter(_clock().toUtc())) {
        continue;
      }
      try {
        final link = await radio.connect(candidate);
        return await forwardOverLink(
          link: link,
          signer: signer,
          homeNodeDomain: homeNodeDomain,
          accountId: accountId,
          identityId: identityId,
          deviceId: deviceId,
          senderAddress: senderAddress,
          conversationId: conversationId,
          clientId: clientId,
          type: type,
          ciphertext: ciphertext,
          protocolVersion: protocolVersion,
          replyToMessageId: replyToMessageId,
          metadata: metadata,
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? StateError('No Nearby Internet gateway was discovered');
  }

  Future<LoomSendReceipt> forwardOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    required String homeNodeDomain,
    required String accountId,
    required String identityId,
    required String deviceId,
    required String senderAddress,
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    LoomNearbyDtnPeerSession? session;
    try {
      session = await bootstrap.establishAsInitiator(
        link: link,
        signer: signer,
        canStoreCarry: false,
      );
      final request = await _signedRequest(
        signer: signer,
        homeNodeDomain: homeNodeDomain,
        accountId: accountId,
        identityId: identityId,
        deviceId: deviceId,
        senderAddress: senderAddress,
        conversationId: conversationId,
        clientId: clientId,
        type: type,
        ciphertext: ciphertext,
        protocolVersion: protocolVersion,
        replyToMessageId: replyToMessageId,
        metadata: metadata,
      );
      await _sendJson(session.connection, <String, Object?>{
        'kind': _gatewayKind,
        'version': 1,
        'request': request,
      });
      final response = await _receiveJson(session.connection);
      if (response['kind'] != _responseKind ||
          response['version'] != 1 ||
          response['statusCode'] is! int) {
        throw const FormatException('Invalid Nearby message gateway response');
      }
      final statusCode = response['statusCode'] as int;
      final body = _object(response['body'], 'Nearby message gateway receipt');
      if (statusCode != 200 && statusCode != 201) {
        final error = body['error'];
        throw LoomProtocolException(
          error is String && error.isNotEmpty
              ? error
              : 'Nearby message gateway rejected the send',
        );
      }
      return _receipt(body, clientId);
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

  Future<void> acceptOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
  }) async {
    LoomNearbyDtnPeerSession? session;
    try {
      session = await bootstrap.establishAsResponder(
        link: link,
        signer: signer,
        canStoreCarry: false,
      );
      final frame = await _receiveJson(session.connection);
      if (frame['kind'] != _gatewayKind || frame['version'] != 1) {
        throw const FormatException('Invalid Nearby message gateway request');
      }
      final request = _object(
        frame['request'],
        'Nearby message gateway request',
      );
      final domain = LoomAddress.normalizeHomeNode(
        _text(request['homeNodeDomain'], 'Home Node domain', max: 253),
      );
      final verifiedNode = await _discoverNode(domain);
      final response = await poster.postJson(
        _directMessageUri(verifiedNode.endpoint),
        request,
      );
      await _sendJson(session.connection, <String, Object?>{
        'kind': _responseKind,
        'version': 1,
        'statusCode': response.statusCode,
        'body': response.body ?? const <String, Object?>{},
      });
    } catch (error) {
      if (session != null) {
        try {
          await _sendJson(session.connection, <String, Object?>{
            'kind': _responseKind,
            'version': 1,
            'statusCode': 502,
            'body': const <String, Object?>{
              'error': 'nearby_gateway_uplink_failed',
            },
          });
        } catch (_) {}
      }
      rethrow;
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

  Future<Map<String, Object?>> _signedRequest({
    required LoomDirectTransportSigner signer,
    required String homeNodeDomain,
    required String accountId,
    required String identityId,
    required String deviceId,
    required String senderAddress,
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    required String? replyToMessageId,
    required Map<String, Object?> metadata,
  }) async {
    final domain = LoomAddress.normalizeHomeNode(homeNodeDomain);
    final payload = <String, Object?>{
      'conversationId': _text(conversationId, 'conversation id', max: 256),
      'clientId': _text(clientId, 'client id', max: 256),
      'type': type.name.toUpperCase(),
      'ciphertext': _text(ciphertext, 'ciphertext', max: 1024 * 1024),
      'protocolVersion': _text(protocolVersion, 'protocol version', max: 128),
      if (replyToMessageId != null)
        'replyToMessageId': _text(
          replyToMessageId,
          'reply message id',
          max: 256,
        ),
      'metadata': metadata,
    };
    final payloadBytes = utf8.encode(jsonEncode(payload));
    if (payloadBytes.length > 1024 * 1024) {
      throw const FormatException('Nearby message payload exceeds bounds');
    }
    final payloadBase64 = _b64u(payloadBytes);
    final publicKey = await signer.ed25519PublicKey();
    if (publicKey.length != 32) {
      throw const FormatException('Invalid Nearby message signing key');
    }
    final devicePublicKey = _b64u(publicKey);
    final issuedAt = _iso(_clock().toUtc());
    final nonce = _b64u(_randomBytes(24));
    final canonical = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<Object?>[
          _proofDomain,
          domain,
          _text(accountId, 'account id', max: 256),
          _text(identityId, 'identity id', max: 256),
          _text(deviceId, 'device id', max: 256),
          _text(senderAddress, 'sender address', max: 512),
          devicePublicKey,
          issuedAt,
          nonce,
          payloadBase64,
        ]),
      ),
    );
    final signature = await signer.sign(canonical);
    if (signature.length != 64) {
      throw const FormatException('Invalid Nearby message signature');
    }
    return <String, Object?>{
      'homeNodeDomain': domain,
      'accountId': accountId,
      'identityId': identityId,
      'deviceId': deviceId,
      'senderAddress': senderAddress,
      'payloadBase64': payloadBase64,
      'transportProof': <String, Object?>{
        'devicePublicKey': devicePublicKey,
        'issuedAt': issuedAt,
        'nonce': nonce,
        'signature': _b64u(signature),
      },
    };
  }

  static LoomSendReceipt _receipt(
    Map<String, Object?> body,
    String expectedClientId,
  ) {
    final messageId = _text(body['messageId'], 'message id', max: 256);
    final clientId = _text(body['clientId'], 'client id', max: 256);
    final serverOrder = body['serverOrder'];
    final createdAtRaw = body['createdAt'];
    final createdAt = createdAtRaw is String
        ? DateTime.tryParse(createdAtRaw)?.toUtc()
        : null;
    if (clientId != expectedClientId ||
        serverOrder is! int ||
        serverOrder < 0 ||
        createdAt == null) {
      throw const FormatException('Invalid Nearby message send receipt');
    }
    return LoomSendReceipt(
      messageId: messageId,
      clientId: clientId,
      serverOrder: serverOrder,
      createdAt: createdAt,
    );
  }

  static Uri _directMessageUri(Uri endpoint) {
    final basePath = endpoint.path.isEmpty
        ? '/'
        : endpoint.path.endsWith('/')
            ? endpoint.path
            : '${endpoint.path}/';
    return endpoint.replace(
      path: '${basePath}api/v1/messages/direct',
      query: null,
      fragment: null,
    );
  }
}

final class LoomNearbyLegacyMessageGatewayRoundRunner {
  LoomNearbyLegacyMessageGatewayRoundRunner({
    required this.gateway,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LoomNearbyLegacyMessageGateway gateway;
  final DateTime Function() _clock;

  Future<int> run({
    required LoomNearbyRadioAdapter radio,
    required LoomNearbyBearer bearer,
    required LoomDirectTransportSigner signer,
    Duration lifetime = const Duration(seconds: 5),
    int maxConcurrentLinks = 4,
  }) async {
    if (!radio.supportedBearers.contains(bearer)) {
      throw StateError('Nearby radio does not support ${bearer.name}');
    }
    if (lifetime <= Duration.zero) {
      throw ArgumentError.value(lifetime, 'lifetime');
    }
    final advertisement = LoomNearbyAdvertisement(
      protocolVersion: 1,
      rendezvousId: '$_rendezvousPrefix${_b64u(_randomBytes(18))}',
      bearers: <LoomNearbyBearer>[bearer],
      expiresAt: _clock().toUtc().add(lifetime + const Duration(seconds: 2)),
    );
    final advertising = await radio.advertise(advertisement);
    final tasks = <Future<void>>[];
    var accepted = 0;
    final subscription = advertising.incomingLinks.listen((link) {
      if (tasks.length >= maxConcurrentLinks) {
        unawaited(link.close());
        return;
      }
      late final Future<void> task;
      task = gateway
          .acceptOverLink(link: link, signer: signer)
          .then<void>((_) {
            accepted++;
          })
          .catchError((Object _) {})
          .whenComplete(() {
            tasks.remove(task);
          });
      tasks.add(task);
    });
    try {
      await Future<void>.delayed(lifetime);
    } finally {
      await advertising.close();
      await subscription.cancel();
    }
    await Future.wait(List<Future<void>>.from(tasks));
    return accepted;
  }
}

Future<void> _sendJson(
  LoomNearbySecureConnection connection,
  Map<String, Object?> value,
) =>
    connection.send(utf8.encode(jsonEncode(value)));

Future<Map<String, Object?>> _receiveJson(
  LoomNearbySecureConnection connection, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final bytes = await connection.receive(timeout: timeout);
  if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
    throw const FormatException('Nearby message gateway frame exceeds bounds');
  }
  final decoded = jsonDecode(utf8.decode(bytes));
  return _object(decoded, 'Nearby message gateway frame');
}
