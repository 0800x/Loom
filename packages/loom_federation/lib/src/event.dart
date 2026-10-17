import 'dart:convert';

import 'canonical_json.dart';

enum LoomFederationEventType {
  message,
  membership,
  groupUpdate,
  receipt,
  callAuthorization,
  keyPackageUpdate,
}

class LoomFederationEvent {
  const LoomFederationEvent({
    required this.eventId,
    required this.originNodeId,
    required this.destinationDomain,
    required this.conversationId,
    required this.type,
    required this.createdAt,
    required this.expiresAt,
    required this.hopCount,
    required this.maxHops,
    required this.nonce,
    required this.body,
    required this.signature,
    this.version = 'loom-federation-v1',
  });

  final String version;
  final String eventId;
  final String originNodeId;
  final String destinationDomain;
  final String conversationId;
  final LoomFederationEventType type;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int hopCount;
  final int maxHops;
  final String nonce;
  final Map<String, Object?> body;
  final String signature;

  Map<String, Object?> unsignedJson() => <String, Object?>{
        'version': version,
        'eventId': eventId,
        'originNodeId': originNodeId,
        'destination': destinationDomain,
        'conversationId': conversationId,
        'type': _wireType(type),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'hopCount': hopCount,
        'maxHops': maxHops,
        'nonce': nonce,
        'body': body,
      };

  Map<String, Object?> toJson() => <String, Object?>{
        ...unsignedJson(),
        'signature': signature,
      };

  List<int> signingBytes() => utf8.encode(loomCanonicalJson(unsignedJson()));

  LoomFederationEvent forwarded() {
    if (hopCount >= maxHops) {
      throw StateError('Federation hop limit reached');
    }
    return LoomFederationEvent(
      eventId: eventId,
      originNodeId: originNodeId,
      destinationDomain: destinationDomain,
      conversationId: conversationId,
      type: type,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopCount: hopCount + 1,
      maxHops: maxHops,
      nonce: nonce,
      body: body,
      signature: signature,
      version: version,
    );
  }

  factory LoomFederationEvent.fromJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Missing or invalid $key');
      }
      return value.trim();
    }

    int requiredInt(String key) {
      final value = json[key];
      if (value is! int) throw FormatException('Missing or invalid $key');
      return value;
    }

    final body = json['body'];
    if (body is! Map<String, Object?>) {
      throw const FormatException('Federation body must be an object');
    }
    final createdAt = DateTime.tryParse(requiredString('createdAt'))?.toUtc();
    final expiresAt = DateTime.tryParse(requiredString('expiresAt'))?.toUtc();
    if (createdAt == null || expiresAt == null) {
      throw const FormatException('Invalid federation timestamps');
    }
    final version = requiredString('version');
    if (version != 'loom-federation-v1') {
      throw FormatException('Unsupported federation version: $version');
    }
    return LoomFederationEvent(
      version: version,
      eventId: requiredString('eventId'),
      originNodeId: requiredString('originNodeId'),
      destinationDomain: requiredString('destination').toLowerCase(),
      conversationId: requiredString('conversationId'),
      type: _parseWireType(requiredString('type')),
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopCount: requiredInt('hopCount'),
      maxHops: requiredInt('maxHops'),
      nonce: requiredString('nonce'),
      body: body,
      signature: requiredString('signature'),
    );
  }
}

String _wireType(LoomFederationEventType type) => switch (type) {
      LoomFederationEventType.message => 'MessageEvent',
      LoomFederationEventType.membership => 'MembershipEvent',
      LoomFederationEventType.groupUpdate => 'GroupUpdate',
      LoomFederationEventType.receipt => 'Receipt',
      LoomFederationEventType.callAuthorization => 'CallAuthorization',
      LoomFederationEventType.keyPackageUpdate => 'KeyPackageUpdate',
    };

LoomFederationEventType _parseWireType(String value) => switch (value) {
      'MessageEvent' => LoomFederationEventType.message,
      'MembershipEvent' => LoomFederationEventType.membership,
      'GroupUpdate' => LoomFederationEventType.groupUpdate,
      'Receipt' => LoomFederationEventType.receipt,
      'CallAuthorization' => LoomFederationEventType.callAuthorization,
      'KeyPackageUpdate' => LoomFederationEventType.keyPackageUpdate,
      _ => throw FormatException('Unsupported federation event type: $value'),
    };
