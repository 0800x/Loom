import 'dart:convert';

class LoomNodeDescriptor {
  const LoomNodeDescriptor({
    required this.nodeId,
    required this.name,
    required this.domain,
    required this.operatorCountry,
    required this.networkLocation,
    required this.registration,
    required this.federation,
    required this.protocols,
    required this.publicKey,
    required this.fingerprint,
    required this.capabilities,
    this.region,
    this.operatorName,
    this.lastVerified,
  });

  final String nodeId;
  final String name;
  final String domain;
  final String operatorCountry;
  final String networkLocation;
  final String registration;
  final bool federation;
  final List<String> protocols;
  final String publicKey;
  final String fingerprint;
  final List<String> capabilities;
  final String? region;
  final String? operatorName;
  final DateTime? lastVerified;

  factory LoomNodeDescriptor.fromJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Missing or invalid $key');
      }
      return value.trim();
    }

    List<String> requiredStrings(String key) {
      final value = json[key];
      if (value is! List ||
          value.any((item) => item is! String || item.trim().isEmpty)) {
        throw FormatException('Missing or invalid $key');
      }
      return value.cast<String>().map((e) => e.trim()).toList(growable: false);
    }

    final federation = json['federation'];
    if (federation is! bool)
      throw const FormatException('Missing or invalid federation');
    final lastVerifiedRaw = json['lastVerified'];
    return LoomNodeDescriptor(
      nodeId: requiredString('nodeId'),
      name: requiredString('name'),
      domain: requiredString('domain').toLowerCase(),
      operatorCountry: requiredString('country').toUpperCase(),
      networkLocation: requiredString('networkLocation').toUpperCase(),
      registration: requiredString('registration'),
      federation: federation,
      protocols: requiredStrings('protocol'),
      publicKey: requiredString('publicKey'),
      fingerprint: requiredString('fingerprint'),
      capabilities: requiredStrings('capabilities'),
      region: json['region'] is String
          ? (json['region'] as String).trim()
          : null,
      operatorName: json['operator'] is String
          ? (json['operator'] as String).trim()
          : null,
      lastVerified: lastVerifiedRaw is String
          ? DateTime.tryParse(lastVerifiedRaw)?.toUtc()
          : null,
    );
  }
}

class LoomRegistryManifest {
  const LoomRegistryManifest({
    required this.schemaVersion,
    required this.generatedAt,
    required this.nodes,
  });

  final int schemaVersion;
  final DateTime generatedAt;
  final List<LoomNodeDescriptor> nodes;

  factory LoomRegistryManifest.fromBytes(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Registry root must be an object');
    }
    final version = decoded['schemaVersion'];
    final generatedAt = decoded['generatedAt'];
    final nodes = decoded['nodes'];
    if (version is! int || version != 1) {
      throw FormatException('Unsupported registry schema: $version');
    }
    if (generatedAt is! String || DateTime.tryParse(generatedAt) == null) {
      throw const FormatException('Invalid registry generatedAt');
    }
    if (nodes is! List)
      throw const FormatException('Registry nodes must be an array');
    final parsed = nodes
        .map((item) {
          if (item is! Map<String, Object?>)
            throw const FormatException('Invalid node entry');
          return LoomNodeDescriptor.fromJson(item);
        })
        .toList(growable: false);
    final ids = <String>{};
    final domains = <String>{};
    for (final node in parsed) {
      if (!ids.add(node.nodeId))
        throw FormatException('Duplicate nodeId: ${node.nodeId}');
      if (!domains.add(node.domain))
        throw FormatException('Duplicate domain: ${node.domain}');
    }
    return LoomRegistryManifest(
      schemaVersion: version,
      generatedAt: DateTime.parse(generatedAt).toUtc(),
      nodes: parsed,
    );
  }
}

class LoomWellKnownNode {
  const LoomWellKnownNode({
    required this.protocol,
    required this.endpoint,
    required this.nodeId,
    required this.publicKey,
    required this.signature,
    required this.fingerprint,
  });

  final String protocol;
  final Uri endpoint;
  final String nodeId;
  final String publicKey;
  final String signature;
  final String fingerprint;
}

class LoomNodeLiveInfo {
  const LoomNodeLiveInfo({
    required this.nodeId,
    required this.serverVersion,
    required this.protocolVersion,
    required this.registration,
    required this.federationMode,
    required this.capabilities,
    this.maxMediaBytes,
    this.capacityUsed,
    this.capacityLimit,
  });

  final String nodeId;
  final String serverVersion;
  final String protocolVersion;
  final String registration;
  final String federationMode;
  final List<String> capabilities;
  final int? maxMediaBytes;
  final int? capacityUsed;
  final int? capacityLimit;
}

class LoomIdentityPublic {
  const LoomIdentityPublic({
    required this.identityId,
    required this.publicKey,
    required this.fingerprint,
    required this.createdAt,
  });

  final String identityId;
  final String publicKey;
  final String fingerprint;
  final DateTime createdAt;
}

class LoomRecoveryMaterial {
  const LoomRecoveryMaterial({
    required this.mnemonicWords,
    required this.recoveryId,
  });

  final List<String> mnemonicWords;
  final String recoveryId;
}

class LoomPendingIdentity {
  const LoomPendingIdentity({required this.identity, required this.recovery});
  final LoomIdentityPublic identity;
  final LoomRecoveryMaterial recovery;
}

class LoomRegistrationReceipt {
  const LoomRegistrationReceipt({
    required this.accountId,
    required this.deviceId,
    required this.address,
    required this.homeNode,
  });
  final String accountId;
  final String deviceId;
  final String address;
  final String homeNode;
}

class LoomRegistrationResult {
  const LoomRegistrationResult({
    required this.receipt,
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiresInSeconds,
  });
  final LoomRegistrationReceipt receipt;
  final String accessToken;
  final String refreshToken;
  final int accessTokenExpiresInSeconds;
}

class LoomLoginResult {
  const LoomLoginResult({
    required this.receipt,
    required this.identityId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiresInSeconds,
  });

  final LoomRegistrationReceipt receipt;
  final String identityId;
  final String accessToken;
  final String refreshToken;
  final int accessTokenExpiresInSeconds;
}

enum LoomConversationKind { self, direct, group }

enum LoomMessageType {
  text,
  image,
  video,
  voice,
  file,
  audio,
  contact,
  location,
  system,
}

enum LoomDeliveryState { queued, sending, sent, delivered, read, failed }

/// Observed by this device's transport, never taken from message metadata.
enum LoomMessageTransportPath { unknown, internet, nearby, hybrid }

enum LoomPendingOperationKind { sendMessage, markRead }

class LoomConversation {
  const LoomConversation({
    required this.id,
    required this.kind,
    required this.updatedOrder,
    required this.unreadCount,
    required this.isMuted,
    required this.isPinned,
    this.title,
    this.peerAddress,
  });

  final String id;
  final LoomConversationKind kind;
  final String? title;
  final String? peerAddress;
  final int updatedOrder;
  final int unreadCount;
  final bool isMuted;
  final bool isPinned;
}

class LoomMessageRecord {
  const LoomMessageRecord({
    required this.id,
    required this.clientId,
    required this.conversationId,
    required this.senderAddress,
    required this.type,
    required this.ciphertext,
    required this.protocolVersion,
    required this.createdOrder,
    required this.createdAt,
    required this.deliveryState,
    this.transportPath = LoomMessageTransportPath.unknown,
    this.replyToMessageId,
    this.metadata = const {},
  });

  final String id;
  final String clientId;
  final String conversationId;
  final String senderAddress;
  final LoomMessageType type;
  final String ciphertext;
  final String protocolVersion;
  final int createdOrder;
  final DateTime createdAt;
  final LoomDeliveryState deliveryState;
  final LoomMessageTransportPath transportPath;
  final String? replyToMessageId;
  final Map<String, Object?> metadata;
}

class LoomPendingOperation {
  const LoomPendingOperation({
    required this.operationId,
    required this.clientId,
    required this.conversationId,
    required this.kind,
    required this.payload,
    required this.attemptCount,
    required this.nextAttemptAt,
    required this.createdAt,
    this.lastError,
  });

  final String operationId;
  final String clientId;
  final String conversationId;
  final LoomPendingOperationKind kind;
  final Map<String, Object?> payload;
  final int attemptCount;
  final DateTime nextAttemptAt;
  final DateTime createdAt;
  final String? lastError;
}

class LoomSyncEvent {
  const LoomSyncEvent({
    required this.eventId,
    required this.kind,
    required this.order,
    required this.payload,
  });
  final String eventId;
  final String kind;
  final int order;
  final Map<String, Object?> payload;
}

class LoomSyncPage {
  const LoomSyncPage({
    required this.events,
    required this.nextCursor,
    required this.hasMore,
  });
  final List<LoomSyncEvent> events;
  final String? nextCursor;
  final bool hasMore;
}

class LoomSendReceipt {
  const LoomSendReceipt({
    required this.messageId,
    required this.clientId,
    required this.serverOrder,
    required this.createdAt,
  });
  final String messageId;
  final String clientId;
  final int serverOrder;
  final DateTime createdAt;
}

class LoomAttachmentReceipt {
  const LoomAttachmentReceipt({
    required this.attachmentId,
    required this.sizeBytes,
    required this.contentType,
  });
  final String attachmentId;
  final int sizeBytes;
  final String contentType;
}

enum LoomDeviceTrustState { unknown, verified, changed, revoked }

enum LoomEncryptionState { unavailable, legacy, modernReady, mlsActive }

enum LoomSecurityEventKind {
  deviceAdded,
  deviceVerified,
  deviceKeyChanged,
  deviceRevoked,
  identityKeyChanged,
}

class LoomDeviceKeyBundle {
  const LoomDeviceKeyBundle({
    required this.bundleVersion,
    required this.identityId,
    required this.deviceId,
    required this.deviceName,
    required this.signingPublicKey,
    required this.agreementPublicKey,
    required this.createdAt,
    required this.capabilities,
    required this.fingerprint,
    required this.deviceSignature,
    required this.identitySignature,
  });

  factory LoomDeviceKeyBundle.unsigned({
    required String identityId,
    required String deviceId,
    required String deviceName,
    required String signingPublicKey,
    required String agreementPublicKey,
    required DateTime createdAt,
    required List<String> capabilities,
  }) => LoomDeviceKeyBundle(
    bundleVersion: 1,
    identityId: identityId,
    deviceId: deviceId,
    deviceName: deviceName,
    signingPublicKey: signingPublicKey,
    agreementPublicKey: agreementPublicKey,
    createdAt: createdAt.toUtc(),
    capabilities: List<String>.unmodifiable(capabilities),
    fingerprint: '',
    deviceSignature: '',
    identitySignature: '',
  );

  factory LoomDeviceKeyBundle.fromJson(Map<String, Object?> json) {
    String requireString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Invalid device bundle field: $key');
      }
      return value.trim();
    }

    final version = json['bundleVersion'];
    if (version != 1)
      throw FormatException('Unsupported device bundle version: $version');
    final created = DateTime.tryParse(requireString('createdAt'));
    if (created == null)
      throw const FormatException('Invalid device bundle createdAt');
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities is! List ||
        rawCapabilities.any((item) => item is! String)) {
      throw const FormatException('Invalid device bundle capabilities');
    }
    return LoomDeviceKeyBundle(
      bundleVersion: 1,
      identityId: requireString('identityId'),
      deviceId: requireString('deviceId'),
      deviceName: requireString('deviceName'),
      signingPublicKey: requireString('signingPublicKey'),
      agreementPublicKey: requireString('agreementPublicKey'),
      createdAt: created.toUtc(),
      capabilities: List<String>.unmodifiable(rawCapabilities.cast<String>()),
      fingerprint: requireString('fingerprint'),
      deviceSignature: requireString('deviceSignature'),
      identitySignature: requireString('identitySignature'),
    );
  }

  final int bundleVersion;
  final String identityId;
  final String deviceId;
  final String deviceName;
  final String signingPublicKey;
  final String agreementPublicKey;
  final DateTime createdAt;
  final List<String> capabilities;
  final String fingerprint;
  final String deviceSignature;
  final String identitySignature;

  LoomDeviceKeyBundle copyWith({
    String? fingerprint,
    String? deviceSignature,
    String? identitySignature,
  }) => LoomDeviceKeyBundle(
    bundleVersion: bundleVersion,
    identityId: identityId,
    deviceId: deviceId,
    deviceName: deviceName,
    signingPublicKey: signingPublicKey,
    agreementPublicKey: agreementPublicKey,
    createdAt: createdAt,
    capabilities: capabilities,
    fingerprint: fingerprint ?? this.fingerprint,
    deviceSignature: deviceSignature ?? this.deviceSignature,
    identitySignature: identitySignature ?? this.identitySignature,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'bundleVersion': bundleVersion,
    'identityId': identityId,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'signingPublicKey': signingPublicKey,
    'agreementPublicKey': agreementPublicKey,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'capabilities': capabilities,
    'fingerprint': fingerprint,
    'deviceSignature': deviceSignature,
    'identitySignature': identitySignature,
  };

  List<int> canonicalBindingBytes() => utf8.encode(
    jsonEncode(<String, Object?>{
      'bundleVersion': bundleVersion,
      'identityId': identityId,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'signingPublicKey': signingPublicKey,
      'agreementPublicKey': agreementPublicKey,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'capabilities': List<String>.from(capabilities)..sort(),
    }),
  );
}

class LoomVerificationComparison {
  const LoomVerificationComparison({
    required this.displayGroups,
    required this.qrPayload,
  });

  final List<String> displayGroups;
  final String qrPayload;
}

class LoomKnownDevice {
  const LoomKnownDevice({
    required this.bundle,
    required this.trustState,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.verifiedAt,
  });

  final LoomDeviceKeyBundle bundle;
  final LoomDeviceTrustState trustState;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime? verifiedAt;
}

class LoomSecurityEvent {
  const LoomSecurityEvent({
    required this.eventId,
    required this.kind,
    required this.identityId,
    required this.deviceId,
    required this.createdAt,
    required this.summary,
  });

  final String eventId;
  final LoomSecurityEventKind kind;
  final String identityId;
  final String deviceId;
  final DateTime createdAt;
  final String summary;
}

class LoomMlsKeyPackage {
  const LoomMlsKeyPackage({
    required this.deviceId,
    required this.ciphersuite,
    required this.serialized,
    required this.expiresAt,
  });
  final String deviceId;
  final String ciphersuite;
  final List<int> serialized;
  final DateTime expiresAt;
}

class LoomMlsGroupState {
  const LoomMlsGroupState({
    required this.conversationId,
    required this.epoch,
    required this.memberDeviceIds,
  });
  final String conversationId;
  final int epoch;
  final List<String> memberDeviceIds;
}

class LoomMlsCiphertext {
  const LoomMlsCiphertext({
    required this.conversationId,
    required this.epoch,
    required this.serialized,
  });
  final String conversationId;
  final int epoch;
  final List<int> serialized;
}

class LoomMlsCommitResult {
  const LoomMlsCommitResult({
    required this.newState,
    required this.commitMessage,
    this.welcomeMessages = const <List<int>>[],
  });
  final LoomMlsGroupState newState;
  final List<int> commitMessage;
  final List<List<int>> welcomeMessages;
}

class LoomLegacyEnvelope {
  const LoomLegacyEnvelope({
    required this.protocolVersion,
    required this.ciphertext,
    required this.nonce,
    required this.wrappedKeys,
  });
  final String protocolVersion;
  final String ciphertext;
  final String nonce;
  final Map<String, String> wrappedKeys;
}

enum LoomCallKind { audio, video }

enum LoomCallDirection { incoming, outgoing }

enum LoomCallLifecycle {
  idle,
  preparing,
  ringing,
  connecting,
  connected,
  reconnecting,
  ended,
  failed,
}

enum LoomCallQuality { unknown, excellent, good, constrained, poor }

enum LoomCallEndReason {
  localHangup,
  remoteHangup,
  rejected,
  busy,
  timeout,
  permissionDenied,
  mediaFailure,
  signalingFailure,
  connectionFailure,
}

class LoomIceServer {
  const LoomIceServer({required this.urls, this.username, this.credential});

  final List<String> urls;
  final String? username;
  final String? credential;

  Map<String, Object?> toJson() => {
    'urls': urls.length == 1 ? urls.first : urls,
    if (username != null) 'username': username,
    if (credential != null) 'credential': credential,
  };
}

class LoomRtcConfiguration {
  const LoomRtcConfiguration({
    required this.iceServers,
    required this.expiresAt,
  });

  final List<LoomIceServer> iceServers;
  final DateTime expiresAt;
}

class LoomCallSignal {
  const LoomCallSignal({
    required this.callId,
    required this.conversationId,
    required this.senderIdentityId,
    required this.targetIdentityId,
    required this.kind,
    required this.sequence,
    required this.createdAt,
    this.sdp,
    this.sdpType,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    this.reason,
    this.mediaKind,
  });

  final String callId;
  final String conversationId;
  final String senderIdentityId;
  final String targetIdentityId;
  final String kind;
  final int sequence;
  final DateTime createdAt;
  final String? sdp;
  final String? sdpType;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
  final String? reason;
  final LoomCallKind? mediaKind;
}

class LoomPendingCall {
  const LoomPendingCall({
    required this.callId,
    required this.conversationId,
    required this.callerIdentityId,
    required this.kind,
    required this.createdAt,
    required this.expiresAt,
    required this.offerSdp,
  });

  final String callId;
  final String conversationId;
  final String callerIdentityId;
  final LoomCallKind kind;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String offerSdp;
}

class LoomRelaySealedPayload {
  const LoomRelaySealedPayload({
    required this.version,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  factory LoomRelaySealedPayload.fromJson(Map<String, Object?> json) {
    String field(String key, {int max = 400000}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw FormatException('Invalid relay sealed payload field: $key');
      }
      return value;
    }

    if (json['version'] != 1)
      throw const FormatException('Unsupported relay sealed payload version');
    final ephemeral = base64Decode(field('ephemeralPublicKey', max: 128));
    final nonceBytes = base64Decode(field('nonce', max: 128));
    final macBytes = base64Decode(field('mac', max: 128));
    if (ephemeral.length != 32 ||
        nonceBytes.length != 12 ||
        macBytes.length != 16) {
      throw const FormatException(
        'Invalid relay sealed payload cryptographic lengths',
      );
    }
    return LoomRelaySealedPayload(
      version: 1,
      ephemeralPublicKey: base64Encode(ephemeral),
      nonce: base64Encode(nonceBytes),
      ciphertext: field('ciphertext'),
      mac: base64Encode(macBytes),
    );
  }

  final int version;
  final String ephemeralPublicKey;
  final String nonce;
  final String ciphertext;
  final String mac;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'ephemeralPublicKey': ephemeralPublicKey,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'mac': mac,
  };
}
