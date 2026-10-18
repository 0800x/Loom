import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';

import 'direct_node_delivery.dart';
import 'nearby_transport.dart';

const _leaseDomain = 'loom-proximity-gateway-lease-v1';
const _proofDomain = 'loom-proximity-gateway-proof-v1';
const _nearbyLeaseKind = 'proximity.gateway.lease.v1';
const _nearbyPacketKind = 'proximity.gateway.packet.v1';
const _nearbyPacketAckKind = 'proximity.gateway.packet-ack.v1';
const _nearbyLegacyKind = 'proximity.gateway.legacy-event.v1';
const _nearbyLegacyAckKind = 'proximity.gateway.legacy-event-ack.v1';

String _b64u(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
String _iso(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
      value.toUtc().millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();

Uint8List _nonce([int length = 24]) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Future<String> _fingerprint(Uint8List publicKey) async {
  if (publicKey.length != 32) {
    throw const FormatException('Gateway Ed25519 public key must be 32 bytes');
  }
  return _b64u((await Sha256().hash(publicKey)).bytes);
}

enum LoomProximityGatewayBearer { ble, wifiDirect, wifiAware }

extension LoomProximityGatewayBearerWire on LoomProximityGatewayBearer {
  String get wireName => switch (this) {
        LoomProximityGatewayBearer.ble => 'ble',
        LoomProximityGatewayBearer.wifiDirect => 'wifi-direct',
        LoomProximityGatewayBearer.wifiAware => 'wifi-aware',
      };
}

final class LoomProximityGatewayLease {
  const LoomProximityGatewayLease({
    required this.leaseId,
    required this.sessionId,
    required this.recipientIdentityId,
    required this.recipientDeviceId,
    required this.recipientNodeId,
    required this.recipientNodeDomain,
    required this.gatewayDevicePublicKey,
    required this.gatewayFingerprint,
    required this.gatewayEphemeralPublicKey,
    required this.recipientEphemeralPublicKey,
    required this.bearer,
    required this.issuedAt,
    required this.expiresAt,
    required this.nonce,
    required this.maxPackets,
    required this.maxBytes,
    required this.signature,
  });

  final String leaseId;
  final String sessionId;
  final String recipientIdentityId;
  final String recipientDeviceId;
  final String recipientNodeId;
  final String recipientNodeDomain;
  final String gatewayDevicePublicKey;
  final String gatewayFingerprint;
  final String gatewayEphemeralPublicKey;
  final String recipientEphemeralPublicKey;
  final LoomProximityGatewayBearer bearer;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String nonce;
  final int maxPackets;
  final int maxBytes;
  final String signature;

  Uint8List canonicalBytes() => Uint8List.fromList(
        utf8.encode(
          jsonEncode(<Object?>[
            _leaseDomain,
            1,
            leaseId,
            sessionId,
            recipientIdentityId,
            recipientDeviceId,
            recipientNodeId,
            recipientNodeDomain,
            gatewayDevicePublicKey,
            gatewayFingerprint,
            gatewayEphemeralPublicKey,
            recipientEphemeralPublicKey,
            bearer.wireName,
            _iso(issuedAt),
            _iso(expiresAt),
            nonce,
            maxPackets,
            maxBytes,
          ]),
        ),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'leaseId': leaseId,
        'sessionId': sessionId,
        'recipientIdentityId': recipientIdentityId,
        'recipientDeviceId': recipientDeviceId,
        'recipientNodeId': recipientNodeId,
        'recipientNodeDomain': recipientNodeDomain,
        'gatewayDevicePublicKey': gatewayDevicePublicKey,
        'gatewayFingerprint': gatewayFingerprint,
        'gatewayEphemeralPublicKey': gatewayEphemeralPublicKey,
        'recipientEphemeralPublicKey': recipientEphemeralPublicKey,
        'bearer': bearer.wireName,
        'issuedAt': _iso(issuedAt),
        'expiresAt': _iso(expiresAt),
        'nonce': nonce,
        'maxPackets': maxPackets,
        'maxBytes': maxBytes,
        'signature': signature,
      };

  factory LoomProximityGatewayLease.fromJson(Map<String, Object?> json) {
    String string(String key, {int max = 512}) {
      final value = json[key];
      if (value is! String ||
          value.trim() != value ||
          value.isEmpty ||
          value.length > max ||
          value.contains(RegExp(r'[\r\n\x00]'))) {
        throw FormatException('Invalid proximity lease $key');
      }
      return value;
    }

    if (json['version'] != 1) {
      throw const FormatException('Unsupported proximity lease version');
    }
    final issuedAt = DateTime.tryParse(string('issuedAt', max: 64))?.toUtc();
    final expiresAt = DateTime.tryParse(string('expiresAt', max: 64))?.toUtc();
    if (issuedAt == null || expiresAt == null) {
      throw const FormatException('Invalid proximity lease timestamps');
    }
    final bearer = switch (string('bearer', max: 32)) {
      'ble' => LoomProximityGatewayBearer.ble,
      'wifi-direct' => LoomProximityGatewayBearer.wifiDirect,
      'wifi-aware' => LoomProximityGatewayBearer.wifiAware,
      _ => throw const FormatException('Invalid proximity lease bearer'),
    };
    final maxPackets = json['maxPackets'];
    final maxBytes = json['maxBytes'];
    if (maxPackets is! int ||
        maxPackets < 1 ||
        maxPackets > 50 ||
        maxBytes is! int ||
        maxBytes < 1024 ||
        maxBytes > 1024 * 1024) {
      throw const FormatException('Invalid proximity lease limits');
    }
    return LoomProximityGatewayLease(
      leaseId: string('leaseId', max: 128),
      sessionId: string('sessionId', max: 128),
      recipientIdentityId: string('recipientIdentityId', max: 128),
      recipientDeviceId: string('recipientDeviceId', max: 256),
      recipientNodeId: string('recipientNodeId', max: 256),
      recipientNodeDomain: string(
        'recipientNodeDomain',
        max: 253,
      ).toLowerCase(),
      gatewayDevicePublicKey: string('gatewayDevicePublicKey', max: 128),
      gatewayFingerprint: string('gatewayFingerprint', max: 128),
      gatewayEphemeralPublicKey: string('gatewayEphemeralPublicKey', max: 128),
      recipientEphemeralPublicKey: string(
        'recipientEphemeralPublicKey',
        max: 128,
      ),
      bearer: bearer,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      nonce: string('nonce', max: 128),
      maxPackets: maxPackets,
      maxBytes: maxBytes,
      signature: string('signature', max: 256),
    );
  }

  static Future<LoomProximityGatewayLease> create({
    required LoomDirectTransportSigner recipientSigner,
    required String sessionId,
    required String recipientIdentityId,
    required String recipientDeviceId,
    required String recipientNodeId,
    required String recipientNodeDomain,
    required Uint8List gatewayDevicePublicKey,
    required Uint8List gatewayEphemeralPublicKey,
    required Uint8List recipientEphemeralPublicKey,
    required LoomProximityGatewayBearer bearer,
    Duration lifetime = const Duration(seconds: 90),
    int maxPackets = 20,
    int maxBytes = 512 * 1024,
    DateTime? now,
  }) async {
    if (sessionId.length < 8 || sessionId.length > 128) {
      throw const FormatException('Invalid gateway Nearby session id');
    }
    if (!recipientNodeId.startsWith('node:') || recipientNodeId.length > 256) {
      throw const FormatException('Invalid recipient destination node id');
    }
    final domain = recipientNodeDomain.trim().toLowerCase();
    if (domain != recipientNodeDomain ||
        domain.contains('://') ||
        domain.contains('/') ||
        domain.contains(':') ||
        domain.length > 253 ||
        !domain.contains('.')) {
      throw const FormatException('Invalid recipient destination node domain');
    }
    if (gatewayDevicePublicKey.length != 32 ||
        gatewayEphemeralPublicKey.length != 32 ||
        recipientEphemeralPublicKey.length != 32) {
      throw const FormatException(
        'Invalid gateway bootstrap public key material',
      );
    }
    if (lifetime <= Duration.zero || lifetime > const Duration(minutes: 2)) {
      throw const FormatException(
        'Gateway lease lifetime must be 1..120 seconds',
      );
    }
    if (maxPackets < 1 ||
        maxPackets > 50 ||
        maxBytes < 1024 ||
        maxBytes > 1024 * 1024) {
      throw const FormatException('Invalid gateway lease quota');
    }
    final current = (now ?? DateTime.now()).toUtc();
    final unsigned = LoomProximityGatewayLease(
      leaseId: _b64u(_nonce()),
      sessionId: sessionId,
      recipientIdentityId: recipientIdentityId,
      recipientDeviceId: recipientDeviceId,
      recipientNodeId: recipientNodeId,
      recipientNodeDomain: domain,
      gatewayDevicePublicKey: _b64u(gatewayDevicePublicKey),
      gatewayFingerprint: await _fingerprint(gatewayDevicePublicKey),
      gatewayEphemeralPublicKey: _b64u(gatewayEphemeralPublicKey),
      recipientEphemeralPublicKey: _b64u(recipientEphemeralPublicKey),
      bearer: bearer,
      issuedAt: current,
      expiresAt: current.add(lifetime),
      nonce: _b64u(_nonce()),
      maxPackets: maxPackets,
      maxBytes: maxBytes,
      signature: '',
    );
    final signature = await recipientSigner.sign(unsigned.canonicalBytes());
    if (signature.length != 64) {
      throw const FormatException('Invalid recipient lease signature');
    }
    return LoomProximityGatewayLease(
      leaseId: unsigned.leaseId,
      sessionId: unsigned.sessionId,
      recipientIdentityId: unsigned.recipientIdentityId,
      recipientDeviceId: unsigned.recipientDeviceId,
      recipientNodeId: unsigned.recipientNodeId,
      recipientNodeDomain: unsigned.recipientNodeDomain,
      gatewayDevicePublicKey: unsigned.gatewayDevicePublicKey,
      gatewayFingerprint: unsigned.gatewayFingerprint,
      gatewayEphemeralPublicKey: unsigned.gatewayEphemeralPublicKey,
      recipientEphemeralPublicKey: unsigned.recipientEphemeralPublicKey,
      bearer: unsigned.bearer,
      issuedAt: unsigned.issuedAt,
      expiresAt: unsigned.expiresAt,
      nonce: unsigned.nonce,
      maxPackets: unsigned.maxPackets,
      maxBytes: unsigned.maxBytes,
      signature: _b64u(signature),
    );
  }
}

final class LoomGatewayClaimPacket {
  const LoomGatewayClaimPacket({
    required this.packetId,
    required this.mailboxToken,
    required this.envelopeBase64,
    required this.expiresAt,
    required this.priority,
    required this.acceptedAt,
  });
  final String packetId;
  final String mailboxToken;
  final String envelopeBase64;
  final DateTime expiresAt;
  final String priority;
  final DateTime acceptedAt;

  factory LoomGatewayClaimPacket.fromJson(Map<String, Object?> json) {
    String s(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Invalid gateway packet $key');
      }
      return value;
    }

    final expiresAt = DateTime.tryParse(s('expiresAt'))?.toUtc();
    final acceptedAt = DateTime.tryParse(s('acceptedAt'))?.toUtc();
    if (expiresAt == null || acceptedAt == null) {
      throw const FormatException('Invalid gateway packet timestamps');
    }
    return LoomGatewayClaimPacket(
      packetId: s('packetId'),
      mailboxToken: s('mailboxToken'),
      envelopeBase64: s('envelopeBase64'),
      expiresAt: expiresAt,
      priority: s('priority'),
      acceptedAt: acceptedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'packetId': packetId,
        'mailboxToken': mailboxToken,
        'envelopeBase64': envelopeBase64,
        'expiresAt': _iso(expiresAt),
        'priority': priority,
        'acceptedAt': _iso(acceptedAt),
      };
}

final class LoomLegacyGatewayDelivery {
  const LoomLegacyGatewayDelivery({
    required this.deliveryId,
    required this.conversation,
    required this.event,
  });
  final String deliveryId;
  final LoomConversation conversation;
  final LoomSyncEvent event;

  factory LoomLegacyGatewayDelivery.fromJson(Map<String, Object?> json) {
    final deliveryId = json['deliveryId'];
    final conversationRaw = json['conversation'];
    final eventRaw = json['event'];
    if (deliveryId is! String || conversationRaw is! Map || eventRaw is! Map) {
      throw const FormatException('Invalid legacy gateway delivery');
    }
    final c = conversationRaw.map(
      (key, value) => MapEntry(key.toString(), value as Object?),
    );
    final e = eventRaw.map(
      (key, value) => MapEntry(key.toString(), value as Object?),
    );
    final kind = c['kind'];
    final order = e['order'];
    final payload = e['payload'];
    if (c['id'] is! String ||
        kind is! String ||
        c['updatedOrder'] is! int ||
        c['unreadCount'] is! int ||
        e['eventId'] is! String ||
        e['kind'] is! String ||
        order is! int ||
        payload is! Map) {
      throw const FormatException('Malformed legacy gateway delivery');
    }
    return LoomLegacyGatewayDelivery(
      deliveryId: deliveryId,
      conversation: LoomConversation(
        id: c['id'] as String,
        kind: LoomConversationKind.values.byName(kind.toLowerCase()),
        title: c['title'] as String?,
        peerAddress: c['peerAddress'] as String?,
        updatedOrder: c['updatedOrder'] as int,
        unreadCount: c['unreadCount'] as int,
        isMuted: c['isMuted'] == true,
        isPinned: c['isPinned'] == true,
      ),
      event: LoomSyncEvent(
        eventId: e['eventId'] as String,
        kind: e['kind'] as String,
        order: order,
        payload: payload.map(
          (key, value) => MapEntry(key.toString(), value as Object?),
        ),
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'deliveryId': deliveryId,
        'conversation': <String, Object?>{
          'id': conversation.id,
          'kind': conversation.kind.name,
          'title': conversation.title,
          'peerAddress': conversation.peerAddress,
          'updatedOrder': conversation.updatedOrder,
          'unreadCount': conversation.unreadCount,
          'isMuted': conversation.isMuted,
          'isPinned': conversation.isPinned,
        },
        'event': <String, Object?>{
          'eventId': event.eventId,
          'kind': event.kind,
          'order': event.order,
          'payload': event.payload,
        },
      };
}

final class LoomProximityGatewayClaim {
  const LoomProximityGatewayClaim({
    required this.packets,
    required this.legacyDeliveries,
  });
  final List<LoomGatewayClaimPacket> packets;
  final List<LoomLegacyGatewayDelivery> legacyDeliveries;
  List<String> get custodyIds => <String>[
        ...packets.map((packet) => packet.packetId),
        ...legacyDeliveries.map((delivery) => delivery.deliveryId),
      ];
}

final class LoomProximityGatewayTarget {
  const LoomProximityGatewayTarget({
    required this.nodeId,
    required this.endpoint,
    required this.identityVerified,
  });
  final String nodeId;
  final Uri endpoint;
  final bool identityVerified;

  static Future<LoomProximityGatewayTarget> discoverForLease(
    LoomProximityGatewayLease lease, {
    LoomNodeClient? nodeClient,
  }) async {
    final node = await (nodeClient ?? LoomNodeClient()).discoverDomain(
      lease.recipientNodeDomain,
    );
    if (node.nodeId != lease.recipientNodeId) {
      throw const FormatException('Proximity lease destination node mismatch');
    }
    return LoomProximityGatewayTarget(
      nodeId: node.nodeId,
      endpoint: node.endpoint,
      identityVerified: true,
    );
  }

  Uri route(String path) {
    if (!identityVerified) throw StateError('Destination node is not verified');
    if (endpoint.userInfo.isNotEmpty ||
        endpoint.query.isNotEmpty ||
        endpoint.fragment.isNotEmpty) {
      throw const FormatException('Unsafe proximity gateway endpoint');
    }
    if (endpoint.scheme != 'https') {
      final host = endpoint.host.toLowerCase();
      final loopback = host == 'localhost' ||
          (endpoint.scheme == 'http' &&
              (InternetAddress.tryParse(host)?.isLoopback ?? false));
      if (!loopback) {
        throw const FormatException('Unsafe proximity gateway endpoint');
      }
    }
    return endpoint.resolve(path);
  }
}

final class LoomProximityGatewayClient {
  LoomProximityGatewayClient({
    required this.target,
    required this.gatewaySigner,
    LoomDirectHttpPoster? poster,
  }) : poster =
            poster ?? LoomIoDirectHttpPoster(maxResponseBytes: 2 * 1024 * 1024);

  final LoomProximityGatewayTarget target;
  final LoomDirectTransportSigner gatewaySigner;
  final LoomDirectHttpPoster poster;

  Future<void> registerLease(LoomProximityGatewayLease lease) async {
    if (lease.recipientNodeId != target.nodeId) {
      throw const FormatException('Gateway target does not match lease node');
    }
    final body = <String, Object?>{'lease': lease.toJson()};
    body['gatewayProof'] = await _proof(
      'register',
      leaseId: lease.leaseId,
      recipientDeviceId: lease.recipientDeviceId,
    );
    final response = await poster.postJson(
      target.route('/api/v2/gateway/leases/register'),
      body,
    );
    if (response.statusCode != 201 || response.body?['registered'] != true) {
      throw StateError(
        'Gateway lease registration failed: HTTP ${response.statusCode}',
      );
    }
  }

  Future<LoomProximityGatewayClaim> claim({
    required LoomProximityGatewayLease lease,
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 50) {
      throw const FormatException('Invalid gateway claim limit');
    }
    final body = <String, Object?>{
      'leaseId': lease.leaseId,
      'recipientDeviceId': lease.recipientDeviceId,
      'limit': limit,
    };
    body['gatewayProof'] = await _proof(
      'claim',
      leaseId: lease.leaseId,
      recipientDeviceId: lease.recipientDeviceId,
      limit: limit,
    );
    final response = await poster.postJson(
      target.route('/api/v2/gateway/claim'),
      body,
    );
    if (response.statusCode != 200 || response.body == null) {
      throw StateError(
        'Gateway packet claim failed: HTTP ${response.statusCode}',
      );
    }
    final rawPackets = response.body!['packets'];
    final rawLegacy = response.body!['legacyDeliveries'];
    if (rawPackets is! List || rawLegacy is! List) {
      throw const FormatException('Gateway claim payload is incomplete');
    }
    return LoomProximityGatewayClaim(
      packets: rawPackets.map((value) {
        if (value is! Map) {
          throw const FormatException('Invalid gateway claim packet');
        }
        return LoomGatewayClaimPacket.fromJson(
          value.map(
            (key, value) => MapEntry(key.toString(), value as Object?),
          ),
        );
      }).toList(growable: false),
      legacyDeliveries: rawLegacy.map((value) {
        if (value is! Map) {
          throw const FormatException('Invalid legacy gateway delivery');
        }
        return LoomLegacyGatewayDelivery.fromJson(
          value.map(
            (key, value) => MapEntry(key.toString(), value as Object?),
          ),
        );
      }).toList(growable: false),
    );
  }

  Future<void> acknowledgeCustody({
    required LoomProximityGatewayLease lease,
    required List<String> deliveryIds,
  }) async {
    if (deliveryIds.isEmpty) return;
    if (deliveryIds.length > 50 ||
        deliveryIds.toSet().length != deliveryIds.length) {
      throw const FormatException('Invalid gateway custody delivery ids');
    }
    final sorted = [...deliveryIds]..sort();
    final body = <String, Object?>{
      'leaseId': lease.leaseId,
      'recipientDeviceId': lease.recipientDeviceId,
      'packetIds': sorted,
    };
    body['gatewayProof'] = await _proof(
      'custody',
      leaseId: lease.leaseId,
      recipientDeviceId: lease.recipientDeviceId,
      packetIds: sorted,
    );
    final response = await poster.postJson(
      target.route('/api/v2/gateway/custody'),
      body,
    );
    if (response.statusCode != 200) {
      throw StateError(
        'Gateway custody acknowledgement failed: HTTP ${response.statusCode}',
      );
    }
  }

  Future<Map<String, Object?>> _proof(
    String action, {
    required String leaseId,
    required String recipientDeviceId,
    int limit = 0,
    List<String> packetIds = const <String>[],
  }) async {
    final publicKey = await gatewaySigner.ed25519PublicKey();
    if (publicKey.length != 32) {
      throw const FormatException('Invalid gateway signing key');
    }
    final issuedAt = _iso(DateTime.now());
    final nonce = _b64u(_nonce());
    final key = _b64u(publicKey);
    final sortedPacketIds = [...packetIds]..sort();
    final canonical = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<Object?>[
          _proofDomain,
          action,
          issuedAt,
          nonce,
          key,
          leaseId,
          recipientDeviceId,
          limit,
          sortedPacketIds,
        ]),
      ),
    );
    final signature = await gatewaySigner.sign(canonical);
    if (signature.length != 64) {
      throw const FormatException('Invalid gateway transport signature');
    }
    return <String, Object?>{
      'devicePublicKey': key,
      'issuedAt': issuedAt,
      'nonce': nonce,
      'signature': _b64u(signature),
    };
  }
}

final class LoomNearbyProximityGatewayExchange {
  const LoomNearbyProximityGatewayExchange({
    this.codec = const LoomNearbyPacketCodec(),
  });
  final LoomNearbyPacketCodec codec;

  Future<void> sendLease(
    LoomNearbySecureConnection connection,
    LoomProximityGatewayLease lease,
  ) =>
      connection.send(
        codec.encode(<String, Object?>{
          'kind': _nearbyLeaseKind,
          'lease': lease.toJson(),
        }),
      );

  Future<LoomProximityGatewayLease> receiveLease(
    LoomNearbySecureConnection connection, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final body = codec.decode(await connection.receive(timeout: timeout));
    if (body['kind'] != _nearbyLeaseKind || body['lease'] is! Map) {
      throw const FormatException('Invalid Nearby gateway lease frame');
    }
    final raw = body['lease'] as Map;
    return LoomProximityGatewayLease.fromJson(
      raw.map((key, value) => MapEntry(key.toString(), value as Object?)),
    );
  }

  Future<bool> sendPacketAndAwaitRecipientAck(
    LoomNearbySecureConnection connection,
    LoomGatewayClaimPacket packet, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await connection.send(
      codec.encode(<String, Object?>{
        'kind': _nearbyPacketKind,
        'packet': packet.toJson(),
      }),
    );
    final reply = codec.decode(await connection.receive(timeout: timeout));
    return reply['kind'] == _nearbyPacketAckKind &&
        reply['packetId'] == packet.packetId &&
        reply['accepted'] == true;
  }

  Future<LoomGatewayClaimPacket> receivePacketAndAcknowledge(
    LoomNearbySecureConnection connection, {
    required Future<bool> Function(LoomGatewayClaimPacket packet) accept,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final body = codec.decode(await connection.receive(timeout: timeout));
    if (body['kind'] != _nearbyPacketKind || body['packet'] is! Map) {
      throw const FormatException('Invalid Nearby gateway packet frame');
    }
    final raw = body['packet'] as Map;
    final packet = LoomGatewayClaimPacket.fromJson(
      raw.map((key, value) => MapEntry(key.toString(), value as Object?)),
    );
    final accepted = await accept(packet);
    await connection.send(
      codec.encode(<String, Object?>{
        'kind': _nearbyPacketAckKind,
        'packetId': packet.packetId,
        'accepted': accepted,
      }),
    );
    return packet;
  }

  Future<bool> sendLegacyAndAwaitRecipientAck(
    LoomNearbySecureConnection connection,
    LoomLegacyGatewayDelivery delivery, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await connection.send(
      codec.encode(<String, Object?>{
        'kind': _nearbyLegacyKind,
        'delivery': delivery.toJson(),
      }),
    );
    final reply = codec.decode(await connection.receive(timeout: timeout));
    return reply['kind'] == _nearbyLegacyAckKind &&
        reply['deliveryId'] == delivery.deliveryId &&
        reply['accepted'] == true;
  }

  Future<LoomLegacyGatewayDelivery> receiveLegacyAndAcknowledge(
    LoomNearbySecureConnection connection, {
    required Future<bool> Function(LoomLegacyGatewayDelivery delivery) accept,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final body = codec.decode(await connection.receive(timeout: timeout));
    if (body['kind'] != _nearbyLegacyKind || body['delivery'] is! Map) {
      throw const FormatException('Invalid Nearby legacy gateway frame');
    }
    final raw = body['delivery'] as Map;
    final delivery = LoomLegacyGatewayDelivery.fromJson(
      raw.map((key, value) => MapEntry(key.toString(), value as Object?)),
    );
    final accepted = await accept(delivery);
    await connection.send(
      codec.encode(<String, Object?>{
        'kind': _nearbyLegacyAckKind,
        'deliveryId': delivery.deliveryId,
        'accepted': accepted,
      }),
    );
    return delivery;
  }
}
