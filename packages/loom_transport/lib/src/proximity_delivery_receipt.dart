import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'direct_node_delivery.dart';
import 'nearby_transport.dart';
import 'proximity_gateway.dart';

const _recipientReceiptDomain = 'loom-proximity-recipient-delivery-v1';
const _gatewayProofDomain = 'loom-proximity-gateway-proof-v1';
const _legacyOfferKind = 'proximity.gateway.legacy-receipt-offer.v1';
const _legacyReceiptKind = 'proximity.gateway.legacy-receipt-ack.v1';

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

final class LoomRecipientDeliveryReceipt {
  const LoomRecipientDeliveryReceipt({
    required this.leaseId,
    required this.deliveryId,
    required this.recipientDeviceId,
    required this.acceptedAt,
    required this.signature,
  });

  final String leaseId;
  final String deliveryId;
  final String recipientDeviceId;
  final DateTime acceptedAt;
  final String signature;

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(<Object?>[
        _recipientReceiptDomain,
        1,
        leaseId,
        deliveryId,
        recipientDeviceId,
        _iso(acceptedAt),
      ]),
    ),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'leaseId': leaseId,
    'deliveryId': deliveryId,
    'recipientDeviceId': recipientDeviceId,
    'acceptedAt': _iso(acceptedAt),
    'signature': signature,
  };

  factory LoomRecipientDeliveryReceipt.fromJson(Map<String, Object?> json) {
    String text(String key, {int max = 256}) {
      final value = json[key];
      if (value is! String ||
          value.isEmpty ||
          value.length > max ||
          value.contains(RegExp(r'[\r\n\x00]'))) {
        throw FormatException('Invalid recipient delivery receipt $key');
      }
      return value;
    }

    if (json['version'] != 1) {
      throw const FormatException('Unsupported recipient delivery receipt');
    }
    final acceptedAt = DateTime.tryParse(text('acceptedAt', max: 64))?.toUtc();
    if (acceptedAt == null) {
      throw const FormatException(
        'Invalid recipient delivery receipt timestamp',
      );
    }
    final signature = text('signature', max: 128);
    final signatureBytes = base64Url.decode(base64Url.normalize(signature));
    if (signatureBytes.length != 64 || _b64u(signatureBytes) != signature) {
      throw const FormatException(
        'Invalid recipient delivery receipt signature',
      );
    }
    return LoomRecipientDeliveryReceipt(
      leaseId: text('leaseId', max: 128),
      deliveryId: text('deliveryId', max: 256),
      recipientDeviceId: text('recipientDeviceId', max: 256),
      acceptedAt: acceptedAt,
      signature: signature,
    );
  }

  static Future<LoomRecipientDeliveryReceipt> create({
    required LoomDirectTransportSigner recipientSigner,
    required LoomProximityGatewayLease lease,
    required String deliveryId,
    DateTime? acceptedAt,
  }) async {
    if (!deliveryId.startsWith('legacy:') || deliveryId.length > 256) {
      throw const FormatException('Invalid legacy delivery receipt id');
    }
    final unsigned = LoomRecipientDeliveryReceipt(
      leaseId: lease.leaseId,
      deliveryId: deliveryId,
      recipientDeviceId: lease.recipientDeviceId,
      acceptedAt: (acceptedAt ?? DateTime.now()).toUtc(),
      signature: '',
    );
    final signature = await recipientSigner.sign(unsigned.canonicalBytes());
    if (signature.length != 64) {
      throw const FormatException('Invalid recipient delivery signature');
    }
    return LoomRecipientDeliveryReceipt(
      leaseId: unsigned.leaseId,
      deliveryId: unsigned.deliveryId,
      recipientDeviceId: unsigned.recipientDeviceId,
      acceptedAt: unsigned.acceptedAt,
      signature: _b64u(signature),
    );
  }
}

final class LoomProximityDeliveryReceiptExchange {
  const LoomProximityDeliveryReceiptExchange({
    this.codec = const LoomNearbyPacketCodec(),
  });

  final LoomNearbyPacketCodec codec;

  Future<LoomRecipientDeliveryReceipt?> sendLegacyAndAwaitReceipt(
    LoomNearbySecureConnection connection,
    LoomLegacyGatewayDelivery delivery, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await connection.send(
      codec.encode(<String, Object?>{
        'kind': _legacyOfferKind,
        'delivery': delivery.toJson(),
      }),
    );
    final reply = codec.decode(await connection.receive(timeout: timeout));
    if (reply['kind'] != _legacyReceiptKind ||
        reply['deliveryId'] != delivery.deliveryId ||
        reply['accepted'] is! bool) {
      throw const FormatException('Invalid recipient delivery receipt frame');
    }
    if (reply['accepted'] != true) return null;
    final raw = reply['receipt'];
    if (raw is! Map) {
      throw const FormatException('Missing recipient delivery receipt proof');
    }
    final receipt = LoomRecipientDeliveryReceipt.fromJson(
      raw.map((key, value) => MapEntry(key.toString(), value as Object?)),
    );
    if (receipt.deliveryId != delivery.deliveryId) {
      throw const FormatException('Recipient delivery receipt id mismatch');
    }
    return receipt;
  }

  Future<LoomLegacyGatewayDelivery> receiveLegacyAndSignReceipt(
    LoomNearbySecureConnection connection, {
    required LoomProximityGatewayLease lease,
    required LoomDirectTransportSigner recipientSigner,
    required Future<bool> Function(LoomLegacyGatewayDelivery delivery) accept,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final body = codec.decode(await connection.receive(timeout: timeout));
    if (body['kind'] != _legacyOfferKind || body['delivery'] is! Map) {
      throw const FormatException('Invalid Nearby legacy receipt offer');
    }
    final raw = body['delivery'] as Map;
    final delivery = LoomLegacyGatewayDelivery.fromJson(
      raw.map((key, value) => MapEntry(key.toString(), value as Object?)),
    );
    final accepted = await accept(delivery);
    final receipt = accepted
        ? await LoomRecipientDeliveryReceipt.create(
            recipientSigner: recipientSigner,
            lease: lease,
            deliveryId: delivery.deliveryId,
          )
        : null;
    await connection.send(
      codec.encode(<String, Object?>{
        'kind': _legacyReceiptKind,
        'deliveryId': delivery.deliveryId,
        'accepted': accepted,
        if (receipt != null) 'receipt': receipt.toJson(),
      }),
    );
    return delivery;
  }
}

extension LoomProximityRecipientReceiptClient on LoomProximityGatewayClient {
  Future<void> acknowledgeRecipientReceipts({
    required LoomProximityGatewayLease lease,
    required List<LoomRecipientDeliveryReceipt> receipts,
  }) async {
    if (receipts.isEmpty) return;
    if (receipts.length > 50 ||
        receipts.map((item) => item.deliveryId).toSet().length !=
            receipts.length) {
      throw const FormatException('Invalid recipient delivery receipt batch');
    }
    for (final receipt in receipts) {
      if (receipt.leaseId != lease.leaseId ||
          receipt.recipientDeviceId != lease.recipientDeviceId) {
        throw const FormatException('Recipient receipt lease binding mismatch');
      }
    }
    final packetIds = receipts.map((item) => item.deliveryId).toList()..sort();
    final body = <String, Object?>{
      'leaseId': lease.leaseId,
      'recipientDeviceId': lease.recipientDeviceId,
      'packetIds': packetIds,
      'recipientDeliveryReceipts': receipts
          .map((receipt) => receipt.toJson())
          .toList(growable: false),
    };
    body['gatewayProof'] = await _custodyProof(
      leaseId: lease.leaseId,
      recipientDeviceId: lease.recipientDeviceId,
      packetIds: packetIds,
    );
    final response = await poster.postJson(
      target.route('/api/v2/gateway/custody'),
      body,
    );
    if (response.statusCode != 200 ||
        response.body?['recipientDeliveryConfirmed'] != true) {
      throw StateError(
        'Recipient delivery custody failed: HTTP ${response.statusCode}',
      );
    }
  }

  Future<Map<String, Object?>> _custodyProof({
    required String leaseId,
    required String recipientDeviceId,
    required List<String> packetIds,
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
          _gatewayProofDomain,
          'custody',
          issuedAt,
          nonce,
          key,
          leaseId,
          recipientDeviceId,
          0,
          sortedPacketIds,
        ]),
      ),
    );
    final signature = await gatewaySigner.sign(canonical);
    if (signature.length != 64) {
      throw const FormatException('Invalid gateway custody signature');
    }
    return <String, Object?>{
      'devicePublicKey': key,
      'issuedAt': issuedAt,
      'nonce': nonce,
      'signature': _b64u(signature),
    };
  }
}
