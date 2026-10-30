import 'dart:async';

import 'package:loom_calls/loom_calls.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../messaging/application/messaging_session_controller.dart';
import '../../onboarding/application/onboarding_controller.dart';
import 'call_diagnostics.dart';
import '../../media/application/playback_controller.dart';

const _audioCapability = 'loom-call-audio-v1';
const _videoCapability = 'loom-call-video-v1';

class LoomCallPeer {
  const LoomCallPeer({
    required this.conversationId,
    required this.address,
    required this.displayName,
    required this.identityId,
    required this.devices,
  });

  final String conversationId;
  final String address;
  final String displayName;
  final String identityId;
  final List<LoomDeviceKeyBundle> devices;

  bool supports(LoomCallKind kind) {
    final required = kind == LoomCallKind.video
        ? _videoCapability
        : _audioCapability;
    if (devices.any((device) => device.capabilities.contains(required))) {
      return true;
    }

    // Device bundles created before call capability advertisement shipped with
    // the same signed Loom desktop/mobile client but only declared its crypto
    // primitives. Keep those devices callable during the migration; new bundles
    // explicitly advertise audio/video capabilities below the same verified
    // identity/device binding.
    return devices.any(
      (device) =>
          device.capabilities.contains('signing-ed25519') &&
          device.capabilities.contains('agreement-x25519'),
    );
  }
}

class LoomCallUnavailableException implements Exception {
  const LoomCallUnavailableException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class LoomCallSessionController extends ChangeNotifier
    with WidgetsBindingObserver {
  LoomCallSessionController({
    required this.onboarding,
    required this.messaging,
    LoomUserSecurityClient? userSecurityClient,
  }) : _userSecurityClient = userSecurityClient ?? LoomUserSecurityClient();

  final LoomOnboardingController onboarding;
  final LoomMessagingSessionController messaging;
  final LoomUserSecurityClient _userSecurityClient;

  LoomCallEngine? _engine;
  LoomCallClient? _api;
  LoomCallSignalingConnection? _signaling;
  StreamSubscription<LoomCallSignal>? _incomingSubscription;
  LoomCallHistoryStore? _historyStore;
  Timer? _incomingTimeout;
  Timer? _openRetryTimer;
  Timer? _pendingPollTimer;
  Future<void>? _openFuture;
  int _openRetryAttempt = 0;
  bool _pendingPollRunning = false;
  bool _disposed = false;
  String? _boundIdentityId;

  LoomCallPeer? currentPeer;
  LoomPendingCall? incomingCall;
  LoomCallPeer? incomingPeer;
  List<LoomCallHistoryEntry> history = const [];
  String? errorMessage;
  String? connectionError;

  LoomCallEngine? get engine => _engine;
  bool Function()? externalCallActive;
  bool _startingOutgoing = false;
  bool get hasPendingOrActiveCall =>
      hasActiveCall || incomingCall != null || _startingOutgoing;
  bool get hasActiveCall => _engine?.state.active == true;
  bool get ready => _engine != null && _boundIdentityId != null;

  Future<void> open() {
    if (_disposed || LoomAppLock.instance.locked) {
      traceLoomCall('receiver_open_suspended');
      return Future<void>.value();
    }
    return _openFuture ??= _openSession().whenComplete(
      () => _openFuture = null,
    );
  }

  Future<void> _openSession() async {
    if (_disposed) {
      return;
    }
    final identity = onboarding.committedIdentity;
    final receipt = onboarding.receipt;
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (identity == null || receipt == null || endpoint == null) {
      traceLoomCall('receiver_open_missing_session');
      errorMessage = 'Sign in to your Home Node before making a call.';
      return;
    }
    if (_engine != null && _boundIdentityId == identity.identityId) {
      return;
    }

    traceLoomCall('receiver_open_start');
    try {
      await _disposeSessionOnly();
      final proof = await onboarding.deviceRequestProofProvider();
      traceLoomCall('receiver_proof_ready');
      if (_disposed) {
        return;
      }
      Future<String> tokenProvider() => _accessToken();
      final api = LoomCallClient(
        baseUri: endpoint,
        accessTokenProvider: tokenProvider,
        deviceProofProvider: proof,
        refreshRejectedToken: onboarding.refreshRejectedToken,
        trace: traceLoomCall,
      );
      _api = api;
      // Receiving an authenticated offer does not need TURN credentials.
      // Fetch media configuration only when starting/accepting in the engine;
      // a receiver with an incomplete RTC setup must still see who is calling.
      final signaling = LoomCallSignalingConnection(
        baseUri: endpoint,
        accessTokenProvider: tokenProvider,
        deviceProofProvider: proof,
        trace: traceLoomCall,
      );
      final engine = LoomCallEngine(
        api: api,
        signaling: signaling,
        localIdentityId: identity.identityId,
      );
      _signaling = signaling;
      _engine = engine;
      _boundIdentityId = identity.identityId;
      engine.addListener(_onEngineChanged);
      // Subscribe before connecting: a server may send an offer immediately
      // after the WebSocket upgrade, before initialize() completes.
      _incomingSubscription = signaling.signals.listen(
        _onSignal,
        onError: (Object error) {
          if (error is LoomCallSignalingException &&
              error.callId != engine.state.callId &&
              error.callId != incomingCall?.callId) {
            return;
          }
          errorMessage = _safeError(error);
          if (error is! LoomCallSignalingException) {
            connectionError = errorMessage;
          }
          if (!_disposed) {
            notifyListeners();
          }
        },
      );

      // Recover pending offers in parallel with WSS. A failed upgrade can take
      // ten seconds; the incoming surface must not wait for that timeout.
      _startPendingPoll();
      unawaited(_pollPendingCalls());

      Object? realtimeStartupError;
      try {
        await engine.initialize();
      } catch (error) {
        // Keep REST pending-call recovery alive while WSS reconnects.
        realtimeStartupError = error;
      }
      if (_disposed) {
        await _disposeSessionOnly();
        return;
      }

      final support = await getApplicationSupportDirectory();
      if (_disposed) {
        await _disposeSessionOnly();
        return;
      }
      final safeIdentity = identity.identityId.replaceAll(
        RegExp(r'[^a-zA-Z0-9._-]'),
        '_',
      );
      _historyStore = LoomCallHistoryStore.openFile(
        '${support.path}/loom-calls-$safeIdentity.sqlite3',
      );
      _reloadHistory();
      await refreshPendingCalls();
      _openRetryTimer?.cancel();
      _openRetryTimer = null;
      _openRetryAttempt = 0;
      errorMessage = realtimeStartupError == null
          ? null
          : _safeError(realtimeStartupError);
      connectionError = errorMessage;
      traceLoomCall('receiver_open_complete');
    } catch (error) {
      traceLoomCall('receiver_open_failed:${error.runtimeType}');
      errorMessage = _safeError(error);
      connectionError = errorMessage;
      await _disposeSessionOnly();
      _scheduleOpenRetry();
    } finally {
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _bindPlayback() {
    LoomPlaybackController.instance.blockedByCall = () =>
        !_disposed &&
        (hasPendingOrActiveCall || externalCallActive?.call() == true);
  }

  Future<LoomCallPeer> startConversationCall(
    LoomConversation conversation,
    LoomCallKind kind,
  ) async {
    if (hasPendingOrActiveCall || externalCallActive?.call() == true) {
      throw const LoomCallUnavailableException(
        'already_in_call',
        'Another call is already active.',
      );
    }
    _startingOutgoing = true;
    try {
      _bindPlayback();
      await LoomPlaybackController.pauseAll();
      await open();
      final engine = _engine;
      if (engine == null) {
        throw LoomCallUnavailableException(
          'session_unavailable',
          errorMessage ?? 'The call service could not connect. Try again.',
        );
      }
      if (engine.state.active) {
        throw const LoomCallUnavailableException(
          'already_in_call',
          'Another call is already active.',
        );
      }
      final peer = await resolvePeer(conversation, kind: kind);
      if (externalCallActive?.call() == true) {
        throw const LoomCallUnavailableException(
          'already_in_call',
          'Another call is already active.',
        );
      }
      currentPeer = peer;
      errorMessage = null;
      notifyListeners();
      try {
        await engine.startOutgoing(
          conversationId: conversation.id,
          peerIdentityId: peer.identityId,
          kind: kind,
        );
        _recordStarted(peer, engine.state);
        notifyListeners();
        return peer;
      } catch (error) {
        errorMessage = _safeError(error);
        notifyListeners();
        rethrow;
      }
    } finally {
      _startingOutgoing = false;
    }
  }

  Future<LoomCallPeer> callAddress(String address, LoomCallKind kind) async {
    await LoomPlaybackController.pauseAll();
    await messaging.open();
    final conversation = await messaging.startConversation(address);
    if (conversation == null) {
      throw LoomCallUnavailableException(
        'conversation_unavailable',
        messaging.errorMessage ?? 'Could not establish a direct conversation.',
      );
    }
    return startConversationCall(conversation, kind);
  }

  Future<LoomCallPeer> resolvePeer(
    LoomConversation conversation, {
    required LoomCallKind kind,
  }) async {
    if (conversation.kind != LoomConversationKind.direct ||
        conversation.peerAddress == null ||
        conversation.peerAddress!.trim().isEmpty) {
      throw const LoomCallUnavailableException(
        'not_direct',
        'This conversation does not have a callable 1:1 peer.',
      );
    }
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (endpoint == null) {
      throw const LoomCallUnavailableException(
        'node_unavailable',
        'The verified Home Node is unavailable.',
      );
    }
    final proof = await onboarding.deviceRequestProofProvider();
    final resolved = await _userSecurityClient.resolve(
      baseUri: endpoint,
      accessToken: await _accessToken(),
      address: conversation.peerAddress!,
      deviceProofProvider: proof,
    );
    if (resolved.devices.isEmpty) {
      throw const LoomCallUnavailableException(
        'no_active_devices',
        'This person has no compatible active Loom devices.',
      );
    }
    final peer = LoomCallPeer(
      conversationId: conversation.id,
      address: resolved.address,
      displayName: resolved.displayName,
      identityId: resolved.identityId,
      devices: resolved.devices,
    );
    if (!peer.supports(kind)) {
      throw LoomCallUnavailableException(
        'capability_unavailable',
        kind == LoomCallKind.video
            ? 'None of this person’s active devices advertises Loom video-call support.'
            : 'None of this person’s active devices advertises Loom audio-call support.',
      );
    }
    return peer;
  }

  Future<void> refreshPendingCalls() async {
    final api = _api;
    final engine = _engine;
    if (_disposed ||
        LoomAppLock.instance.locked ||
        api == null ||
        engine == null) {
      return;
    }
    try {
      final pending = await api.fetchPendingCalls();
      if (_disposed || !identical(api, _api)) {
        return;
      }
      if (connectionError != null) {
        connectionError = null;
        notifyListeners();
      }
      for (final call in pending) {
        if (!call.expiresAt.isAfter(DateTime.now().toUtc())) {
          continue;
        }
        await _presentIncoming(call);
        break;
      }
    } catch (error) {
      if (!_disposed && identical(api, _api)) {
        traceLoomCall('pending_http_failed:${error.runtimeType}');
        final detail = _safeError(error);
        if (connectionError != detail) {
          connectionError = detail;
          notifyListeners();
        }
      }
    }
  }

  Future<void> acceptIncoming() async {
    final pending = incomingCall;
    final peer = incomingPeer;
    final engine = _engine;
    if (pending == null || engine == null) {
      return;
    }
    if (!pending.expiresAt.isAfter(DateTime.now().toUtc())) {
      await _expireIncoming();
      return;
    }
    _incomingTimeout?.cancel();
    incomingCall = null;
    incomingPeer = null;
    final resolvedPeer = peer ??
        LoomCallPeer(
          conversationId: pending.conversationId,
          address: '',
          displayName: pending.callerIdentityId,
          identityId: pending.callerIdentityId,
          devices: const <LoomDeviceKeyBundle>[],
        );
    currentPeer = resolvedPeer;
    notifyListeners();
    try {
      await engine.acceptPending(pending);
      _recordStarted(currentPeer!, engine.state);
    } catch (error) {
      errorMessage = _safeError(error);
      // The offer is still live server-side: restoring the incoming state
      // lets the user accept again instead of losing the call entirely.
      if (!_disposed && incomingCall == null) {
        incomingCall = pending;
        incomingPeer = peer;
        currentPeer = null;
        final remaining =
            pending.expiresAt.difference(DateTime.now().toUtc());
        if (remaining > Duration.zero) {
          _incomingTimeout =
              Timer(remaining, () => unawaited(_expireIncoming()));
        }
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> declineIncoming() async {
    final pending = incomingCall;
    if (pending == null) {
      return;
    }
    _incomingTimeout?.cancel();
    final peer = incomingPeer;
    incomingCall = null;
    incomingPeer = null;
    notifyListeners();
    try {
      await _engine?.rejectPending(pending);
    } finally {
      _recordUnansweredPending(
        pending,
        peer,
        outcome: LoomCallHistoryOutcome.declined,
        reason: LoomCallEndReason.rejected,
      );
    }
  }

  Future<void> returnToCall() => open();

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
    final token = onboarding.accessToken;
    if (token == null || token.isEmpty) {
      throw const LoomProtocolException('Access token unavailable');
    }
    return token;
  }

  Future<void> _onSignal(LoomCallSignal signal) async {
    final identity = onboarding.committedIdentity;
    if (identity == null || signal.targetIdentityId != identity.identityId) {
      if (signal.kind == 'call.offer') {
        traceLoomCall('offer_ignored:identity');
      }
      return;
    }
    if (signal.kind == 'call.offer' &&
        signal.mediaKind != null &&
        signal.sdp != null) {
      final pending = LoomPendingCall(
        callId: signal.callId,
        conversationId: signal.conversationId,
        callerIdentityId: signal.senderIdentityId,
        kind: signal.mediaKind!,
        createdAt: signal.createdAt,
        expiresAt: signal.createdAt.add(const Duration(seconds: 45)),
        offerSdp: signal.sdp!,
      );
      await _presentIncoming(pending);
      return;
    }
    if (incomingCall?.callId == signal.callId && signal.kind == 'call.end') {
      await _expireIncoming(remoteCanceled: true);
    }
  }

  Future<void> _presentIncoming(LoomPendingCall pending) async {
    final engine = _engine;
    if (_disposed || engine == null) {
      traceLoomCall('incoming_ignored:closed');
      return;
    }
    if (!pending.expiresAt.isAfter(DateTime.now().toUtc())) {
      traceLoomCall('incoming_ignored:expired');
      return;
    }
    if (incomingCall?.callId == pending.callId) {
      return;
    }
    if (engine.state.active && engine.state.callId == pending.callId) {
      // The engine handles a repeated offer/ICE restart for the live call.
      // Do not reject that same peer as busy or reopen the incoming surface.
      return;
    }
    if (engine.state.active ||
        incomingCall != null ||
        _startingOutgoing ||
        externalCallActive?.call() == true) {
      traceLoomCall('incoming_ignored:busy');
      await engine.busyPending(pending);
      _recordUnansweredPending(
        pending,
        null,
        outcome: LoomCallHistoryOutcome.busy,
        reason: LoomCallEndReason.busy,
      );
      return;
    }
    // Present the call immediately. Profile/conversation hydration is useful
    // decoration, not a prerequisite for ringing; waiting on messaging sync
    // here could hide a perfectly valid incoming offer for many seconds.
    _bindPlayback();
    unawaited(LoomPlaybackController.pauseAll());
    incomingCall = pending;
    traceLoomCall('incoming_state_ready:${pending.kind.name}');
    incomingPeer = null;
    errorMessage = null;
    _incomingTimeout?.cancel();
    final remaining = pending.expiresAt.difference(DateTime.now().toUtc());
    if (remaining <= Duration.zero) {
      await _expireIncoming();
      return;
    }
    _incomingTimeout = Timer(remaining, () => unawaited(_expireIncoming()));
    notifyListeners();
    if (!LoomAppLock.instance.locked) {
      unawaited(_hydrateIncomingPeer(pending));
    }

    try {
      await engine.signalRinging(pending);
    } catch (_) {
      // The incoming surface remains valid if the ringing hint races a socket
      // reconnect. Pending-call recovery can still complete the flow.
    }
  }

  Future<void> _hydrateIncomingPeer(LoomPendingCall pending) async {
    LoomCallPeer? peer;
    try {
      await messaging.open();
      await messaging.synchronize();
      if (_disposed || incomingCall?.callId != pending.callId) {
        return;
      }
      final conversation = messaging.conversations
          .where((item) => item.id == pending.conversationId)
          .firstOrNull;
      if (conversation != null) {
        peer = await resolvePeer(conversation, kind: pending.kind);
        if (peer.identityId != pending.callerIdentityId) {
          throw const LoomProtocolException(
            'Incoming caller identity does not match the verified conversation peer',
          );
        }
      }
    } catch (_) {
      // The signaling service already authenticated the caller identity. Keep
      // the immediate identity fallback when profile hydration is unavailable.
    }
    if (!_disposed && incomingCall?.callId == pending.callId && peer != null) {
      incomingPeer = peer;
      notifyListeners();
    }
  }

  Future<void> _expireIncoming({bool remoteCanceled = false}) async {
    final pending = incomingCall;
    if (pending == null) {
      return;
    }
    final peer = incomingPeer;
    incomingCall = null;
    incomingPeer = null;
    _incomingTimeout?.cancel();
    _incomingTimeout = null;
    _recordUnansweredPending(
      pending,
      peer,
      outcome: LoomCallHistoryOutcome.missed,
      reason: remoteCanceled
          ? LoomCallEndReason.remoteHangup
          : LoomCallEndReason.timeout,
    );
    notifyListeners();
  }

  void _recordStarted(LoomCallPeer peer, LoomCallSnapshot state) {
    final callId = state.callId;
    final conversationId = state.conversationId;
    if (callId == null || conversationId == null) {
      return;
    }
    _historyStore?.upsert(
      LoomCallHistoryEntry(
        callId: callId,
        conversationId: conversationId,
        peerIdentityId: peer.identityId,
        peerAddress: peer.address,
        peerDisplayName: peer.displayName,
        kind: state.kind,
        direction: state.direction,
        outcome: LoomCallHistoryOutcome.canceled,
        startedAt: state.startedAt ?? DateTime.now().toUtc(),
      ),
    );
    _reloadHistory();
  }

  void _onEngineChanged() {
    final engine = _engine;
    final peer = currentPeer;
    if (engine == null || peer == null) {
      return;
    }
    final state = engine.state;
    if (state.lifecycle == LoomCallLifecycle.failed) {
      errorMessage = state.error == null
          ? 'The call could not connect.'
          : _safeError(state.error!);
    }
    // The visible state must not depend on whether history storage is ready.
    notifyListeners();
    final callId = state.callId;
    if (callId == null) {
      return;
    }
    var entry = _historyStore?.get(callId);
    if (entry == null &&
        state.startedAt != null &&
        state.conversationId != null) {
      _recordStarted(peer, state);
      entry = _historyStore?.get(callId);
    }
    if (entry == null) {
      return;
    }

    if (state.lifecycle == LoomCallLifecycle.connected &&
        entry.answeredAt == null) {
      _historyStore?.upsert(
        LoomCallHistoryEntry(
          callId: entry.callId,
          conversationId: entry.conversationId,
          peerIdentityId: entry.peerIdentityId,
          peerAddress: entry.peerAddress,
          peerDisplayName: entry.peerDisplayName,
          kind: entry.kind,
          direction: entry.direction,
          outcome: LoomCallHistoryOutcome.answered,
          startedAt: entry.startedAt,
          answeredAt: state.answeredAt ?? DateTime.now().toUtc(),
        ),
      );
      _reloadHistory();
    }

    if (state.lifecycle == LoomCallLifecycle.ended ||
        state.lifecycle == LoomCallLifecycle.failed) {
      final fresh = _historyStore?.get(callId) ?? entry;
      _historyStore?.upsert(
        LoomCallHistoryEntry(
          callId: fresh.callId,
          conversationId: fresh.conversationId,
          peerIdentityId: fresh.peerIdentityId,
          peerAddress: fresh.peerAddress,
          peerDisplayName: fresh.peerDisplayName,
          kind: fresh.kind,
          direction: fresh.direction,
          outcome: _outcomeFor(state, fresh),
          startedAt: fresh.startedAt,
          answeredAt: fresh.answeredAt ?? state.answeredAt,
          endedAt: state.endedAt ?? DateTime.now().toUtc(),
          endReason: state.endReason,
        ),
      );
      _reloadHistory();
    }
    notifyListeners();
  }

  LoomCallHistoryOutcome _outcomeFor(
    LoomCallSnapshot state,
    LoomCallHistoryEntry entry,
  ) {
    if (entry.answeredAt != null || state.answeredAt != null) {
      return LoomCallHistoryOutcome.answered;
    }
    return switch (state.endReason) {
      LoomCallEndReason.rejected => LoomCallHistoryOutcome.declined,
      LoomCallEndReason.busy => LoomCallHistoryOutcome.busy,
      LoomCallEndReason.timeout
          when state.direction == LoomCallDirection.incoming =>
        LoomCallHistoryOutcome.missed,
      LoomCallEndReason.permissionDenied ||
      LoomCallEndReason.mediaFailure ||
      LoomCallEndReason.signalingFailure ||
      LoomCallEndReason.connectionFailure => LoomCallHistoryOutcome.failed,
      _ => LoomCallHistoryOutcome.canceled,
    };
  }

  void _recordUnansweredPending(
    LoomPendingCall pending,
    LoomCallPeer? peer, {
    required LoomCallHistoryOutcome outcome,
    required LoomCallEndReason reason,
  }) {
    _historyStore?.upsert(
      LoomCallHistoryEntry(
        callId: pending.callId,
        conversationId: pending.conversationId,
        peerIdentityId: pending.callerIdentityId,
        peerAddress: peer?.address ?? '',
        peerDisplayName: peer?.displayName ?? pending.callerIdentityId,
        kind: pending.kind,
        direction: LoomCallDirection.incoming,
        outcome: outcome,
        startedAt: pending.createdAt,
        endedAt: DateTime.now().toUtc(),
        endReason: reason,
      ),
    );
    _reloadHistory();
  }

  void _reloadHistory() {
    history = _historyStore?.list() ?? const [];
    if (!_disposed) {
      notifyListeners();
    }
  }

  String _safeError(Object error) {
    if (error is LoomCallUnavailableException) {
      return error.message;
    }
    if (error is LoomProtocolException) {
      return error.message;
    }
    return error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
  }

  void _startPendingPoll() {
    _pendingPollTimer?.cancel();
    _pendingPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_disposed ||
          LoomAppLock.instance.locked ||
          onboarding.status != LoomOnboardingStatus.complete ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
          hasActiveCall ||
          incomingCall != null) {
        return;
      }
      unawaited(_pollPendingCalls());
    });
  }

  Future<void> _pollPendingCalls() async {
    if (_pendingPollRunning || _disposed) {
      return;
    }
    _pendingPollRunning = true;
    try {
      await refreshPendingCalls();
    } finally {
      _pendingPollRunning = false;
    }
  }

  void _scheduleOpenRetry() {
    if (_disposed ||
        onboarding.status != LoomOnboardingStatus.complete ||
        LoomAppLock.instance.locked ||
        _openRetryTimer != null) {
      return;
    }
    const delays = <int>[1, 2, 4, 8, 15];
    final delay = delays[_openRetryAttempt.clamp(0, delays.length - 1).toInt()];
    _openRetryAttempt += 1;
    _openRetryTimer = Timer(Duration(seconds: delay), () {
      _openRetryTimer = null;
      if (!_disposed && onboarding.status == LoomOnboardingStatus.complete) {
        unawaited(open());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !LoomAppLock.instance.locked) {
      unawaited(resumeAfterUnlock());
    }
  }

  Future<void> resumeAfterUnlock() async {
    if (_disposed || LoomAppLock.instance.locked) {
      return;
    }
    _openRetryTimer?.cancel();
    _openRetryTimer = null;
    _openRetryAttempt = 0;
    await open();
    if (_disposed || LoomAppLock.instance.locked) {
      return;
    }
    final pending = incomingCall;
    if (pending != null) {
      unawaited(_hydrateIncomingPeer(pending));
    }
    await _pollPendingCalls();
    final signaling = _signaling;
    if (signaling != null && !signaling.connected) {
      try {
        await signaling.connect();
      } catch (error) {
        errorMessage = _safeError(error);
        connectionError = errorMessage;
        if (!_disposed) {
          notifyListeners();
        }
      }
    }
  }

  Future<void> _disposeSessionOnly() async {
    _incomingTimeout?.cancel();
    _incomingTimeout = null;
    _pendingPollTimer?.cancel();
    _pendingPollTimer = null;
    _pendingPollRunning = false;
    await _incomingSubscription?.cancel();
    _incomingSubscription = null;
    final engine = _engine;
    if (engine != null) {
      engine.removeListener(_onEngineChanged);
      engine.dispose();
    }
    _engine = null;
    _api?.close();
    _api = null;
    _signaling = null;
    _historyStore?.close();
    _historyStore = null;
    _boundIdentityId = null;
    incomingCall = null;
    incomingPeer = null;
    currentPeer = null;
    history = const [];
  }

  @override
  void dispose() {
    _disposed = true;
    _openRetryTimer?.cancel();
    _openRetryTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeSessionOnly());
    super.dispose();
  }

  void attachLifecycleObserver() {
    WidgetsBinding.instance.addObserver(this);
  }
}

class LoomCallSessionScope
    extends InheritedNotifier<LoomCallSessionController> {
  const LoomCallSessionScope({
    required LoomCallSessionController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static LoomCallSessionController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LoomCallSessionScope>();
    assert(scope != null, 'LoomCallSessionScope is missing');
    return scope!.notifier!;
  }
}
