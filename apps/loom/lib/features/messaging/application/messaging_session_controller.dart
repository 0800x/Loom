import 'live_location_projection.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:geolocator/geolocator.dart';

import 'message_content.dart';
import '../../groups/application/groups_controller.dart';
import 'encrypted_media.dart';
import 'media_preparation.dart';
import '../../media/application/playback_controller.dart';

import '../../profile/application/local_avatar_store.dart';

import 'dart:io';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../connectivity/application/lan_resilience_controller.dart';
import '../../onboarding/application/onboarding_controller.dart';
import 'legacy_dtn_mailbox.dart';
import 'offline_device_directory_cache.dart';

typedef LoomNearbyOpaqueMessageSender =
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
      Map<String, Object?> metadata,
    });

typedef _LoomDtnFallbackCommitter =
    Future<void> Function({
      required String conversationId,
      required String clientId,
      required LoomMessageType type,
      required String ciphertext,
      required String protocolVersion,
      String? replyToMessageId,
      Map<String, Object?> metadata,
    });

final class LoomDtnCustodyPending implements Exception {
  const LoomDtnCustodyPending(this.clientId);

  final String clientId;

  @override
  String toString() => 'Message $clientId is durably queued for DTN delivery';
}

/// Decides whether an ordinary online Send failure may safely enter DTN.
///
/// DTN is a resilience transport, not an authorization bypass. Definitive
/// server responses (4xx, redirects), malformed protocol responses, and local
/// validation failures therefore remain authoritative. Only genuine transport
/// unavailability, timeouts, TLS/HTTP transport failures, and explicitly
/// retryable server failures may create durable DTN custody.
abstract final class LoomDtnFallbackPolicy {
  static bool shouldFallback(Object error) {
    if (error is LoomHttpStatusException) {
      return error.retryableOnAlternateRoute;
    }
    return error is LoomMessagingTransportUnavailable ||
        error is SocketException ||
        error is TimeoutException ||
        error is HandshakeException ||
        error is TlsException ||
        error is HttpException;
  }
}

enum LoomMessagingSessionStatus {
  idle,
  opening,
  syncing,
  ready,
  offline,
  error,
}

class LoomPeerPresence {
  const LoomPeerPresence({
    required this.online,
    required this.observedAt,
    this.lastSeenAt,
  });
  final bool online;
  final DateTime observedAt;
  final DateTime? lastSeenAt;
  bool get isFresh =>
      DateTime.now().toUtc().difference(observedAt) <
      const Duration(seconds: 45);
}

class LoomVisibleMessage {
  const LoomVisibleMessage({
    required this.record,
    required String text,
    required this.readable,
  }) : _plaintext = text;

  final LoomMessageRecord record;
  final String _plaintext;
  // Weak keys retain decoded content only as long as this readable snapshot.
  // Lock/logout clears the snapshots; no durable plaintext cache is introduced.
  static final _decoded = Expando<LoomMessageContent>();
  LoomMessageContent get content => readable
      ? (_decoded[this] ??= LoomMessageContent.decode(_plaintext))
      : const LoomMessageContent();
  String get text => readable ? content.preview : _plaintext;
  final bool readable;
}

/// Owns the durable encrypted message database, Home-Node sync lifecycle and
/// device-bound E2EE boundary for Saved Messages and direct conversations.
class LoomMessagingSessionController extends ChangeNotifier
    with WidgetsBindingObserver {
  LoomMessagingSessionController({
    required this.onboarding,
    LoomSelfMessageCodec? selfMessageCodec,
    LoomDeviceSecurityCore? deviceSecurityCore,
    LoomSecurityClient? securityClient,
    LoomUserSecurityClient? userSecurityClient,
    LoomNearbyOpaqueMessageSender? nearbyMessageSender,
  }) : _selfMessageCodec = selfMessageCodec ?? LoomSelfMessageCodec(),
       _deviceSecurityCore = deviceSecurityCore ?? LoomDeviceSecurityCoreV1(),
       _securityClient = securityClient ?? LoomSecurityClient(),
       _userSecurityClient = userSecurityClient ?? LoomUserSecurityClient(),
       // Keep the public constructor name; an initializing formal would expose a private name.
       // ignore: prefer_initializing_formals
       _nearbyMessageSender = nearbyMessageSender {
    _networkSubscription = LoomDefaultNetworkGeneration.events.listen(
      _onDefaultNetworkGenerationChanged,
    );
  }

  final LoomOnboardingController onboarding;
  final LoomSelfMessageCodec _selfMessageCodec;
  final LoomDeviceSecurityCore _deviceSecurityCore;
  final LoomSecurityClient _securityClient;
  final LoomUserSecurityClient _userSecurityClient;
  final LoomNearbyOpaqueMessageSender? _nearbyMessageSender;

  LoomMessagingSessionStatus status = LoomMessagingSessionStatus.idle;
  LoomMessagingStore? _store;
  LoomSecurityStore? _securityStore;
  LoomPeerIdentityStore? _peerIdentityStore;
  LoomOfflineDeviceDirectoryCache? _offlineDeviceDirectoryCache;
  LoomMessagingEngine? _engine;
  LoomMessagingApi? _api;
  LoomDirectMessageCodec? _directCodec;
  LoomLegacyDtnMailboxCoordinator? _legacyDtnMailbox;
  LoomMessagingClient? _homeClient;
  LoomRealtimeConnection? _realtime;
  StreamSubscription<LoomSyncEvent>? _realtimeSubscription;
  StreamSubscription<LoomDefaultNetworkSnapshot>? _networkSubscription;
  List<LoomConversation> conversations = const [];
  Map<String, List<LoomVisibleMessage>> visibleMessages = const {};
  int _readableEpoch = 0;
  ({
    String conversationId,
    File file,
    bool video,
    String kind,
    bool owned,
    bool music,
    bool sticker,
    List<double> waveform,
  })?
  pendingMedia;
  void stagePickedMedia(
    String conversationId,
    File file,
    bool video, {
    String? kind,
    bool owned = false,
    bool music = false,
    bool sticker = false,
    List<double> waveform = const [],
  }) {
    if (_disposed) {
      if (owned) {
        unawaited(file.delete().catchError((Object _) => file));
      }
      return;
    }
    _clearPendingMedia();
    pendingMedia = (
      conversationId: conversationId,
      file: file,
      video: video,
      kind: kind ?? (video ? 'video' : 'image'),
      owned: owned,
      music: music,
      sticker: sticker,
      waveform: List.unmodifiable(waveform),
    );
    notifyListeners();
  }

  void _clearPendingMedia() {
    final pending = pendingMedia;
    pendingMedia = null;
    if (pending != null && pending.owned) {
      unawaited(pending.file.delete().catchError((Object _) => pending.file));
    }
  }

  void discardPendingMedia() {
    _clearPendingMedia();
    if (!_disposed) {
      notifyListeners();
    }
  }

  void clearReadableState() {
    _readableEpoch++;
    _clearPendingMedia();
    _cancelLive();
    visibleMessages = const {};
    _groupViews.clear();
    _groupMessageSources.clear();
    notifyListeners();
  }

  String? errorMessage;
  LoomConnectivityState connectivity =
      LoomConnectivityState.nodeUnreachable;

  final Map<String, _PeerSecurityCache> _peerSecurityCache = {};
  final Map<String, String> _peerDisplayNames = {};
  final Map<String, String> _peerIdentityIds = {};
  String? peerIdentityId(String? address) =>
      address == null ? null : _peerIdentityIds[address.trim().toLowerCase()];
  final Map<String, String> _conversationTitles = {};
  List<LoomDeviceKeyBundle> _ownDevicesCache = const [];
  DateTime? _ownDevicesCachedAt;
  bool _displayNameHydrationRunning = false;
  bool _sendDrainRunning = false;
  bool _sendDrainRequested = false;
  Future<void>? _syncFuture;
  Future<void> _localRefreshTail = Future<void>.value();
  int _realtimeEpoch = 0;
  int? _realtimeRecoveryEpoch;
  bool _realtimeRecoveryRequested = false;
  bool _disposed = false;

  String? _activeConversationId;
  String? get activeConversationId => _activeConversationId;
  final _peerPresence = <String, LoomPeerPresence>{};
  final _deliveryAcknowledged = <String>{};
  Future<void>? _receiptFuture;
  Future<void>? _maintenanceFuture;
  Future<void>? _catalogueFuture;
  DateTime? _lastDirectoryRefresh;

  LoomPeerPresence? presenceFor(String conversationId) =>
      _peerPresence[conversationId];

  Object? _conversationWatcher;
  Map<String, LoomLocalConversationState> localConversationStates = const {};
  final _historyLimits = <String, int>{};
  final _moreHistory = <String>{};
  final _loadingHistory = <String>{};
  bool hasOlderMessages(String id) => _moreHistory.contains(id);
  bool loadingOlderMessages(String id) => _loadingHistory.contains(id);

  Future<void> loadOlderMessages(String id) async {
    if (_disposed ||
        LoomAppLock.instance.locked ||
        !_moreHistory.contains(id) ||
        !_loadingHistory.add(id)) {
      return;
    }
    final previousLimit = _historyLimits[id] ?? 50;
    _historyLimits[id] = previousLimit + 50;
    notifyListeners();
    try {
      await refreshLocalMessages();
    } catch (_) {
      _historyLimits[id] = previousLimit;
      errorMessage = 'Could not load earlier messages. Try again.';
    } finally {
      _loadingHistory.remove(id);
      if (!_disposed) notifyListeners();
    }
  }

  List<LoomMessageRecord> _historyWindow(String id) {
    final store = _store;
    if (store == null) return const [];
    final wanted = (_historyLimits[id] ?? 50) + 1;
    final records = <LoomMessageRecord>[];
    while (records.length < wanted) {
      final remaining = wanted - records.length;
      final page = store.listMessages(
        id,
        beforeMessage: records.lastOrNull,
        limit: remaining.clamp(1, 200),
      );
      records.addAll(page);
      if (page.length < remaining.clamp(1, 200)) break;
    }
    if (records.length == wanted) {
      _moreHistory.add(id);
      records.removeLast();
    } else {
      _moreHistory.remove(id);
    }
    return records;
  }

  LoomGroupsController? _groups;
  LoomGroupsController? get groupsController => _groups;
  final _groupMessageSources = <String, List<LoomGroupMessage>>{};
  final _groupViews = <String, List<LoomVisibleMessage>>{};

  void attachGroups(LoomGroupsController groups) {
    _groups?.removeListener(_groupsChanged);
    _groups = groups;
    groups.addListener(_groupsChanged);
    _groupsChanged();
  }

  void _groupsChanged() {
    if (_disposed || LoomAppLock.instance.locked) return;
    _mergeGroups();
    notifyListeners();
  }

  void _mergeGroups() {
    final groups = _groups;
    if (groups == null || LoomAppLock.instance.locked) return;
    final own = onboarding.receipt?.address ?? '';
    final home = onboarding.nodes.selectedEndpoint?.host ?? '';
    final catalogue = conversations
        .where((c) => c.kind != LoomConversationKind.group)
        .toList();
    final next = Map<String, List<LoomVisibleMessage>>.from(visibleMessages)
      ..removeWhere((id, _) => _groupViews.containsKey(id));
    final ids = groups.groups.map((g) => g.id).toSet();
    _groupViews.removeWhere((id, _) => !ids.contains(id));
    _groupMessageSources.removeWhere((id, _) => !ids.contains(id));
    for (final group in groups.groups) {
      final rows = groups.messages[group.id] ?? const <LoomGroupMessage>[];
      final previous = _groupMessageSources[group.id];
      final sameHistory =
          previous != null &&
          previous.length == rows.length &&
          List.generate(rows.length, (i) => i).every(
            (i) =>
                previous[i].operationId == rows[i].operationId &&
                previous[i].sequence == rows[i].sequence &&
                previous[i].location?['at'] == rows[i].location?['at'] &&
                previous[i].location?['stopped'] ==
                    rows[i].location?['stopped'],
          );
      if (!sameHistory) {
        _groupMessageSources[group.id] = rows;
        _groupViews[group.id] = List.unmodifiable(
          rows.reversed.map((m) {
            final member = group.members
                .where((p) => p.deviceId == m.senderDeviceId)
                .firstOrNull;
            final label = groups.senderLabel(m.senderDeviceId);
            final address = m.senderDeviceId == groups.ownDeviceId
                ? own
                : (member == null
                          ? null
                          : _groupIdentityAddress(member.identityId)) ??
                      '@${m.senderDeviceId}:$home';
            return LoomVisibleMessage(
              record: LoomMessageRecord(
                id: m.operationId,
                clientId: m.operationId,
                conversationId: group.id,
                senderAddress: address,
                type: LoomMessageType.text,
                ciphertext: '',
                protocolVersion: loomGroupProtocol,
                createdOrder: m.sequence,
                createdAt:
                    m.createdAt ??
                    DateTime.fromMillisecondsSinceEpoch(
                      m.sequence,
                      isUtc: true,
                    ),
                deliveryState: LoomDeliveryState.sent,
                metadata: {
                  'groupSenderLabel': label,
                  'groupTimestampKnown': m.createdAt != null,
                },
              ),
              text: LoomMessageContent(
                text: m.text,
                attachment: m.attachment,
                reply: m.reply,
                location: m.location,
              ).encode(),
              readable: true,
            );
          }),
        );
      }
      next[group.id] = _groupViews[group.id] ?? const [];
      final last = rows.lastOrNull;
      final entry = LoomConversation(
        id: group.id,
        kind: LoomConversationKind.group,
        title: group.title,
        updatedOrder: last?.createdAt?.millisecondsSinceEpoch ?? group.sequence,
        unreadCount: groups.unreadCounts[group.id] ?? 0,
        isMuted: false,
        isPinned: false,
      );
      catalogue.add(_store?.applyConversationPreferences(entry) ?? entry);
    }
    // Decoration can change flags. Always sort the final combined catalogue.
    catalogue.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final at = next[a.id]?.firstOrNull?.record.createdAt;
      final bt = next[b.id]?.firstOrNull?.record.createdAt;
      final byTime = (bt?.millisecondsSinceEpoch ?? b.updatedOrder).compareTo(
        at?.millisecondsSinceEpoch ?? a.updatedOrder,
      );
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    conversations = List.unmodifiable(catalogue);
    visibleMessages = Map.unmodifiable(next);
  }

  bool canSendToGroup(String id) =>
      _groups?.ready == true &&
      (_groups?.groups
              .where((g) => g.id == id)
              .firstOrNull
              ?.members
              .any((m) => m.deviceId == _groups?.ownDeviceId) ??
          false);

  bool isArchived(String id) => localConversationStates[id]?.archived ?? false;

  Future<void> setConversationArchived(String id, bool value) async {
    if (_disposed || LoomAppLock.instance.locked || _store == null) return;
    _store!.setConversationArchived(id, value);
    _refreshConversationPreferences();
  }

  Future<void> setConversationPinned(String id, bool value) async {
    if (_disposed || LoomAppLock.instance.locked || _store == null) return;
    _store!.setConversationPinned(id, value);
    _refreshConversationPreferences();
  }

  Future<void> setConversationMuted(
    String id,
    bool value, {
    DateTime? until,
  }) async {
    if (_disposed || LoomAppLock.instance.locked || _store == null) return;
    _store!.setConversationMuted(id, value, until: until);
    _refreshConversationPreferences();
  }

  Future<void> markConversationUnread(String id) async {
    if (_disposed || LoomAppLock.instance.locked || _store == null) return;
    _store!.setConversationMarkedUnread(id, true);
    _refreshConversationPreferences();
  }

  void _refreshConversationPreferences() {
    localConversationStates = _store!.localConversationStates();
    conversations = _store!
        .listConversations()
        .map(_decorateConversation)
        .toList(growable: false);
    _mergeGroups();
    notifyListeners();
  }

  Future<void> clearLocalConversationHistory(String id) async {
    if (_disposed || LoomAppLock.instance.locked || _store == null) return;
    _store!.clearLocalConversationHistory(id);
    await refreshLocalMessages();
  }

  void releaseConversationWatcher(Object owner) {
    if (identical(_conversationWatcher, owner)) {
      _conversationWatcher = null;
      _activeConversationId = null;
      _groups?.setActiveGroup(null);
    }
  }

  void watchConversation(String? conversationId, {Object? owner}) {
    _conversationWatcher = owner;
    if (_activeConversationId == conversationId) {
      return;
    }
    _activeConversationId = conversationId;
    _groups?.setActiveGroup(
      _groups?.groups.any((g) => g.id == conversationId) == true
          ? conversationId
          : null,
    );
    if (conversationId != null) {
      unawaited(_refreshPresence());
      unawaited(_refreshVisiblePeerProfile());
    }
  }

  Future<void>? _visibleProfileRefresh;
  DateTime? _lastVisibleProfileRefresh;
  String? _lastVisibleProfileAddress;

  Future<void> _refreshVisiblePeerProfile() async {
    if (_disposed || _visibleProfileRefresh != null) {
      return;
    }
    final active = conversations
        .where((c) => c.id == _activeConversationId)
        .firstOrNull;
    final address = active?.peerAddress;
    if (address == null || _securityStore == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    if (_lastVisibleProfileAddress == address &&
        _lastVisibleProfileRefresh != null &&
        now.difference(_lastVisibleProfileRefresh!) <
            const Duration(seconds: 30)) {
      return;
    }
    _lastVisibleProfileAddress = address;
    _lastVisibleProfileRefresh = now;
    _visibleProfileRefresh = () async {
      try {
        await _resolvePeerSecurity(address, force: true);
        if (!_disposed) {
          notifyListeners();
        }
      } catch (_) {
        /* The encrypted conversation remains usable offline. */
      }
    }();
    try {
      await _visibleProfileRefresh;
    } finally {
      _visibleProfileRefresh = null;
    }
  }

  Future<void> _refreshPresence() async {
    final id = _activeConversationId;
    final client = _homeClient;
    if (_disposed || id == null || client == null) {
      return;
    }
    try {
      final value = await client.fetchConversationPresence(id);
      if (_disposed) {
        return;
      }
      if (value['available'] == true) {
        _peerPresence[id] = LoomPeerPresence(
          online: value['online'] == true,
          observedAt: DateTime.now().toUtc(),
          lastSeenAt: DateTime.tryParse(
            value['lastSeenAt'] as String? ?? '',
          )?.toUtc(),
        );
        notifyListeners();
      }
    } catch (_) {
      /* Older/offline nodes have no fresh presence evidence. */
    }
  }

  Future<void> _acknowledgeReadableMessages() async {
    final client = _homeClient;
    final own = onboarding.receipt?.address.toLowerCase();
    if (_disposed || client == null || own == null) {
      return;
    }
    final ids = visibleMessages.values
        .expand((messages) => messages)
        .where(
          (m) =>
              m.readable &&
              m.record.senderAddress.toLowerCase() != own &&
              !m.record.id.startsWith('dtn_') &&
              !_deliveryAcknowledged.contains(m.record.clientId),
        )
        .map((m) => m.record.clientId)
        .take(50)
        .toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    try {
      await client.acknowledgeReceived(ids);
      if (!_disposed) {
        _deliveryAcknowledged.addAll(ids);
      }
    } catch (_) {
      /* Retry from the durable readable inbox on the next sync. */
    }
  }

  bool get isSynchronizing => _syncFuture != null;
  int get pendingSendCount => _disposed ? 0 : (_store?.pendingSendCount ?? 0);

  Future<void> markConversationRead(String conversationId) async {
    final ownAddress = onboarding.receipt?.address;
    if (_disposed || ownAddress == null || _store == null) {
      return;
    }
    if (_groups?.groups.any((g) => g.id == conversationId) == true) {
      _groups!.markGroupRead(conversationId);
      _store!.setConversationMarkedUnread(conversationId, false);
      _refreshConversationPreferences();
      return;
    }
    final readable = visibleMessagesFor(
      conversationId,
    ).where((m) => m.readable);
    _store!.setConversationMarkedUnread(conversationId, false);
    _store!.markMessagesRead(
      conversationId,
      ownAddress,
      readable.map((m) => m.record.clientId),
    );
    conversations = _store!
        .listConversations()
        .map(_decorateConversation)
        .toList(growable: false);
    localConversationStates = _store!.localConversationStates();
    notifyListeners();
    _scheduleSendDrain();
  }

  /// Nearby intake has already committed locally; it must not wait for a
  /// failing Internet request before becoming visible in the conversation.
  Future<void> restoreSavedConversation() async {
    if (_disposed || _store == null || LoomAppLock.instance.locked) return;
    _store!.restoreLocalSavedConversation();
    await refreshLocalMessages();
  }

  Future<void> deleteLocalMessage(
    String conversationId,
    String clientId,
  ) async {
    if (_disposed || _store == null || LoomAppLock.instance.locked) return;
    _store!.deleteLocalMessage(conversationId, clientId);
    await refreshLocalMessages();
  }

  Future<void> deleteLocalConversation(String conversationId) async {
    if (_disposed || _store == null || LoomAppLock.instance.locked) return;
    _store!.deleteLocalConversation(conversationId);
    await refreshLocalMessages();
  }

  Future<void> refreshLocalMessages() async {
    if (_disposed) {
      return;
    }
    await _refreshLocal();
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  Future<void> retryQueuedMessages() async {
    if (_disposed) {
      return;
    }
    if (_engine == null) {
      await open();
      return;
    }
    _store?.retryPendingSends(includeRejected: true);
    _scheduleSendDrain();
    await synchronize();
  }

  bool _cleanedPlaybackCache = false;
  Future<void> open() async {
    if (_disposed ||
        status == LoomMessagingSessionStatus.opening ||
        status == LoomMessagingSessionStatus.syncing) {
      return;
    }
    final receipt = onboarding.receipt;
    final identity = onboarding.committedIdentity;
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (receipt == null || identity == null || endpoint == null) {
      _setError('Messaging requires a completed Loom identity registration.');
      return;
    }
    status = LoomMessagingSessionStatus.opening;
    errorMessage = null;
    notifyListeners();
    try {
      if (!_cleanedPlaybackCache) {
        _cleanedPlaybackCache = true;
        try {
          final temp = await getTemporaryDirectory();
          for (final name in [
            'loom_media_view',
            'loom_media_prepare',
            'loom_media_record',
            'loom_media_playback',
            'loom_music_library',
            'loom_media_keyboard',
          ]) {
            final stale = Directory('${temp.path}/$name');
            if (await stale.exists()) {
              await stale.delete(recursive: true);
            }
          }
          try {
            await LoomMediaPreparation.clearStaleNativeCache();
          } catch (_) {}
        } catch (_) {
          /* A stale playback cache must not block account opening. */
        }
      }
      final support = await getApplicationSupportDirectory();
      if (_disposed) {
        return;
      }
      final store = _store ??= LoomMessagingStore.openFile(
        '${support.path}/loom-messages-v1.sqlite3',
      );
      store.repairLegacyDeliveryEvidence(receipt.address);
      final securityPath = '${support.path}/loom_security.sqlite3';
      _securityStore ??= LoomSecurityStore.openFile(securityPath);
      _peerIdentityStore ??= LoomPeerIdentityStore.openFile(securityPath);
      _offlineDeviceDirectoryCache ??= LoomOfflineDeviceDirectoryCache(
        securityStore: _securityStore!,
        peerIdentityStore: _peerIdentityStore!,
      );
      _rememberStoredConversationTitles();

      Future<String> tokenProvider() => _accessToken();
      final deviceProofProvider = await onboarding.deviceRequestProofProvider();
      if (_disposed) {
        return;
      }
      final homeClient = LoomMessagingClient(
        baseUri: endpoint,
        accessTokenProvider: tokenProvider,
        deviceProofProvider: deviceProofProvider,
        refreshRejectedToken: onboarding.refreshRejectedToken,
      );
      _homeClient = homeClient;
      _legacyDtnMailbox?.close();
      _legacyDtnMailbox = LoomLegacyDtnMailboxCoordinator(
        client: LoomV2DeliveryClient(
          baseUri: endpoint,
          accessTokenProvider: tokenProvider,
          deviceProofProvider: deviceProofProvider,
        ),
        deviceSecurity: _deviceSecurityCore,
        identityId: identity.identityId,
        deviceId: receipt.deviceId,
        ownAddress: receipt.address,
        applicationSupportPath: support.path,
      );
      _api = homeClient;
      _directCodec = LoomDirectMessageCodec(
        signer: (payload) => _deviceSecurityCore.signDevicePayload(
          identityId: identity.identityId,
          deviceId: receipt.deviceId,
          payload: payload,
        ),
        opener: ({required payload, required associatedData}) =>
            _deviceSecurityCore.openSealedPayload(
              identityId: identity.identityId,
              deviceId: receipt.deviceId,
              payload: payload,
              associatedData: associatedData,
            ),
      );
      _engine?.dispose();
      _engine = LoomMessagingEngine(
        store: store,
        client: _withNearbySendFallback(homeClient),
        senderAddress: receipt.address,
        encoder: _SessionMessageEncoder(controller: this),
      );

      // The restored vault already authorizes local history. Show that history
      // before an offline Home Node/token refresh can consume its timeout.
      await _refreshLocal();
      if (_disposed) {
        return;
      }
      if (LoomAppLock.instance.locked) {
        status = LoomMessagingSessionStatus.offline;
        return;
      }
      notifyListeners();

      if ((onboarding.accessToken == null || onboarding.accessToken!.isEmpty) &&
          !await onboarding.refreshAccessToken()) {
        if (_disposed) {
          return;
        }
        await _refreshLocal();
        status = LoomMessagingSessionStatus.offline;
        connectivity = LoomConnectivityState.nodeUnreachable;
        errorMessage =
            'Encrypted messages are available offline. Reconnect the Home Node to refresh this session.';
        notifyListeners();
        return;
      }

      if (_disposed) {
        return;
      }
      final trustedNode = onboarding.nodes.selectedNode;
      if (trustedNode == null) {
        throw const LoomProtocolException(
          'Trusted Home Node identity unavailable',
        );
      }
      // The durable account cursor lets realtime catch up independently of
      // LAN discovery and the REST conversation catalogue.
      unawaited(_connectRealtime(homeClient, expectedEpoch: _realtimeEpoch));
      final routes = await LoomLanResilienceController().routesForHomeNode(
        trustedNode: trustedNode,
        homeEndpoint: endpoint,
        accessTokenProvider: tokenProvider,
        deviceProofProvider: deviceProofProvider,
        refreshRejectedToken: onboarding.refreshRejectedToken,
      );
      if (_disposed) {
        return;
      }
      final routedClient = LoomRoutedMessagingApi(
        homeNodeId: trustedNode.nodeId,
        routes: routes,
      );
      _api = routedClient;
      _engine?.dispose();
      _engine = LoomMessagingEngine(
        store: store,
        client: _withNearbySendFallback(routedClient),
        senderAddress: receipt.address,
        encoder: _SessionMessageEncoder(controller: this),
      );
      await synchronize();
      if (_disposed) {
        return;
      }
      connectivity = routedClient.state;
    } catch (error) {
      if (_disposed) {
        return;
      }
      status = LoomMessagingSessionStatus.offline;
      connectivity = LoomConnectivityState.nodeUnreachable;
      errorMessage = _safeError(error);
      await _refreshLocal();
      notifyListeners();
    }
  }

  LoomMessagingApi _withNearbySendFallback(LoomMessagingApi primary) {
    final fallback = _nearbyMessageSender;
    if (fallback == null) {
      return primary;
    }
    return _LoomSendFallbackMessagingApi(
      primary: primary,
      fallback:
          ({
            required conversationId,
            required clientId,
            required type,
            required ciphertext,
            required protocolVersion,
            replyToMessageId,
            metadata = const <String, Object?>{},
          }) => _persistDtnFallback(
            fallback: fallback,
            conversationId: conversationId,
            clientId: clientId,
            type: type,
            ciphertext: ciphertext,
            protocolVersion: protocolVersion,
            replyToMessageId: replyToMessageId,
            metadata: metadata,
          ),
    );
  }

  Future<void> _persistDtnFallback({
    required LoomNearbyOpaqueMessageSender fallback,
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final receipt = onboarding.receipt;
    final conversation = (_store?.listConversations(limit: 500) ?? const [])
        .where((item) => item.id == conversationId)
        .firstOrNull;
    if (receipt == null || conversation == null) {
      throw StateError('DTN routing context is unavailable');
    }

    late final String destinationNodeDomain;
    late final List<LoomDeviceKeyBundle> recipientDevices;
    if (conversation.kind == LoomConversationKind.self) {
      destinationNodeDomain = receipt.homeNode;
      recipientDevices = await _ownDevices();
    } else if (conversation.kind == LoomConversationKind.direct) {
      final peerAddress = conversation.peerAddress;
      if (peerAddress == null || peerAddress.isEmpty) {
        throw StateError('Direct DTN destination address is unavailable');
      }
      final peer = await _resolvePeerSecurity(peerAddress);
      if (peer.devices.isEmpty) {
        throw StateError('Peer has no active DTN recipient devices');
      }
      destinationNodeDomain = LoomAddress.parseCanonical(
        peer.address,
      ).homeNode;
      recipientDevices = peer.devices;
    } else {
      throw StateError('DTN fallback is not enabled for this chat type');
    }

    await fallback(
      destinationNodeDomain: destinationNodeDomain,
      senderAddress: receipt.address,
      recipientDevices: recipientDevices,
      conversationId: conversationId,
      clientId: clientId,
      type: type,
      ciphertext: ciphertext,
      protocolVersion: protocolVersion,
      replyToMessageId: replyToMessageId,
      metadata: metadata,
    );
  }

  Future<String> _accessToken() async {
    final expiresAt = onboarding.accessTokenExpiresAt;
    if (onboarding.accessToken == null ||
        onboarding.accessToken!.isEmpty ||
        (expiresAt != null &&
            expiresAt.isBefore(
              DateTime.now().toUtc().add(const Duration(seconds: 30)),
            ))) {
      if (!await onboarding.refreshAccessToken()) {
        throw const LoomProtocolException('Access token unavailable');
      }
    }
    final current = onboarding.accessToken;
    if (current == null || current.isEmpty) {
      throw const LoomProtocolException('Access token unavailable');
    }
    return current;
  }

  Future<void> synchronize() {
    if (_disposed || _engine == null) {
      return Future<void>.value();
    }
    return _syncFuture ??= Future<void>.microtask(_synchronize).whenComplete(
      () {
        _syncFuture = null;
        notifyListeners();
      },
    );
  }

  Future<void> _synchronize() async {
    final engine = _engine;
    if (engine == null) {
      return;
    }
    // Preserve the stable online/offline banner during background polling.
    if (status != LoomMessagingSessionStatus.ready &&
        status != LoomMessagingSessionStatus.offline) {
      status = LoomMessagingSessionStatus.syncing;
    }
    notifyListeners();
    try {
      _rememberStoredConversationTitles();
      // First-contact delivery can create the recipient conversation on the
      // Node before this device has ever searched for the sender. Hydrate the
      // catalogue before applying message events so the local SQLite foreign
      // key (message -> conversation) is always satisfied.
      await _refreshConversationCatalogue();
      if (_disposed) {
        return;
      }
      // A large offline outbox must not block incoming messages and receipts.
      _scheduleSendDrain();
      await engine.synchronize();
      if (_disposed) {
        return;
      }
      _store?.pruneSeenEvents(
        DateTime.now().toUtc().subtract(const Duration(days: 30)),
      );
      await _refreshLocal();
      if (_disposed) {
        return;
      }
      final transportClient = engine.client is _LoomSendFallbackMessagingApi
          ? (engine.client as _LoomSendFallbackMessagingApi).primary
          : engine.client;
      connectivity = transportClient is LoomRoutedMessagingApi
          ? transportClient.state
          : LoomConnectivityState.online;
      status = LoomMessagingSessionStatus.ready;
      errorMessage = null;
      notifyListeners();
      unawaited(_refreshPresence());
      unawaited(onboarding.synchronizeProfile());
      unawaited(_refreshVisiblePeerProfile());
      _receiptFuture ??= _acknowledgeReadableMessages().whenComplete(
        () => _receiptFuture = null,
      );
      _catalogueFuture ??= _refreshConversationCatalogue().whenComplete(
        () => _catalogueFuture = null,
      );
      _maintenanceFuture ??= _maintainInbox().whenComplete(
        () => _maintenanceFuture = null,
      );
    } catch (error) {
      if (_disposed) {
        return;
      }
      await _refreshLocal();
      status = LoomMessagingSessionStatus.offline;
      connectivity = LoomConnectivityState.nodeUnreachable;
      errorMessage = _safeError(error);
      notifyListeners();
    }
  }

  Future<void> _refreshConversationCatalogue() async {
    try {
      final api = _api;
      if (api != null) {
        final remote = await api.fetchConversations();
        if (_disposed) {
          return;
        }
        for (final conversation in remote) {
          _store?.upsertConversation(_decorateConversation(conversation));
        }
        await _refreshLocal();
        if (!_disposed) {
          notifyListeners();
        }
      }
    } catch (_) {
      // The durable event stream remains usable during a catalogue outage.
    }
  }

  Future<void> _maintainInbox() async {
    try {
      await _legacyDtnMailbox?.synchronize();
    } catch (_) {
      // Relay mailbox outages must not hold ordinary incoming messages hostage.
    }
    if (_disposed) {
      return;
    }
    final now = DateTime.now().toUtc();
    if (_lastDirectoryRefresh == null ||
        now.difference(_lastDirectoryRefresh!) >= const Duration(minutes: 2)) {
      _lastDirectoryRefresh = now;
      // Network key-directory refresh happens outside the serialized local
      // decryption queue. New messages can still use previously verified keys.
      final peers = conversations
          .map((c) => c.peerAddress)
          .whereType<String>()
          .toSet();
      for (final peer in peers) {
        if (_disposed) {
          return;
        }
        try {
          await _resolvePeerSecurity(peer, force: true);
        } catch (_) {}
      }
      if (_disposed) {
        return;
      }
      try {
        await _ownDevices(force: true);
      } catch (_) {}
    }
    if (_disposed) {
      return;
    }
    try {
      await _refreshLocal();
    } catch (_) {}
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<LoomConversation?> startConversation(String address) async {
    final receipt = onboarding.receipt;
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (receipt == null || endpoint == null) {
      _setError('A verified Home Node session is required to start a chat.');
      return null;
    }
    final normalized = address.trim();
    // Opening local history never needs an online directory round trip.
    // Encryption still resolves/pins recipient keys when a message is sent.
    try {
      final canonical = LoomAddress.normalizeInput(
        normalized,
        homeNode: receipt.homeNode,
      ).canonical;
      final existing = conversations
          .where(
            (c) =>
                c.kind == LoomConversationKind.direct &&
                c.peerAddress?.toLowerCase() == canonical.toLowerCase(),
          )
          .firstOrNull;
      if (existing != null) {
        return existing;
      }
    } on FormatException {
      /* The normal resolver below reports invalid input. */
    }
    if (normalized.toLowerCase() == receipt.address.toLowerCase()) {
      await restoreSavedConversation();
      return conversations
          .where(
            (conversation) => conversation.kind == LoomConversationKind.self,
          )
          .firstOrNull;
    }
    try {
      final peer = await _resolvePeerSecurity(normalized, force: true);
      if (peer.devices.isEmpty) {
        throw StateError('The peer has no active encryption devices');
      }
      final proof = await onboarding.deviceRequestProofProvider();
      final createdConversation = await _userSecurityClient
          .createDirectConversation(
            baseUri: endpoint,
            accessToken: await _accessToken(),
            address: peer.address,
            deviceProofProvider: proof,
          );
      final conversation = _decorateConversation(createdConversation);
      _store?.upsertConversation(conversation);
      _store?.restoreLocalConversation(conversation.id);
      await _refreshLocal();
      notifyListeners();
      return conversation;
    } catch (error) {
      errorMessage = _safeError(error);
      notifyListeners();
      return null;
    }
  }

  List<LoomMessageRecord> messagesFor(
    String conversationId, {
    int limit = 50,
  }) => _store?.listMessages(conversationId, limit: limit) ?? const [];

  List<LoomVisibleMessage> visibleMessagesFor(String conversationId) =>
      visibleMessages[conversationId] ?? const [];

  Future<bool> sendText(
    String conversationId,
    String plaintext, {
    String? replyToMessageId,
    LoomVisibleMessage? reply,
    LoomMessageContent? content,
  }) async {
    if (content == null &&
        (plaintext.trim().isEmpty || plaintext.length > 32000)) {
      return false;
    }
    if (_disposed || LoomAppLock.instance.locked) {
      return false;
    }
    if (_groups?.groups.any((g) => g.id == conversationId) == true) {
      return _groups!.sendContent(
        conversationId,
        content ??
            LoomMessageContent(
              text: plaintext.trim(),
              reply: reply == null
                  ? null
                  : {
                      'clientId': reply.record.clientId,
                      'text': reply.content.replyExcerpt.substring(
                        0,
                        min(reply.content.replyExcerpt.length, 1024),
                      ),
                      'sender': reply.record.senderAddress,
                    },
            ),
      );
    }
    final engine = _engine;
    final conversation = conversations
        .where((item) => item.id == conversationId)
        .firstOrNull;
    if (engine == null || conversation == null) {
      _setError('Open a synchronized conversation before sending.');
      return false;
    }
    if (conversation.kind == LoomConversationKind.group) {
      _setError('Group E2EE requires MLS and is not enabled yet.');
      return false;
    }
    try {
      final document =
          content ??
          (reply == null &&
                  !plaintext.trim().startsWith(LoomMessageContent.prefix)
              ? null
              : LoomMessageContent(
                  text: plaintext.trim(),
                  reply: reply == null
                      ? null
                      : {
                          'clientId': reply.record.clientId,
                          'text': reply.content.replyExcerpt.substring(
                            0,
                            min(reply.content.replyExcerpt.length, 1024),
                          ),
                          'sender': reply.record.senderAddress,
                        },
                ));
      if (document == null) {
        await engine.queueText(
          conversationId: conversationId,
          plaintext: plaintext,
          replyToMessageId: replyToMessageId,
        );
      } else {
        await engine.queueContent(
          conversationId: conversationId,
          encodedContent: document.encode(),
          replyToMessageId: replyToMessageId,
        );
      }
      if (_disposed) {
        return false;
      }
      await _refreshLocal();
      errorMessage = null;
      notifyListeners();
      _scheduleSendDrain();
      return true;
    } catch (error) {
      if (_disposed) {
        return false;
      }
      errorMessage = _safeError(error);
      await _refreshLocal();
      notifyListeners();
      return false;
    }
  }

  int get mediaUploadLimit =>
      (onboarding.nodes.selectedLiveInfo?.maxMediaBytes ?? 32 * 1024 * 1024)
          .clamp(1, LoomEncryptedMedia.maxBytes);

  Future<bool> sendMedia(
    String conversationId,
    File source,
    String kind, {
    String caption = '',
    bool music = false,
    bool sticker = false,
    List<double> waveform = const [],
    Duration? duration,
    LoomVisibleMessage? reply,
    Future<bool> Function(LoomMessageContent)? publishContent,
  }) async {
    if (publishContent == null &&
        _groups?.groups.any((g) => g.id == conversationId) == true) {
      publishContent = (content) =>
          _groups!.sendContent(conversationId, content);
    }
    File? encryptedFile;
    Uint8List? clear;
    final epoch = _readableEpoch;
    try {
      final api = _api;
      final endpoint = onboarding.nodes.selectedEndpoint;
      if (api == null ||
          endpoint == null ||
          endpoint.scheme != 'https' ||
          LoomAppLock.instance.locked) {
        throw StateError('A secure Home Node connection is required');
      }
      await onboarding.nodes.refreshMediaPolicy();
      if (_disposed ||
          LoomAppLock.instance.locked ||
          endpoint != onboarding.nodes.selectedEndpoint) {
        return false;
      }
      final length = await source.length();
      if (length < 1 || length > mediaUploadLimit) {
        throw FormatException(
          'Server file limit: ${(mediaUploadLimit / 1048576).toStringAsFixed(1)} MiB',
        );
      }
      if (!const [
        'image',
        'video',
        'audio',
        'video_note',
        'file',
      ].contains(kind)) {
        throw const FormatException('Invalid media kind');
      }
      final metadata = kind == 'file'
          ? <String, Object?>{}
          : await LoomMediaPreparation.dimensions(source, kind);
      if (kind == 'audio') {
        duration = await LoomPlaybackController.inspectDuration(source);
        if (!music && duration < const Duration(milliseconds: 700)) {
          throw const FormatException('Recording too short');
        }
      }
      clear = await source.readAsBytes();
      final sealed = await LoomEncryptedMedia.encrypt(clear);
      clear.fillRange(0, clear.length, 0);
      clear = null;
      final temp = await getTemporaryDirectory();
      final folder = await Directory(
        '${temp.path}/loom_upload',
      ).create(recursive: true);
      final nonce = base64UrlEncode(
        List.generate(24, (_) => Random.secure().nextInt(256)),
      );
      encryptedFile = File('${folder.path}/$nonce.enc');
      await encryptedFile.writeAsBytes(sealed.bytes, flush: true);
      if (_disposed ||
          LoomAppLock.instance.locked ||
          epoch != _readableEpoch) {
        return false;
      }
      final receipt = await api.uploadEncryptedAttachment(
        conversationId: conversationId,
        encryptedFile: encryptedFile,
        contentType: 'application/octet-stream',
      );
      if (!RegExp(r'^att_[a-f0-9]{64}$').hasMatch(receipt.attachmentId)) {
        throw StateError(
          'Update the Home Node to enable encrypted media downloads',
        );
      }
      if (_disposed ||
          LoomAppLock.instance.locked ||
          epoch != _readableEpoch) {
        return false;
      }
      final uri = endpoint.resolve(
        '/api/v1/attachments/${receipt.attachmentId}',
      );
      final media = <String, Object?>{
        'kind': kind,
        if (kind == 'image' && sticker) 'sticker': true,
        'url': uri.toString(),
        'key': sealed.key,
        'bytes': length,
        ...metadata,
        if (kind == 'audio' || kind == 'file')
          'name': source.uri.pathSegments.last.substring(
            0,
            min(200, source.uri.pathSegments.last.length),
          ),
        if (kind == 'audio') 'music': music,
        if (kind == 'audio' && duration != null)
          'durationMs': duration.inMilliseconds,
        if (kind == 'audio' && waveform.isNotEmpty)
          'waveform': waveform.take(64).map((v) => v.clamp(0.0, 1.0)).toList(),
      };
      // Cache BEFORE publishing the message; the UI can immediately decrypt
      // its own local ciphertext even when the source draft is later deleted.
      // A full disk/cache failure must not prevent a successfully uploaded send.
      try {
        await LoomEncryptedMedia.cacheEncrypted(
          media,
          sealed.bytes,
          endpoint.host,
        );
      } catch (_) {}
      final quote = reply == null
          ? null
          : <String, Object?>{
              'clientId': reply.record.clientId,
              'text': reply.content.replyExcerpt.substring(
                0,
                min(reply.content.replyExcerpt.length, 1024),
              ),
              'sender': reply.record.senderAddress,
            };
      final document = LoomMessageContent(
        text: caption,
        reply: quote,
        attachment: media,
      );
      if (publishContent != null) return await publishContent(document);
      return await sendText(
        conversationId,
        '',
        replyToMessageId: reply?.record.id.startsWith('local:') == false
            ? reply!.record.id
            : null,
        content: document,
      );
    } catch (_) {
      if (!_disposed) {
        errorMessage =
            'Media could not be sent. Check the 32 MB limit and Home Node version, then retry.';
        notifyListeners();
      }
      return false;
    } finally {
      final remaining = clear;
      if (remaining != null) {
        remaining.fillRange(0, remaining.length, 0);
      }
      if (encryptedFile != null) {
        try {
          await encryptedFile.delete();
        } catch (_) {}
      }
    }
  }

  Timer? _liveTimer;
  String? _liveConversationId;
  String? _liveSession;
  DateTime? _liveUntil;
  Map<String, Object?>? _livePoint;
  bool _liveBusy = false;
  int _liveEpoch = 0;
  bool _observingLive = false;
  String? get liveConversationId => _liveConversationId;
  String? get liveSessionId => _liveSession;
  bool _liveStarting = false;

  Future<Position> currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services are disabled');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission is required');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 30),
      ),
    );
  }

  Future<bool> sendLocation(
    String conversationId,
    double latitude,
    double longitude,
  ) => sendText(
    conversationId,
    '',
    content: LoomMessageContent(
      location: {
        'lat': latitude,
        'lon': longitude,
        'at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
    ),
  );

  Future<bool> startLiveLocation(
    String conversationId,
    Duration duration, {
    Position? initialPosition,
  }) async {
    if (_liveStarting) return false;
    _liveStarting = true;
    try {
      if (duration <= Duration.zero || duration > const Duration(hours: 1)) {
        return false;
      }
      await stopLiveLocation();
      final epoch = ++_liveEpoch;
      final position =
          initialPosition != null &&
              DateTime.now().difference(initialPosition.timestamp).abs() <
                  const Duration(seconds: 30)
          ? initialPosition
          : await currentPosition();
      if (_disposed ||
          epoch != _liveEpoch ||
          LoomAppLock.instance.locked ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
        return false;
      }
      _liveConversationId = conversationId;
      _liveSession = base64UrlEncode(
        List.generate(24, (_) => Random.secure().nextInt(256)),
      );
      _liveUntil = DateTime.now().toUtc().add(duration);
      _livePoint = _point(position);
      final ok = await sendText(
        conversationId,
        '',
        content: LoomMessageContent(location: _livePoint),
      );
      if (!ok || epoch != _liveEpoch) {
        _cancelLive();
        return false;
      }
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.detached) {
        await stopLiveLocation();
        return false;
      }
      WidgetsBinding.instance.addObserver(this);
      _observingLive = true;
      _liveTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_updateLive()),
      );
      notifyListeners();
      return true;
    } finally {
      _liveStarting = false;
    }
  }

  Map<String, Object?> _point(Position position) => {
    'lat': position.latitude,
    'lon': position.longitude,
    'at': DateTime.now().toUtc().millisecondsSinceEpoch,
    'session': _liveSession,
    'until': _liveUntil!.millisecondsSinceEpoch,
    'stopped': false,
  };

  Future<void> _updateLive() async {
    if (_liveBusy || _liveConversationId == null) {
      return;
    }
    if (LoomAppLock.instance.locked ||
        !DateTime.now().toUtc().isBefore(_liveUntil!)) {
      await stopLiveLocation();
      return;
    }
    _liveBusy = true;
    final epoch = _liveEpoch;
    try {
      final position = await currentPosition();
      if (_disposed || epoch != _liveEpoch || LoomAppLock.instance.locked) {
        return;
      }
      if (!DateTime.now().toUtc().isBefore(_liveUntil!)) {
        await stopLiveLocation();
        return;
      }
      _livePoint = _point(position);
      await sendText(
        _liveConversationId!,
        '',
        content: LoomMessageContent(location: _livePoint),
      );
    } catch (_) {
      // Keep the previous authenticated point; never invent a GPS fix.
    } finally {
      _liveBusy = false;
    }
  }

  Future<void> stopLiveLocation() async {
    final conversation = _liveConversationId, point = _livePoint;
    _cancelLive();
    if (!_disposed) {
      notifyListeners();
    }
    if (conversation != null &&
        point != null &&
        !_disposed &&
        !LoomAppLock.instance.locked) {
      await sendText(
        conversation,
        '',
        content: LoomMessageContent(
          location: {
            ...point,
            'at': DateTime.now().toUtc().millisecondsSinceEpoch,
            'stopped': true,
          },
        ),
      );
    }
  }

  void _cancelLive() {
    _liveEpoch++;
    _liveTimer?.cancel();
    _liveTimer = null;
    _liveConversationId = null;
    _liveSession = null;
    _livePoint = null;
    _liveUntil = null;
    if (_observingLive) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _observingLive = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(stopLiveLocation());
    }
  }

  void _scheduleSendDrain() {
    if (_disposed) {
      return;
    }
    _sendDrainRequested = true;
    if (_sendDrainRunning) {
      return;
    }
    unawaited(_drainQueuedSends());
  }

  Future<void> _drainQueuedSends() async {
    if (_sendDrainRunning || _disposed) {
      return;
    }
    _sendDrainRunning = true;
    try {
      do {
        _sendDrainRequested = false;
        final engine = _engine;
        if (engine == null) {
          return;
        }
        await engine.flushDue();
        if (engine.lastSendError != null) {
          errorMessage = engine.lastSendError;
        }
        await _refreshLocal();
        if (!_disposed) {
          notifyListeners();
        }
      } while (_sendDrainRequested && !_disposed);
    } catch (error) {
      errorMessage = _safeError(error);
      try {
        await _refreshLocal();
      } catch (_) {}
      if (!_disposed) {
        notifyListeners();
      }
    } finally {
      _sendDrainRunning = false;
      if (_sendDrainRequested && !_disposed) {
        _scheduleSendDrain();
      }
    }
  }

  Future<LoomOpaqueEnvelope> _encodeText({
    required String conversationId,
    required String plaintext,
    String? replyToMessageId,
  }) async {
    final conversation =
        (_store?.listConversations() ?? const <LoomConversation>[])
            .where((item) => item.id == conversationId)
            .firstOrNull;
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    if (conversation == null || identity == null || receipt == null) {
      throw StateError('Messaging encryption context is unavailable');
    }
    if (conversation.kind == LoomConversationKind.self) {
      return LoomOpaqueEnvelope(
        ciphertext: await _selfMessageCodec.encryptText(
          identityId: identity.identityId,
          conversationId: conversationId,
          plaintext: plaintext,
        ),
        protocolVersion: LoomSelfMessageCodec.protocolVersion,
      );
    }
    if (conversation.kind != LoomConversationKind.direct) {
      throw StateError(
        'No production envelope encoder exists for this chat type',
      );
    }
    final peerAddress = conversation.peerAddress;
    final codec = _directCodec;
    if (peerAddress == null || peerAddress.isEmpty || codec == null) {
      throw StateError('Direct-message encryption context is incomplete');
    }
    final peer = await _resolvePeerSecurity(peerAddress);
    if (peer.devices.isEmpty) {
      throw StateError('Peer has no active encryption devices');
    }
    final ownDevices = await _ownDevices();
    final allDevices = <LoomDeviceKeyBundle>[...peer.devices, ...ownDevices];
    return LoomOpaqueEnvelope(
      ciphertext: await codec.encryptText(
        conversationId: conversationId,
        plaintext: plaintext,
        senderAddress: receipt.address,
        senderIdentityId: identity.identityId,
        senderDeviceId: receipt.deviceId,
        recipientDevices: allDevices,
        replyToMessageId: replyToMessageId,
      ),
      protocolVersion: LoomDirectMessageCodec.protocolVersion,
    );
  }

  /// Directory-verified first-use pins do not require saving a contact. Existing
  /// account/device pins still block changed or revoked keys.
  String? _groupIdentityAddress(String identityId) =>
      _peerIdentityIds.entries
          .where((entry) => entry.value == identityId)
          .firstOrNull
          ?.key ??
      _peerIdentityStore?.pinForIdentity(identityId)?.address;

  String? groupIdentityLabel(String identityId) {
    if (identityId == onboarding.committedIdentity?.identityId) {
      return onboarding.displayName.trim().isNotEmpty
          ? onboarding.displayName
          : onboarding.receipt?.address;
    }
    final address =
        _peerIdentityIds.entries
            .where((entry) => entry.value == identityId)
            .firstOrNull
            ?.key ??
        _peerIdentityStore?.pinForIdentity(identityId)?.address;
    return address == null ? null : _peerDisplayNames[address] ?? address;
  }

  Future<LoomDeviceKeyBundle> trustedGroupDevice(
    LoomGroupMember member,
  ) async {
    if (member.identityId == onboarding.committedIdentity?.identityId) {
      if (member.accountId != onboarding.receipt?.accountId) {
        throw StateError('Own MLS account mismatch');
      }
      return (await _ownDevices(
        force: true,
      )).singleWhere((d) => d.deviceId == member.deviceId);
    }
    final pin = _peerIdentityStore?.pinForIdentity(member.identityId);
    String? address = pin?.address;
    if (address == null) {
      final support = await getApplicationSupportDirectory();
      final contacts = LoomContactStore.openFile(
        '${support.path}/loom-contacts-v1.sqlite3',
      );
      try {
        address = contacts
            .list()
            .where(
              (c) =>
                  c.identityId == member.identityId &&
                  c.securityState != LoomContactSecurityState.changed,
            )
            .firstOrNull
            ?.canonicalAddress;
      } finally {
        contacts.close();
      }
    }
    if (address == null) {
      if (_store == null) await open();
      final endpoint = onboarding.nodes.selectedEndpoint;
      if (endpoint == null) throw StateError('Reconnect the Home Node');
      final client = LoomGroupClient(
        baseUri: endpoint,
        accessTokenProvider: _accessToken,
        deviceProof: await onboarding.deviceRequestProofProvider(),
      );
      try {
        final profile = await client.memberProfile(member.deviceId);
        if (profile['accountId'] != member.accountId ||
            profile['identityId'] != member.identityId) {
          throw StateError('MLS account identity mismatch');
        }
        address = '@${profile['username']}:${onboarding.receipt!.homeNode}';
      } finally {
        client.close();
      }
    }
    final peer = await _resolvePeerSecurity(address, force: true);
    if (peer.identityId != member.identityId) {
      throw StateError('MLS account identity changed');
    }
    return peer.devices.singleWhere((d) => d.deviceId == member.deviceId);
  }

  Future<List<String>> groupDevicesForContact(String address) async {
    if (_store == null) await open();
    final canonical = LoomAddress.normalizeInput(
      address,
      homeNode: onboarding.receipt!.homeNode,
    );
    if (!canonical.isSameNode(onboarding.receipt!.homeNode)) {
      throw StateError('MLS currently supports members on the same Home Node');
    }
    final peer = await _resolvePeerSecurity(canonical.canonical, force: true);
    return peer.devices.map((d) => d.deviceId).toList();
  }

  Future<LoomResolvedUserSecurity> _resolvePeerSecurity(
    String address, {
    bool force = false,
  }) async {
    if (_disposed || LoomAppLock.instance.locked) {
      throw StateError('Messaging is locked');
    }
    final epoch = _readableEpoch;
    final account = onboarding.receipt?.accountId;
    final key = address.trim().toLowerCase();
    final cached = _peerSecurityCache[key];
    if (!force &&
        cached != null &&
        DateTime.now().toUtc().difference(cached.cachedAt) <
            const Duration(minutes: 2)) {
      _rememberPeerDisplayName(cached.value);
      return cached.value;
    }
    if (!force) {
      final durable = await _offlineDeviceDirectoryCache?.loadPeer(
        address: address,
        now: DateTime.now().toUtc(),
        displayName: _peerDisplayNames[key] ?? '',
      );
      if (durable != null) {
        _rememberPeerDisplayName(durable);
        return durable;
      }
    }
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (endpoint == null) {
      throw const LoomProtocolException('Home Node endpoint unavailable');
    }
    final proof = await onboarding.deviceRequestProofProvider();
    final resolved = await _userSecurityClient.resolve(
      baseUri: endpoint,
      accessToken: await _accessToken(),
      address: address,
      deviceProofProvider: proof,
    );
    if (_disposed ||
        LoomAppLock.instance.locked ||
        epoch != _readableEpoch ||
        account != onboarding.receipt?.accountId ||
        _peerIdentityStore == null) {
      throw StateError('Messaging identity lookup was cancelled');
    }
    final observedAt = DateTime.now().toUtc();
    final observation = _peerIdentityStore!.observe(
      address: resolved.address,
      identityId: resolved.identityId,
      publicKey: resolved.identityPublicKey,
      fingerprint: resolved.identityFingerprint,
      observedAt: observedAt,
    );
    if (observation == LoomPeerIdentityObservation.changed) {
      throw StateError(
        'Peer identity key changed. Chat is blocked until the new identity is explicitly verified.',
      );
    }
    for (final bundle in resolved.devices) {
      final trust = _securityStore!.observeDevice(
        bundle,
        observedAt: observedAt,
      );
      if (trust == LoomDeviceTrustState.changed ||
          trust == LoomDeviceTrustState.revoked) {
        throw StateError(
          'A peer device key changed or was revoked. Direct messaging is blocked.',
        );
      }
    }
    _securityStore!.reconcileActiveDeviceSet(
      identityId: resolved.identityId,
      activeDeviceIds: resolved.devices
          .map((bundle) => bundle.deviceId)
          .toSet(),
      observedAt: observedAt,
    );
    _peerSecurityCache[key] = _PeerSecurityCache(
      value: resolved,
      cachedAt: observedAt,
    );
    _rememberPeerDisplayName(resolved);
    return resolved;
  }

  void _rememberPeerDisplayName(LoomResolvedUserSecurity peer) {
    _peerIdentityIds[peer.address.trim().toLowerCase()] = peer.identityId;
    final avatar = peer.avatar;
    if (avatar != null) {
      unawaited(
        LoomLocalAvatarStore.forIdentity(peer.identityId)
            .cachePeer(
              name: peer.displayName,
              png: avatar.png,
              color: avatar.color,
            )
            .catchError((Object _) {}),
      );
    }
    final displayName = peer.displayName.trim();
    if (displayName.isEmpty) {
      return;
    }
    _peerDisplayNames[peer.address.trim().toLowerCase()] = displayName;
  }

  Future<List<LoomDeviceKeyBundle>> _ownDevices({bool force = false}) async {
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (identity == null || receipt == null || endpoint == null) {
      throw StateError('Local device directory context is unavailable');
    }
    final cachedAt = _ownDevicesCachedAt;
    if (!force &&
        cachedAt != null &&
        _ownDevicesCache.isNotEmpty &&
        DateTime.now().toUtc().difference(cachedAt) <
            const Duration(minutes: 2)) {
      return _ownDevicesCache;
    }
    if (!force) {
      final durable = await _offlineDeviceDirectoryCache?.loadOwn(
        identity: identity,
        currentDeviceId: receipt.deviceId,
        now: DateTime.now().toUtc(),
      );
      if (durable != null) {
        _ownDevicesCache = durable;
        return durable;
      }
    }
    final proof = await onboarding.deviceRequestProofProvider();
    final devices = await _securityClient.listIdentityDevices(
      baseUri: endpoint,
      accessToken: await _accessToken(),
      identityId: identity.identityId,
      identityPublicKey: identity.publicKey,
      deviceProofProvider: proof,
    );
    if (!devices.any((bundle) => bundle.deviceId == receipt.deviceId)) {
      throw StateError(
        'Current device is missing from the Home Node device directory',
      );
    }
    final observedAt = DateTime.now().toUtc();
    for (final bundle in devices) {
      final trust = _securityStore!.observeDevice(
        bundle,
        observedAt: observedAt,
      );
      if (trust == LoomDeviceTrustState.changed ||
          trust == LoomDeviceTrustState.revoked) {
        throw StateError('A local device key changed unexpectedly');
      }
    }
    _securityStore!.reconcileActiveDeviceSet(
      identityId: identity.identityId,
      activeDeviceIds: devices.map((bundle) => bundle.deviceId).toSet(),
      observedAt: observedAt,
    );
    _ownDevicesCache = List<LoomDeviceKeyBundle>.unmodifiable(devices);
    _ownDevicesCachedAt = observedAt;
    return _ownDevicesCache;
  }

  void _onDefaultNetworkGenerationChanged(
    LoomDefaultNetworkSnapshot snapshot,
  ) {
    if (_disposed) {
      return;
    }
    final epoch = ++_realtimeEpoch;
    LoomTransportDiagnostics.event(
      'messaging_network_generation_observed',
      networkGeneration: snapshot.generation,
      transportCategory: snapshot.transportClass,
    );
    _store?.retryPendingSends();
    _scheduleSendDrain();
    unawaited(_invalidateRealtimeForGeneration(epoch));
  }

  Future<void> _invalidateRealtimeForGeneration(int epoch) async {
    final subscription = _realtimeSubscription;
    final connection = _realtime;
    _realtimeSubscription = null;
    _realtime = null;
    await subscription?.cancel();
    await connection?.close();
    if (_disposed || epoch != _realtimeEpoch) {
      return;
    }
    final client = _homeClient;
    if (client != null) {
      _scheduleRealtimeRecovery(client, expectedEpoch: epoch);
    }
  }

  Future<void> _connectRealtime(
    LoomMessagingClient client, {
    required int expectedEpoch,
  }) async {
    final previousSubscription = _realtimeSubscription;
    final previousConnection = _realtime;
    _realtimeSubscription = null;
    _realtime = null;
    await previousSubscription?.cancel();
    await previousConnection?.dispose();
    if (_disposed || expectedEpoch != _realtimeEpoch) {
      return;
    }

    final connection = client.realtime(cursor: _store?.readCursor('account'));
    _realtime = connection;
    _realtimeSubscription = connection.events.listen(
      (event) async {
        if (_disposed ||
            expectedEpoch != _realtimeEpoch ||
            !identical(_realtime, connection)) {
          return;
        }
        try {
          final conversationId = event.payload['conversationId'];
          final missingConversation =
              event.kind == 'message.created' &&
              conversationId is String &&
              !conversations.any((item) => item.id == conversationId);
          if (missingConversation) {
            // Resolve the conversation before applying the message. Applying it
            // first violates the local SQLite foreign key and used to throw,
            // which made realtime recovery reconnect forever as "Connecting…".
            await _refreshConversationCatalogue();
            if (_disposed ||
                expectedEpoch != _realtimeEpoch ||
                !identical(_realtime, connection)) {
              return;
            }
          }
          _engine?.applyRealtimeEvent(event);
          await _refreshLocal();
          if (!_disposed && expectedEpoch == _realtimeEpoch) {
            notifyListeners();
            _receiptFuture ??= _acknowledgeReadableMessages().whenComplete(
              () => _receiptFuture = null,
            );
          }
        } catch (_) {
          _scheduleRealtimeRecovery(client, expectedEpoch: expectedEpoch);
        }
      },
      onError: (_) {
        if (expectedEpoch == _realtimeEpoch &&
            identical(_realtime, connection)) {
          _scheduleRealtimeRecovery(client, expectedEpoch: expectedEpoch);
        }
      },
    );
    try {
      await connection.connect();
      if (_disposed ||
          expectedEpoch != _realtimeEpoch ||
          !identical(_realtime, connection)) {
        await connection.dispose();
        return;
      }
      LoomTransportDiagnostics.event(
        'realtime_connected',
        networkGeneration: LoomDefaultNetworkGeneration.current.generation,
      );
    } catch (_) {
      if (expectedEpoch == _realtimeEpoch) {
        _scheduleRealtimeRecovery(client, expectedEpoch: expectedEpoch);
      }
    }
  }

  void _scheduleRealtimeRecovery(
    LoomMessagingClient client, {
    required int expectedEpoch,
  }) {
    if (_disposed || expectedEpoch != _realtimeEpoch) {
      return;
    }
    _realtimeRecoveryRequested = true;
    if (_realtimeRecoveryEpoch == expectedEpoch) {
      return;
    }
    _realtimeRecoveryEpoch = expectedEpoch;
    unawaited(_recoverRealtime(client, expectedEpoch));
  }

  Future<void> _recoverRealtime(
    LoomMessagingClient client,
    int expectedEpoch,
  ) async {
    var attempt = 0;
    try {
      do {
        if (expectedEpoch != _realtimeEpoch || _disposed) {
          return;
        }
        _realtimeRecoveryRequested = false;
        // A slow REST fallback must not delay the websocket reconnect itself.
        // Opening installs the verified LAN routes before starting REST sync.
        if (status != LoomMessagingSessionStatus.opening) {
          unawaited(synchronize());
        }
        final delayMs = (350 * (1 << attempt)).clamp(350, 8000).toInt();
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        if (_disposed || expectedEpoch != _realtimeEpoch) {
          return;
        }
        try {
          await _connectRealtime(client, expectedEpoch: expectedEpoch);
        } catch (_) {
          if (expectedEpoch == _realtimeEpoch) {
            _realtimeRecoveryRequested = true;
          }
        }
        if (attempt < 5) {
          attempt++;
        }
        // connect/onError can request another retry while this loop owns the
        // epoch. Keep that request instead of losing it behind the old guard.
      } while (_realtimeRecoveryRequested);
    } finally {
      if (_realtimeRecoveryEpoch == expectedEpoch) {
        _realtimeRecoveryEpoch = null;
      }
    }
  }

  Future<void> _refreshLocal({bool requireFreshDeviceDirectory = false}) {
    Future<void> refresh() => _refreshLocalNow(
      requireFreshDeviceDirectory: requireFreshDeviceDirectory,
    );
    // Decryption is asynchronous. Serialize snapshots so an older refresh
    // cannot overwrite messages queued while it was awaiting device keys.
    return _localRefreshTail = _localRefreshTail.then(
      (_) => refresh(),
      onError: (Object _, StackTrace __) => refresh(),
    );
  }

  Future<void> _refreshLocalNow({
    bool requireFreshDeviceDirectory = false,
  }) async {
    if (_disposed || LoomAppLock.instance.locked) {
      return;
    }
    final readableEpoch = _readableEpoch;
    _rememberStoredConversationTitles();
    localConversationStates = _store?.localConversationStates() ?? const {};
    conversations = (_store?.listConversations() ?? const [])
        .map(_decorateConversation)
        .toList(growable: false);
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    var historicalDeviceIds = const <String>[];
    if (identity != null) {
      try {
        historicalDeviceIds = await _deviceSecurityCore
            .historicalAgreementDeviceIds(identityId: identity.identityId);
      } catch (_) {
        // A damaged historical-key index must not make current-device messages
        // unreadable. The imported history can be repaired by linking again.
      }
    }
    final freshPeers = <String, LoomResolvedUserSecurity>{};
    List<LoomDeviceKeyBundle>? freshOwnDevices;
    final next = <String, List<LoomVisibleMessage>>{};
    for (final conversation in conversations) {
      if (_disposed) {
        return;
      }
      final records = _historyWindow(conversation.id);
      final messages = <LoomVisibleMessage>[];
      for (final record in records) {
        if (_disposed ||
            readableEpoch != _readableEpoch ||
            LoomAppLock.instance.locked) {
          return;
        }
        if (conversation.kind == LoomConversationKind.self &&
            identity != null &&
            record.protocolVersion == LoomSelfMessageCodec.protocolVersion) {
          try {
            messages.add(
              LoomVisibleMessage(
                record: record,
                text: await _selfMessageCodec.decryptText(
                  identityId: identity.identityId,
                  conversationId: conversation.id,
                  envelope: record.ciphertext,
                ),
                readable: true,
              ),
            );
          } catch (_) {
            messages.add(_unreadable(record));
          }
          continue;
        }

        if (conversation.kind == LoomConversationKind.direct &&
            identity != null &&
            receipt != null &&
            record.protocolVersion ==
                LoomDirectMessageCodec.protocolVersion &&
            _directCodec != null) {
          try {
            final header = _directCodec!.inspect(record.ciphertext);
            if (header.senderAddress.toLowerCase() !=
                record.senderAddress.toLowerCase()) {
              throw const FormatException('Sender address mismatch');
            }
            final ownSender =
                header.senderAddress.toLowerCase() ==
                receipt.address.toLowerCase();
            if (ownSender && header.senderIdentityId != identity.identityId) {
              throw const FormatException('Local sender identity mismatch');
            }
            if (!ownSender) {
              final pin = _peerIdentityStore?.pinForAddress(
                header.senderAddress,
              );
              if (pin != null && pin.identityId != header.senderIdentityId) {
                throw const FormatException('Pinned peer identity mismatch');
              }
            }

            LoomDeviceKeyBundle? senderBundle;
            if (requireFreshDeviceDirectory) {
              if (ownSender) {
                freshOwnDevices ??= await _ownDevices(force: true);
                senderBundle = freshOwnDevices
                    .where((bundle) => bundle.deviceId == header.senderDeviceId)
                    .firstOrNull;
              } else {
                final key = header.senderAddress.toLowerCase();
                var peer = freshPeers[key];
                if (peer == null) {
                  peer = await _resolvePeerSecurity(
                    header.senderAddress,
                    force: true,
                  );
                  freshPeers[key] = peer;
                }
                senderBundle = peer.devices
                    .where((bundle) => bundle.deviceId == header.senderDeviceId)
                    .firstOrNull;
              }
            } else {
              senderBundle = _knownSenderBundle(
                header.senderIdentityId,
                header.senderDeviceId,
              );
              if (senderBundle == null) {
                if (ownSender) {
                  final own = await _ownDevices();
                  senderBundle = own
                      .where(
                        (bundle) => bundle.deviceId == header.senderDeviceId,
                      )
                      .firstOrNull;
                } else {
                  final peer = await _resolvePeerSecurity(header.senderAddress);
                  senderBundle = peer.devices
                      .where(
                        (bundle) => bundle.deviceId == header.senderDeviceId,
                      )
                      .firstOrNull;
                }
              }
            }
            if (senderBundle == null) {
              throw StateError('Sender device key is unavailable or revoked');
            }
            messages.add(
              LoomVisibleMessage(
                record: record,
                text: await _decryptDirectTextForLocalHistory(
                  record: record,
                  conversationId: conversation.id,
                  identity: identity,
                  receipt: receipt,
                  senderBundle: senderBundle,
                  historicalDeviceIds: historicalDeviceIds,
                ),
                readable: true,
              ),
            );
          } catch (_) {
            messages.add(_unreadable(record));
          }
          continue;
        }

        messages.add(
          LoomVisibleMessage(
            record: record,
            text: 'Encrypted message',
            readable: false,
          ),
        );
      }
      if (readableEpoch != _readableEpoch || LoomAppLock.instance.locked) {
        return;
      }
      final ordinary = projectLoomLiveLocations<LoomVisibleMessage>(
        messages,
        location: (m) => m.readable ? m.content.location : null,
        sender: (m) => m.record.senderAddress.toLowerCase(),
        compare: (a, b) {
          final byTime = a.record.createdAt.compareTo(b.record.createdAt);
          return byTime != 0
              ? byTime
              : a.record.createdOrder.compareTo(b.record.createdOrder);
        },
        merge: (anchor, latest) => LoomVisibleMessage(
          record: anchor.record,
          text: latest.text,
          readable: latest.readable,
        ),
      );
      ordinary.sort((a, b) {
        final byTime = b.record.createdAt.compareTo(a.record.createdAt);
        if (byTime != 0) return byTime;
        final byOrder = b.record.createdOrder.compareTo(a.record.createdOrder);
        return byOrder != 0 ? byOrder : b.record.id.compareTo(a.record.id);
      });
      next[conversation.id] = List.unmodifiable(ordinary);
    }

    if (_disposed) {
      return;
    }
    final decorated = conversations
        .map(_decorateConversation)
        .toList(growable: false);
    for (final conversation in decorated) {
      _store?.upsertConversation(conversation);
      _rememberConversationTitle(conversation);
    }
    conversations = decorated;
    if (readableEpoch != _readableEpoch || LoomAppLock.instance.locked) {
      return;
    }
    visibleMessages = Map.unmodifiable(next);
    _mergeGroups();
    _scheduleDisplayNameHydration();
  }

  void _rememberStoredConversationTitles() {
    for (final conversation
        in _store?.listConversations() ?? const <LoomConversation>[]) {
      _rememberConversationTitle(conversation);
    }
  }

  void _rememberConversationTitle(LoomConversation conversation) {
    if (conversation.kind != LoomConversationKind.direct) {
      return;
    }
    final title = conversation.title?.trim();
    if (title == null || title.isEmpty) {
      return;
    }
    final peerAddress = conversation.peerAddress?.trim();
    if (peerAddress != null &&
        title.toLowerCase() == peerAddress.toLowerCase()) {
      return;
    }
    _conversationTitles[conversation.id] = title;
  }

  LoomConversation _decorateConversation(LoomConversation conversation) {
    if (conversation.kind != LoomConversationKind.direct) {
      return conversation;
    }
    final peerAddress = conversation.peerAddress?.trim();
    final resolvedDisplayName = peerAddress == null || peerAddress.isEmpty
        ? null
        : _peerDisplayNames[peerAddress.toLowerCase()];
    final currentTitle = conversation.title?.trim();
    final currentTitleIsAddress =
        currentTitle != null &&
        peerAddress != null &&
        currentTitle.toLowerCase() == peerAddress.toLowerCase();
    final rememberedTitle = _conversationTitles[conversation.id];
    final hasResolvedDisplayName =
        resolvedDisplayName != null && resolvedDisplayName.trim().isNotEmpty;
    final title = hasResolvedDisplayName
        ? resolvedDisplayName.trim()
        : currentTitle != null &&
              currentTitle.isNotEmpty &&
              !currentTitleIsAddress
        ? currentTitle
        : rememberedTitle;
    if (title == null || title.isEmpty || title == conversation.title) {
      if (title != null && title.isNotEmpty) {
        _conversationTitles[conversation.id] = title;
      }
      return conversation;
    }
    final decorated = LoomConversation(
      id: conversation.id,
      kind: conversation.kind,
      title: title,
      peerAddress: conversation.peerAddress,
      updatedOrder: conversation.updatedOrder,
      unreadCount: conversation.unreadCount,
      isMuted: conversation.isMuted,
      isPinned: conversation.isPinned,
    );
    _conversationTitles[conversation.id] = title;
    return decorated;
  }

  bool _conversationNeedsDisplayName(LoomConversation conversation) {
    if (conversation.kind != LoomConversationKind.direct) {
      return false;
    }
    final peerAddress = conversation.peerAddress?.trim();
    if (peerAddress == null || peerAddress.isEmpty) {
      return false;
    }
    final resolved = _peerDisplayNames[peerAddress.toLowerCase()]?.trim();
    if (resolved != null && resolved.isNotEmpty) {
      return false;
    }
    final title = conversation.title?.trim();
    return title == null ||
        title.isEmpty ||
        title.toLowerCase() == peerAddress.toLowerCase();
  }

  void _scheduleDisplayNameHydration() {
    if (_disposed ||
        _displayNameHydrationRunning ||
        _directCodec == null ||
        !conversations.any(_conversationNeedsDisplayName)) {
      return;
    }
    unawaited(_hydrateMissingConversationDisplayNames());
  }

  Future<void> _hydrateMissingConversationDisplayNames() async {
    if (_displayNameHydrationRunning || _disposed) {
      return;
    }
    _displayNameHydrationRunning = true;
    var changed = false;
    try {
      final missing = conversations
          .where(_conversationNeedsDisplayName)
          .toList(growable: false);
      for (final conversation in missing) {
        final peerAddress = conversation.peerAddress;
        if (peerAddress == null || peerAddress.trim().isEmpty) {
          continue;
        }
        final before = _peerDisplayNames[peerAddress.trim().toLowerCase()]
            ?.trim();
        try {
          final peer = await _resolvePeerSecurity(peerAddress);
          final after = peer.displayName.trim();
          if (after.isNotEmpty && after != before) {
            changed = true;
          }
        } catch (_) {
          // Address fallback remains available when profile lookup is offline.
        }
      }
      if (!changed || _disposed) {
        return;
      }
      final updated = (_store?.listConversations() ?? const [])
          .map(_decorateConversation)
          .toList(growable: false);
      for (final conversation in updated) {
        _store?.upsertConversation(conversation);
        _rememberConversationTitle(conversation);
      }
      conversations = updated;
      if (!_disposed) {
        notifyListeners();
      }
    } finally {
      _displayNameHydrationRunning = false;
    }
  }

  Future<String> _decryptDirectTextForLocalHistory({
    required LoomMessageRecord record,
    required String conversationId,
    required LoomIdentityPublic identity,
    required LoomRegistrationReceipt receipt,
    required LoomDeviceKeyBundle senderBundle,
    required List<String> historicalDeviceIds,
  }) async {
    final candidates = <String>[
      receipt.deviceId,
      ...historicalDeviceIds.where((deviceId) => deviceId != receipt.deviceId),
    ];
    Object? lastError;
    for (final localDeviceId in candidates) {
      final codec = localDeviceId == receipt.deviceId
          ? _directCodec
          : LoomDirectMessageCodec(
              signer: (payload) => _deviceSecurityCore.signDevicePayload(
                identityId: identity.identityId,
                deviceId: receipt.deviceId,
                payload: payload,
              ),
              opener: ({required payload, required associatedData}) =>
                  _deviceSecurityCore.openSealedPayload(
                    identityId: identity.identityId,
                    deviceId: localDeviceId,
                    payload: payload,
                    associatedData: associatedData,
                  ),
            );
      if (codec == null) {
        continue;
      }
      try {
        return await codec.decryptText(
          envelope: record.ciphertext,
          expectedConversationId: conversationId,
          expectedSenderAddress: record.senderAddress,
          localIdentityId: identity.identityId,
          localDeviceId: localDeviceId,
          senderDevice: senderBundle,
          expectedReplyToMessageId: record.replyToMessageId,
        );
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) {
      throw lastError;
    }
    throw const FormatException(
      'No local recipient key could open this direct message',
    );
  }

  LoomDeviceKeyBundle? _knownSenderBundle(
    String identityId,
    String deviceId,
  ) {
    final known = _securityStore?.listDevices(identityId) ?? const [];
    return known
        .where(
          (item) =>
              item.bundle.deviceId == deviceId &&
              item.trustState != LoomDeviceTrustState.changed &&
              item.trustState != LoomDeviceTrustState.revoked,
        )
        .map((item) => item.bundle)
        .firstOrNull;
  }

  LoomVisibleMessage _unreadable(LoomMessageRecord record) =>
      LoomVisibleMessage(
        record: record,
        text: 'Unable to decrypt this message on this device',
        readable: false,
      );

  void _setError(String value) {
    status = LoomMessagingSessionStatus.error;
    errorMessage = value;
    notifyListeners();
  }

  String _safeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
    return text.length <= 240 ? text : text.substring(0, 240);
  }

  @override
  void dispose() {
    _clearPendingMedia();
    _cancelLive();
    _groups?.removeListener(_groupsChanged);
    _groupViews.clear();
    _groupMessageSources.clear();
    _disposed = true;
    _engine?.dispose();
    ++_realtimeEpoch;
    unawaited(_networkSubscription?.cancel());
    _networkSubscription = null;
    unawaited(_realtimeSubscription?.cancel());
    unawaited(_realtime?.dispose());
    _legacyDtnMailbox?.close();
    _peerIdentityStore?.close();
    _securityStore?.close();
    _store?.close();
    _store = null;
    _securityStore = null;
    _peerIdentityStore = null;
    super.dispose();
  }
}

final class _LoomSendFallbackMessagingApi implements LoomMessagingApi {
  const _LoomSendFallbackMessagingApi({
    required this.primary,
    required this.fallback,
  });

  final LoomMessagingApi primary;
  final _LoomDtnFallbackCommitter fallback;

  @override
  Future<List<LoomConversation>> fetchConversations() =>
      primary.fetchConversations();

  @override
  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    try {
      return await primary.sendOpaqueMessage(
        conversationId: conversationId,
        clientId: clientId,
        type: type,
        ciphertext: ciphertext,
        protocolVersion: protocolVersion,
        replyToMessageId: replyToMessageId,
        metadata: metadata,
      );
    } catch (error) {
      final shouldFallback = LoomDtnFallbackPolicy.shouldFallback(error);
      LoomTransportDiagnostics.event(
        'fallback_decision',
        sendAttemptId: clientId,
        networkGeneration: LoomDefaultNetworkGeneration.current.generation,
        exceptionType: error.runtimeType.toString(),
        fallback: shouldFallback,
      );
      if (!shouldFallback) {
        rethrow;
      }
      await fallback(
        conversationId: conversationId,
        clientId: clientId,
        type: type,
        ciphertext: ciphertext,
        protocolVersion: protocolVersion,
        replyToMessageId: replyToMessageId,
        metadata: metadata,
      );
      throw LoomDtnCustodyPending(clientId);
    }
  }

  @override
  Future<LoomSyncPage> sync({String? cursor, int limit = 200}) =>
      primary.sync(cursor: cursor, limit: limit);

  @override
  Future<void> markRead({
    required String conversationId,
    required int throughOrder,
  }) => primary.markRead(
    conversationId: conversationId,
    throughOrder: throughOrder,
  );

  @override
  Future<LoomAttachmentReceipt> uploadEncryptedAttachment({
    required String conversationId,
    required File encryptedFile,
    required String contentType,
  }) => primary.uploadEncryptedAttachment(
    conversationId: conversationId,
    encryptedFile: encryptedFile,
    contentType: contentType,
  );
}

class _SessionMessageEncoder implements LoomOutgoingEnvelopeEncoder {
  const _SessionMessageEncoder({required this.controller});

  final LoomMessagingSessionController controller;

  @override
  Future<LoomOpaqueEnvelope> encodeText({
    required String conversationId,
    required String plaintext,
    String? replyToMessageId,
  }) => controller._encodeText(
    conversationId: conversationId,
    plaintext: plaintext,
    replyToMessageId: replyToMessageId,
  );
}

class _PeerSecurityCache {
  const _PeerSecurityCache({required this.value, required this.cachedAt});

  final LoomResolvedUserSecurity value;
  final DateTime cachedAt;
}

class LoomMessagingSessionScope
    extends InheritedNotifier<LoomMessagingSessionController> {
  const LoomMessagingSessionScope({
    required LoomMessagingSessionController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static LoomMessagingSessionController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LoomMessagingSessionScope>();
    assert(scope != null, 'LoomMessagingSessionScope not found');
    return scope!.notifier!;
  }

  static LoomMessagingSessionController? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LoomMessagingSessionScope>()
          ?.notifier;
}
