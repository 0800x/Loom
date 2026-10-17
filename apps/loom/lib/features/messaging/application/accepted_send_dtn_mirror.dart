import 'dart:async';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../onboarding/application/onboarding_controller.dart';
import 'offline_device_directory_cache.dart';

typedef LoomAcceptedSendMessagesProvider =
    List<LoomMessageRecord> Function(String conversationId);

typedef LoomAcceptedSendDtnWriter =
    Future<void> Function({
      required String destinationNodeDomain,
      required String senderAddress,
      required List<LoomDeviceKeyBundle> recipientDevices,
      required String conversationId,
      required String clientId,
      required LoomMessageType type,
      required String ciphertext,
      required String protocolVersion,
      String? replyToMessageId,
      DateTime? createdAt,
      required Map<String, Object?> metadata,
    });

typedef LoomAcceptedSendRouteResolver =
    Future<LoomAcceptedSendRoute?> Function(LoomConversation conversation);

final class LoomAcceptedSendRoute {
  const LoomAcceptedSendRoute({
    required this.destinationNodeDomain,
    required this.recipientDevices,
  });

  final String destinationNodeDomain;
  final List<LoomDeviceKeyBundle> recipientDevices;
}

/// Process-local, release-safe diagnostics for the accepted-send DTN mirror.
/// No addresses, device ids, ciphertext, message text, keys, tokens, endpoints,
/// SSIDs or IP addresses are retained here.
abstract final class LoomAcceptedSendDtnDiagnostics {
  static int persistedCount = 0;
  static int directoryUnavailableCount = 0;
  static int failedCount = 0;
  static String lastResult = 'none';
  static String? lastExceptionType;
  static DateTime? lastUpdatedAt;

  static void record(String result, {String? exceptionType}) {
    lastResult = result;
    lastExceptionType = exceptionType;
    lastUpdatedAt = DateTime.now().toUtc();
  }
}

/// Mirrors a message into durable DTN custody only after ordinary online
/// delivery has been authoritatively accepted by the Home Node.
///
/// This closes an important hybrid-transport gap: an online sender can receive
/// a successful server receipt while the nearby recipient has no Internet. A
/// successful online send therefore also gets an idempotent store/carry copy,
/// using the exact same client id and encrypted envelope.
///
/// Queued/sending messages are deliberately ignored here. Their bounded online
/// attempt is still responsible for entering the ordinary transport-error DTN
/// fallback path, so a future definitive 4xx cannot be bypassed by this mirror.
final class LoomAcceptedSendDtnMirror {
  LoomAcceptedSendDtnMirror({
    required this.onboarding,
    required this.messagingListenable,
    required this.conversationsProvider,
    required this.messagesProvider,
    required this.dtnWriter,
    this._routeResolver,
    Future<String> Function()? supportPathProvider,
    DateTime Function()? clock,
    this.replayWindow = const Duration(days: 6),
  }) : _supportPathProvider =
           supportPathProvider ?? _defaultApplicationSupportPath,
       _clock = clock ?? DateTime.now {
    _notBefore = _clock().toUtc().subtract(replayWindow);
    messagingListenable.addListener(_requestDrain);
    _requestDrain();
    _retryTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _requestDrain(),
    );
  }

  final LoomOnboardingController onboarding;
  final Listenable messagingListenable;
  final List<LoomConversation> Function() conversationsProvider;
  final LoomAcceptedSendMessagesProvider messagesProvider;
  final LoomAcceptedSendDtnWriter dtnWriter;
  final LoomAcceptedSendRouteResolver? _routeResolver;
  final Future<String> Function() _supportPathProvider;
  final DateTime Function() _clock;
  final Duration replayWindow;

  final Set<String> _mirroredClientIds = <String>{};
  late final DateTime _notBefore;
  Timer? _retryTimer;
  bool _disposed = false;
  bool _draining = false;
  bool _drainRequested = false;

  int persistedCount = 0;
  int directoryUnavailableCount = 0;
  int failedCount = 0;
  String lastResult = 'none';
  String? lastExceptionType;
  DateTime? lastUpdatedAt;

  static Future<String> _defaultApplicationSupportPath() async =>
      (await getApplicationSupportDirectory()).path;

  void _requestDrain() {
    if (_disposed) return;
    _drainRequested = true;
    if (_draining) return;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_disposed || _draining) return;
    _draining = true;
    try {
      do {
        _drainRequested = false;
        await _mirrorAcceptedMessages();
      } while (_drainRequested && !_disposed);
    } finally {
      _draining = false;
      if (_drainRequested && !_disposed) _requestDrain();
    }
  }

  Future<void> _mirrorAcceptedMessages() async {
    final receipt = onboarding.receipt;
    final identity = onboarding.committedIdentity;
    if (receipt == null || identity == null || _disposed) return;

    for (final conversation in conversationsProvider()) {
      if (_disposed) return;
      if (conversation.kind != LoomConversationKind.direct &&
          conversation.kind != LoomConversationKind.self) {
        continue;
      }
      LoomAcceptedSendRoute? route;
      for (final message in messagesProvider(conversation.id)) {
        if (_disposed) return;
        if (!_isAcceptedOutgoing(message, receipt.address) ||
            _mirroredClientIds.contains(message.clientId)) {
          continue;
        }

        route ??= await _resolveRoute(
          conversation,
          identity: identity,
          receipt: receipt,
        );
        if (_disposed) return;
        if (route == null || route.recipientDevices.isEmpty) {
          directoryUnavailableCount++;
          LoomAcceptedSendDtnDiagnostics.directoryUnavailableCount++;
          _recordResult('directory_unavailable');
          LoomTransportDiagnostics.event(
            'accepted_send_dtn_mirror',
            sendAttemptId: message.clientId,
            networkGeneration:
                LoomDefaultNetworkGeneration.current.generation,
            resultCategory: 'directory_unavailable',
          );
          continue;
        }

        try {
          await dtnWriter(
            destinationNodeDomain: route.destinationNodeDomain,
            senderAddress: receipt.address,
            recipientDevices: route.recipientDevices,
            conversationId: message.conversationId,
            clientId: message.clientId,
            type: message.type,
            ciphertext: message.ciphertext,
            protocolVersion: message.protocolVersion,
            replyToMessageId: message.replyToMessageId,
            metadata: message.metadata,
            createdAt: message.createdAt,
          );
          if (_disposed) return;
          _mirroredClientIds.add(message.clientId);
          persistedCount++;
          LoomAcceptedSendDtnDiagnostics.persistedCount++;
          _recordResult('persisted');
          LoomTransportDiagnostics.event(
            'accepted_send_dtn_mirror',
            sendAttemptId: message.clientId,
            networkGeneration:
                LoomDefaultNetworkGeneration.current.generation,
            resultCategory: 'persisted',
          );
        } catch (error) {
          failedCount++;
          LoomAcceptedSendDtnDiagnostics.failedCount++;
          _recordResult('failed', exceptionType: error.runtimeType.toString());
          LoomTransportDiagnostics.event(
            'accepted_send_dtn_mirror',
            sendAttemptId: message.clientId,
            networkGeneration:
                LoomDefaultNetworkGeneration.current.generation,
            exceptionType: error.runtimeType.toString(),
            resultCategory: 'failed',
          );
        }
      }
    }
  }

  void _recordResult(String result, {String? exceptionType}) {
    lastResult = result;
    lastExceptionType = exceptionType;
    lastUpdatedAt = _clock().toUtc();
    LoomAcceptedSendDtnDiagnostics.record(
      result,
      exceptionType: exceptionType,
    );
  }

  bool _isAcceptedOutgoing(LoomMessageRecord message, String ownAddress) {
    if (message.createdAt.toUtc().isBefore(_notBefore) ||
        message.senderAddress.toLowerCase() != ownAddress.toLowerCase()) {
      return false;
    }
    // A recipient receipt ends the need to create new forwarding replicas.
    return message.deliveryState == LoomDeliveryState.sent;
  }

  Future<LoomAcceptedSendRoute?> _resolveRoute(
    LoomConversation conversation, {
    required LoomIdentityPublic identity,
    required LoomRegistrationReceipt receipt,
  }) async {
    final injected = _routeResolver;
    if (injected != null) return injected(conversation);

    final supportPath = await _supportPathProvider();
    final securityPath = '$supportPath/loom_security.sqlite3';
    final securityStore = LoomSecurityStore.openFile(securityPath);
    final peerIdentityStore = LoomPeerIdentityStore.openFile(securityPath);
    try {
      final cache = LoomOfflineDeviceDirectoryCache(
        securityStore: securityStore,
        peerIdentityStore: peerIdentityStore,
      );
      if (conversation.kind == LoomConversationKind.self) {
        final devices = await cache.loadOwn(
          identity: identity,
          currentDeviceId: receipt.deviceId,
          now: _clock().toUtc(),
        );
        if (devices == null || devices.isEmpty) return null;
        return LoomAcceptedSendRoute(
          destinationNodeDomain: receipt.homeNode,
          recipientDevices: devices,
        );
      }

      final peerAddress = conversation.peerAddress;
      if (peerAddress == null || peerAddress.trim().isEmpty) return null;
      final peer = await cache.loadPeer(
        address: peerAddress,
        now: _clock().toUtc(),
      );
      if (peer == null || peer.devices.isEmpty) return null;
      return LoomAcceptedSendRoute(
        destinationNodeDomain: LoomAddress.parseCanonical(
          peer.address,
        ).homeNode,
        recipientDevices: peer.devices,
      );
    } finally {
      peerIdentityStore.close();
      securityStore.close();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    messagingListenable.removeListener(_requestDrain);
  }
}
