import 'dart:async';
import 'dart:math';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'incoming_ice_buffer.dart';

class LoomCallSnapshot {
  const LoomCallSnapshot({
    this.lifecycle = LoomCallLifecycle.idle,
    this.kind = LoomCallKind.audio,
    this.direction = LoomCallDirection.outgoing,
    this.callId,
    this.conversationId,
    this.peerIdentityId,
    this.muted = false,
    this.cameraEnabled = false,
    this.speakerEnabled = false,
    this.remoteRinging = false,
    this.remoteVideoAvailable = false,
    this.remoteCameraEnabled = true,
    this.quality = LoomCallQuality.unknown,
    this.startedAt,
    this.answeredAt,
    this.endedAt,
    this.endReason,
    this.reconnectAttempts = 0,
    this.error,
  });

  final LoomCallLifecycle lifecycle;
  final LoomCallKind kind;
  final LoomCallDirection direction;
  final String? callId;
  final String? conversationId;
  final String? peerIdentityId;
  final bool muted;
  final bool cameraEnabled;
  final bool speakerEnabled;
  final bool remoteRinging;
  final bool remoteVideoAvailable;
  final bool remoteCameraEnabled;
  final LoomCallQuality quality;
  final DateTime? startedAt;
  final DateTime? answeredAt;
  final DateTime? endedAt;
  final LoomCallEndReason? endReason;
  final int reconnectAttempts;
  final Object? error;

  bool get active => switch (lifecycle) {
        LoomCallLifecycle.preparing ||
        LoomCallLifecycle.ringing ||
        LoomCallLifecycle.connecting ||
        LoomCallLifecycle.connected ||
        LoomCallLifecycle.reconnecting =>
          true,
        _ => false,
      };

  Duration get duration {
    final answered = answeredAt;
    if (answered == null) return Duration.zero;
    return (endedAt ?? DateTime.now().toUtc()).difference(answered);
  }

  LoomCallSnapshot copyWith({
    LoomCallLifecycle? lifecycle,
    LoomCallKind? kind,
    LoomCallDirection? direction,
    String? callId,
    String? conversationId,
    String? peerIdentityId,
    bool? muted,
    bool? cameraEnabled,
    bool? speakerEnabled,
    bool? remoteRinging,
    bool? remoteVideoAvailable,
    bool? remoteCameraEnabled,
    LoomCallQuality? quality,
    DateTime? startedAt,
    DateTime? answeredAt,
    DateTime? endedAt,
    LoomCallEndReason? endReason,
    int? reconnectAttempts,
    Object? error,
    bool clearError = false,
  }) =>
      LoomCallSnapshot(
        lifecycle: lifecycle ?? this.lifecycle,
        kind: kind ?? this.kind,
        direction: direction ?? this.direction,
        callId: callId ?? this.callId,
        conversationId: conversationId ?? this.conversationId,
        peerIdentityId: peerIdentityId ?? this.peerIdentityId,
        muted: muted ?? this.muted,
        cameraEnabled: cameraEnabled ?? this.cameraEnabled,
        speakerEnabled: speakerEnabled ?? this.speakerEnabled,
        remoteRinging: remoteRinging ?? this.remoteRinging,
        remoteVideoAvailable: remoteVideoAvailable ?? this.remoteVideoAvailable,
        remoteCameraEnabled: remoteCameraEnabled ?? this.remoteCameraEnabled,
        quality: quality ?? this.quality,
        startedAt: startedAt ?? this.startedAt,
        answeredAt: answeredAt ?? this.answeredAt,
        endedAt: endedAt ?? this.endedAt,
        endReason: endReason ?? this.endReason,
        reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
        error: clearError ? null : error ?? this.error,
      );
}

class LoomCallEngine extends ChangeNotifier {
  LoomCallEngine({
    required this.api,
    required this.signaling,
    required this.localIdentityId,
    Random? random,
  }) : _random = random ?? Random.secure();

  final LoomCallApi api;
  final LoomCallSignalingConnection signaling;
  final String localIdentityId;
  final Random _random;

  LoomCallSnapshot _state = const LoomCallSnapshot();
  LoomCallSnapshot get state => _state;
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  StreamSubscription<LoomCallSignal>? _signalSubscription;
  int _sequence = 0;
  Timer? _ringTimeout;
  Timer? _statsTimer;
  Timer? _reconnectTimer;
  Timer? _reconnectDeadline;
  final Set<String> _remoteSequences = <String>{};
  final List<RTCIceCandidate> _pendingRemoteCandidates = <RTCIceCandidate>[];
  final List<RTCIceCandidate> _pendingLocalCandidates = <RTCIceCandidate>[];
  late final _incomingIce = LoomIncomingIceBuffer(localIdentityId);
  bool _remoteDescriptionSet = false;
  bool _localDescriptionSent = false;
  bool _iceRestartInFlight = false;
  double _lastPacketsLost = 0;
  bool _starting = false;
  bool _disposed = false;
  Future<void>? _finishing;

  Future<void> initialize() async {
    _signalSubscription ??= signaling.signals.listen(
      _handleSignal,
      onError: _onSignalError,
    );
    await signaling.connect();
  }

  Future<void> startOutgoing({
    required String conversationId,
    required String peerIdentityId,
    required LoomCallKind kind,
  }) async {
    _ensureIdle();
    _starting = true;
    _resetPerCallInternals();
    final callId = _newCallId();
    _set(
      LoomCallSnapshot(
        lifecycle: LoomCallLifecycle.preparing,
        kind: kind,
        direction: LoomCallDirection.outgoing,
        callId: callId,
        conversationId: conversationId,
        peerIdentityId: peerIdentityId,
        cameraEnabled: kind == LoomCallKind.video,
        startedAt: DateTime.now().toUtc(),
      ),
    );
    try {
      await _preparePeer(kind);
      _requireActiveAttempt(callId);
      final offer = await _peer!.createOffer(<String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': kind == LoomCallKind.video,
      });
      _requireActiveAttempt(callId);
      await _peer!.setLocalDescription(offer);
      _requireActiveAttempt(callId);
      await _send('call.offer', sdp: offer.sdp, sdpType: offer.type);
      _requireActiveAttempt(callId);
      if (_state.lifecycle == LoomCallLifecycle.connected) return;
      _set(
        _state.copyWith(
          lifecycle: LoomCallLifecycle.ringing,
          remoteRinging: false,
          clearError: true,
        ),
      );
      _ringTimeout = Timer(
        const Duration(seconds: 45),
        () => unawaited(_finish(LoomCallEndReason.timeout, signal: true)),
      );
    } catch (error) {
      final reason = _classifyStartError(error);
      if (_state.callId == callId && _state.active) await _fail(error, reason);
      await _finishing;
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> acceptPending(LoomPendingCall pending) async {
    _ensureIdle();
    if (!pending.expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const LoomProtocolException('Pending call has expired');
    }
    _starting = true;
    final gathered =
        _incomingIce.take(pending.callId, pending.callerIdentityId);
    _resetPerCallInternals();
    _pendingRemoteCandidates.addAll(gathered.map((signal) => RTCIceCandidate(
          signal.candidate,
          signal.sdpMid,
          signal.sdpMLineIndex,
        )));
    _set(
      LoomCallSnapshot(
        lifecycle: LoomCallLifecycle.preparing,
        kind: pending.kind,
        direction: LoomCallDirection.incoming,
        callId: pending.callId,
        conversationId: pending.conversationId,
        peerIdentityId: pending.callerIdentityId,
        cameraEnabled: pending.kind == LoomCallKind.video,
        startedAt: pending.createdAt,
      ),
    );
    try {
      await _preparePeer(pending.kind);
      _requireActiveAttempt(pending.callId);
      await _setRemoteDescription(
        RTCSessionDescription(pending.offerSdp, 'offer'),
      );
      _requireActiveAttempt(pending.callId);
      final answer = await _peer!.createAnswer(<String, dynamic>{
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': pending.kind == LoomCallKind.video,
      });
      _requireActiveAttempt(pending.callId);
      await _peer!.setLocalDescription(answer);
      _requireActiveAttempt(pending.callId);
      await _send('call.answer', sdp: answer.sdp, sdpType: answer.type);
      _requireActiveAttempt(pending.callId);
      if (_state.lifecycle == LoomCallLifecycle.connected) return;
      _set(
        _state.copyWith(
          lifecycle: LoomCallLifecycle.connecting,
          clearError: true,
        ),
      );
    } catch (error) {
      final reason = _classifyStartError(error);
      if (_state.callId == pending.callId && _state.active) {
        await _fail(error, reason);
      }
      await _finishing;
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> signalRinging(LoomPendingCall pending) =>
      _signalPending(pending, kind: 'call.ringing', reason: 'presented');

  Future<void> rejectPending(LoomPendingCall pending) =>
      _signalPending(pending, kind: 'call.reject', reason: 'rejected');

  Future<void> busyPending(LoomPendingCall pending) =>
      _signalPending(pending, kind: 'call.busy', reason: 'busy');

  Future<void> _signalPending(
    LoomPendingCall pending, {
    required String kind,
    required String reason,
  }) async {
    await signaling.send(
      LoomCallSignal(
        callId: pending.callId,
        conversationId: pending.conversationId,
        senderIdentityId: localIdentityId,
        targetIdentityId: pending.callerIdentityId,
        kind: kind,
        sequence: ++_sequence,
        createdAt: DateTime.now().toUtc(),
        reason: reason,
        mediaKind: pending.kind,
      ),
    );
  }

  Future<void> setMuted(bool muted) async {
    for (final track
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    _set(_state.copyWith(muted: muted));
  }

  Future<void> setCameraEnabled(bool enabled) async {
    if (_state.kind != LoomCallKind.video) return;
    for (final track
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
    _set(_state.copyWith(cameraEnabled: enabled));
    if (_state.callId != null && _state.active) {
      try {
        await _send('call.media', reason: enabled ? 'camera-on' : 'camera-off');
      } catch (_) {
        // A media-state hint must not terminate a healthy WebRTC connection.
      }
    }
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> setSpeakerEnabled(bool enabled) async {
    await Helper.setSpeakerphoneOn(enabled);
    _set(_state.copyWith(speakerEnabled: enabled));
  }

  Future<void> hangUp() =>
      _finish(LoomCallEndReason.localHangup, signal: true);

  Future<void> restartIce() async {
    final peer = _peer;
    if (peer == null || _iceRestartInFlight || !_state.active) return;
    final callId = _state.callId!;
    _iceRestartInFlight = true;
    try {
      _set(
        _state.copyWith(
          lifecycle: LoomCallLifecycle.reconnecting,
          reconnectAttempts: _state.reconnectAttempts + 1,
        ),
      );
      final offer = await peer.createOffer(<String, dynamic>{
        'iceRestart': true,
      });
      _requireActiveAttempt(callId);
      _localDescriptionSent = false;
      await peer.setLocalDescription(offer);
      _requireActiveAttempt(callId);
      await _send('call.offer', sdp: offer.sdp, sdpType: offer.type);
    } catch (error) {
      if (_state.callId == callId &&
          _state.active &&
          _state.reconnectAttempts >= 2) {
        await _fail(error, LoomCallEndReason.connectionFailure);
      }
    } finally {
      _iceRestartInFlight = false;
    }
  }

  Future<void> _preparePeer(LoomCallKind kind) async {
    final callId = _state.callId!;
    final config = await api.fetchRtcConfiguration();
    _requireActiveAttempt(callId);
    if (!config.expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const LoomProtocolException(
        'RTC credentials are already expired',
      );
    }
    localRenderer = RTCVideoRenderer();
    remoteRenderer = RTCVideoRenderer();
    await localRenderer!.initialize();
    _requireActiveAttempt(callId);
    await remoteRenderer!.initialize();
    _requireActiveAttempt(callId);
    final stream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': <String, dynamic>{
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': kind == LoomCallKind.video
          ? <String, dynamic>{
              'facingMode': 'user',
              'width': <String, dynamic>{'ideal': 1280},
              'height': <String, dynamic>{'ideal': 720},
              'frameRate': <String, dynamic>{'ideal': 30, 'max': 30},
            }
          : false,
    });
    if (!_state.active || _state.callId != callId || _disposed) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      await stream.dispose();
      _requireActiveAttempt(callId);
    }
    _localStream = stream;
    localRenderer!.srcObject = stream;
    final peer = await createPeerConnection(<String, dynamic>{
      'iceServers': config.iceServers
          .map((server) => server.toJson())
          .toList(growable: false),
      'sdpSemantics': 'unified-plan',
    });
    if (!_state.active || _state.callId != callId || _disposed) {
      await peer.close();
      _requireActiveAttempt(callId);
    }
    _peer = peer;
    for (final track in stream.getTracks()) {
      await peer.addTrack(track, stream);
      _requireActiveAttempt(callId);
    }
    peer.onIceCandidate = (candidate) {
      if (!_state.active || _state.callId != callId || _disposed) return;
      if (candidate.candidate?.isNotEmpty == true) {
        // Native ICE gathering can start during setLocalDescription. The peer
        // must see our offer/answer before any of its trickled candidates.
        if (!_localDescriptionSent) {
          if (_pendingLocalCandidates.length < 256) {
            _pendingLocalCandidates.add(candidate);
          }
          return;
        }
        unawaited(
          _send(
            'call.ice',
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
          ).catchError((Object error) {
            if (_state.callId == callId && _state.active) _onSignalError(error);
          }),
        );
      }
    };
    peer.onTrack = (event) {
      if (!_state.active ||
          _state.callId != callId ||
          _disposed ||
          event.streams.isEmpty) {
        return;
      }
      _remoteStream = event.streams.first;
      remoteRenderer?.srcObject = _remoteStream;
      if (event.track.kind == 'video') {
        _set(_state.copyWith(remoteVideoAvailable: true));
      }
    };
    peer.onConnectionState = (connectionState) {
      if (!_state.active || _state.callId != callId || _disposed) return;
      switch (connectionState) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _ringTimeout?.cancel();
          _cancelReconnect();
          _set(
            _state.copyWith(
              lifecycle: LoomCallLifecycle.connected,
              answeredAt: _state.answeredAt ?? DateTime.now().toUtc(),
              reconnectAttempts: 0,
              clearError: true,
            ),
          );
          _startStats();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          if (_state.active) _scheduleIceRestart();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _scheduleIceRestart(immediate: true);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          break;
        default:
          break;
      }
    };
  }

  Future<void> _handleSignal(LoomCallSignal signal) async {
    if (_disposed || signal.targetIdentityId != localIdentityId) return;
    if (!_state.active) {
      _incomingIce.observe(signal);
      return;
    }
    final dedupeKey =
        '${signal.callId}\n${signal.senderIdentityId}\n${signal.sequence}';
    if (!_remoteSequences.add(dedupeKey)) return;
    if (_remoteSequences.length > 4096) {
      _remoteSequences.clear();
      _remoteSequences.add(dedupeKey);
    }
    if (_state.callId != signal.callId ||
        _state.peerIdentityId != signal.senderIdentityId) {
      return;
    }
    if (signal.kind == 'call.ice' &&
        signal.candidate != null &&
        !_remoteDescriptionSet) {
      if (_pendingRemoteCandidates.length < 256) {
        _pendingRemoteCandidates.add(RTCIceCandidate(
          signal.candidate,
          signal.sdpMid,
          signal.sdpMLineIndex,
        ));
      }
      return;
    }
    // Remote cancellation/rejection can arrive before native media exists.
    if (signal.kind == 'call.busy' ||
        signal.kind == 'call.reject' ||
        signal.kind == 'call.end') {
      await _finish(
          switch (signal.kind) {
            'call.busy' => LoomCallEndReason.busy,
            'call.reject' => LoomCallEndReason.rejected,
            _ => _remoteEndReason(signal.reason),
          },
          signal: false);
      return;
    }
    final peer = _peer;
    if (peer == null) return;
    try {
      switch (signal.kind) {
        case 'call.ringing':
          if (_state.lifecycle == LoomCallLifecycle.connected) return;
          _set(
            _state.copyWith(
              lifecycle: LoomCallLifecycle.ringing,
              remoteRinging: true,
              clearError: true,
            ),
          );
          break;
        case 'call.answer':
          if (signal.sdp == null || signal.sdpType == null) return;
          await _setRemoteDescription(
            RTCSessionDescription(signal.sdp!, signal.sdpType!),
          );
          _requireActiveAttempt(signal.callId);
          if (_state.lifecycle == LoomCallLifecycle.connected) return;
          _set(
            _state.copyWith(
              lifecycle: LoomCallLifecycle.connecting,
              clearError: true,
            ),
          );
          break;
        case 'call.offer':
          if (signal.sdp == null || signal.sdpType == null) return;
          await _setRemoteDescription(
            RTCSessionDescription(signal.sdp!, signal.sdpType!),
          );
          _requireActiveAttempt(signal.callId);
          final answer = await peer.createAnswer(<String, dynamic>{
            'offerToReceiveAudio': true,
            'offerToReceiveVideo': _state.kind == LoomCallKind.video,
          });
          _requireActiveAttempt(signal.callId);
          _localDescriptionSent = false;
          await peer.setLocalDescription(answer);
          _requireActiveAttempt(signal.callId);
          await _send('call.answer', sdp: answer.sdp, sdpType: answer.type);
          break;
        case 'call.ice':
          if (signal.candidate == null) return;
          final candidate = RTCIceCandidate(
            signal.candidate,
            signal.sdpMid,
            signal.sdpMLineIndex,
          );
          if (_remoteDescriptionSet) {
            await peer.addCandidate(candidate);
          } else {
            _pendingRemoteCandidates.add(candidate);
            if (_pendingRemoteCandidates.length > 256) {
              _pendingRemoteCandidates.removeAt(0);
            }
          }
          break;
        case 'call.media':
          if (signal.reason == 'camera-off') {
            _set(_state.copyWith(remoteCameraEnabled: false));
          } else if (signal.reason == 'camera-on') {
            _set(_state.copyWith(remoteCameraEnabled: true));
          }
          break;
      }
    } catch (error) {
      if (_state.callId == signal.callId && _state.active) {
        await _fail(error, LoomCallEndReason.signalingFailure);
      }
    }
  }

  Future<void> _setRemoteDescription(RTCSessionDescription description) async {
    final peer = _peer;
    if (peer == null) return;
    final callId = _state.callId!;
    await peer.setRemoteDescription(description);
    _requireActiveAttempt(callId);
    _remoteDescriptionSet = true;
    if (_pendingRemoteCandidates.isNotEmpty) {
      final pending = List<RTCIceCandidate>.of(_pendingRemoteCandidates);
      _pendingRemoteCandidates.clear();
      for (final candidate in pending) {
        await peer.addCandidate(candidate);
        _requireActiveAttempt(callId);
      }
    }
  }

  Future<void> _send(
    String kind, {
    String? sdp,
    String? sdpType,
    String? candidate,
    String? sdpMid,
    int? sdpMLineIndex,
    String? reason,
  }) async {
    final callId = _state.callId;
    final conversationId = _state.conversationId;
    final peerIdentityId = _state.peerIdentityId;
    if (callId == null || conversationId == null || peerIdentityId == null) {
      return;
    }
    await signaling.send(
      LoomCallSignal(
        callId: callId,
        conversationId: conversationId,
        senderIdentityId: localIdentityId,
        targetIdentityId: peerIdentityId,
        kind: kind,
        sequence: ++_sequence,
        createdAt: DateTime.now().toUtc(),
        sdp: sdp,
        sdpType: sdpType,
        candidate: candidate,
        sdpMid: sdpMid,
        sdpMLineIndex: sdpMLineIndex,
        reason: reason,
        mediaKind: _state.kind,
      ),
    );
    if (kind == 'call.offer' || kind == 'call.answer') {
      _requireActiveAttempt(callId);
      _localDescriptionSent = true;
      final pending = List<RTCIceCandidate>.of(_pendingLocalCandidates);
      _pendingLocalCandidates.clear();
      for (final candidate in pending) {
        _requireActiveAttempt(callId);
        await _send(
          'call.ice',
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        );
      }
    }
  }

  void _startStats() {
    _statsTimer?.cancel();
    _lastPacketsLost = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      final peer = _peer;
      if (peer == null) return;
      try {
        final reports = await peer.getStats();
        var packetsLost = 0.0;
        var jitter = 0.0;
        var roundTripTime = 0.0;
        for (final report in reports) {
          final values = report.values;
          final loss = values['packetsLost'];
          final reportJitter = values['jitter'];
          final rtt = values['roundTripTime'] ?? values['currentRoundTripTime'];
          if (loss is num) packetsLost += loss.toDouble();
          if (reportJitter is num) {
            jitter = max(jitter, reportJitter.toDouble());
          }
          if (rtt is num) roundTripTime = max(roundTripTime, rtt.toDouble());
        }
        final lossDelta = max(0.0, packetsLost - _lastPacketsLost);
        _lastPacketsLost = packetsLost;
        final quality = jitter > 0.08 || lossDelta > 30 || roundTripTime > 1.0
            ? LoomCallQuality.poor
            : jitter > 0.04 || lossDelta > 10 || roundTripTime > .55
                ? LoomCallQuality.constrained
                : jitter > 0.02 || lossDelta > 2 || roundTripTime > .3
                    ? LoomCallQuality.good
                    : LoomCallQuality.excellent;
        _set(_state.copyWith(quality: quality));
      } catch (_) {
        // Stats failure must not terminate a call.
      }
    });
  }

  void _scheduleIceRestart({bool immediate = false}) {
    if (!_state.active ||
        _state.lifecycle == LoomCallLifecycle.ended ||
        _state.lifecycle == LoomCallLifecycle.failed) {
      return;
    }
    _set(_state.copyWith(lifecycle: LoomCallLifecycle.reconnecting));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      immediate ? Duration.zero : const Duration(seconds: 2),
      () {
        unawaited(restartIce());
      },
    );
    _reconnectDeadline ??= Timer(const Duration(seconds: 20), () {
      if (_state.lifecycle == LoomCallLifecycle.reconnecting) {
        unawaited(
          _fail(
            StateError('Peer connection did not recover'),
            LoomCallEndReason.connectionFailure,
          ),
        );
      }
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectDeadline?.cancel();
    _reconnectDeadline = null;
    _iceRestartInFlight = false;
  }

  Future<void> _fail(Object error, LoomCallEndReason reason) async {
    if (!_state.active) return;
    _set(
      _state.copyWith(
        lifecycle: LoomCallLifecycle.failed,
        error: error,
        endReason: reason,
        endedAt: DateTime.now().toUtc(),
      ),
    );
    await _finish(reason, signal: true, preserveFailure: true);
  }

  Future<void> _finish(
    LoomCallEndReason reason, {
    required bool signal,
    bool preserveFailure = false,
  }) =>
      _finishing ??= _finishOnce(
        reason,
        signal: signal,
        preserveFailure: preserveFailure,
      ).whenComplete(() => _finishing = null);

  Future<void> _finishOnce(
    LoomCallEndReason reason, {
    required bool signal,
    required bool preserveFailure,
  }) async {
    if (_state.lifecycle == LoomCallLifecycle.ended &&
        _state.endReason != null) {
      return;
    }
    _ringTimeout?.cancel();
    _statsTimer?.cancel();
    _cancelReconnect();
    // Publish a terminal state before asynchronous cleanup. Late native events
    // must not restore Connected after a server rejection or a local hangup.
    _set(
      _state.copyWith(
        lifecycle: preserveFailure
            ? LoomCallLifecycle.failed
            : LoomCallLifecycle.ended,
        endReason: reason,
        endedAt: _state.endedAt ?? DateTime.now().toUtc(),
        remoteVideoAvailable: false,
      ),
    );
    final peer = _peer;
    final stream = _localStream;
    final local = localRenderer;
    final remote = remoteRenderer;
    _peer = null;
    _localStream = null;
    _remoteStream = null;
    localRenderer = null;
    remoteRenderer = null;
    try {
      await peer?.close();
    } catch (_) {}
    for (final track in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream?.dispose();
    } catch (_) {}
    local?.srcObject = null;
    remote?.srcObject = null;
    try {
      await local?.dispose();
    } catch (_) {}
    try {
      await remote?.dispose();
    } catch (_) {}
    // Release microphone/camera even if signaling is unreachable.
    if (signal && _state.callId != null && !_disposed) {
      unawaited(
        _send('call.end', reason: reason.name).catchError((Object _) {}),
      );
    }
  }

  void _requireActiveAttempt(String callId) {
    if (_disposed || _state.callId != callId || !_state.active) {
      throw _state.error ??
          StateError('The call ended before it could connect.');
    }
  }

  void _onSignalError(Object error) {
    if (_disposed) return;
    if (error is LoomCallSignalingException) {
      if (error.callId == _state.callId && _state.active) {
        unawaited(_fail(error, LoomCallEndReason.signalingFailure));
      }
      return;
    }
    if (_state.active) {
      _set(
        _state.copyWith(
          lifecycle: LoomCallLifecycle.reconnecting,
          error: error,
        ),
      );
      _scheduleIceRestart();
    }
  }

  LoomCallEndReason _classifyStartError(Object error) {
    if (error is LoomCallSignalingException) {
      return LoomCallEndReason.signalingFailure;
    }
    final text = error.toString().toLowerCase();
    if (text.contains('permission') ||
        text.contains('notallowed') ||
        text.contains('not allowed') ||
        text.contains('denied')) {
      return LoomCallEndReason.permissionDenied;
    }
    if (text.contains('signaling') ||
        text.contains('websocket') ||
        text.contains('http ') ||
        text.contains('calls_disabled') ||
        text.contains('turn_') ||
        text.contains('rtc configuration')) {
      return LoomCallEndReason.signalingFailure;
    }
    return LoomCallEndReason.mediaFailure;
  }

  LoomCallEndReason _remoteEndReason(String? reason) {
    return switch (reason) {
      'busy' => LoomCallEndReason.busy,
      'rejected' => LoomCallEndReason.rejected,
      'timeout' => LoomCallEndReason.timeout,
      _ => LoomCallEndReason.remoteHangup,
    };
  }

  void _ensureIdle() {
    if (_disposed) throw StateError('The call session is closed');
    if (_starting || _finishing != null) {
      throw StateError('A call is already active or closing');
    }
    if (_state.lifecycle != LoomCallLifecycle.idle &&
        _state.lifecycle != LoomCallLifecycle.ended &&
        _state.lifecycle != LoomCallLifecycle.failed) {
      throw StateError('A call is already active');
    }
  }

  void _resetPerCallInternals() {
    _ringTimeout?.cancel();
    _statsTimer?.cancel();
    _cancelReconnect();
    _remoteSequences.clear();
    _pendingRemoteCandidates.clear();
    _pendingLocalCandidates.clear();
    _remoteDescriptionSet = false;
    _localDescriptionSent = false;
    _sequence = 0;
    _lastPacketsLost = 0;
  }

  String _newCallId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final random = List<int>.generate(
      16,
      (_) => _random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return 'call-$now-$random';
  }

  void _set(LoomCallSnapshot next) {
    _state = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _incomingIce.clear();
    _ringTimeout?.cancel();
    _statsTimer?.cancel();
    _cancelReconnect();
    unawaited(_signalSubscription?.cancel());
    unawaited(signaling.dispose());
    unawaited(_finish(LoomCallEndReason.localHangup, signal: false));
    super.dispose();
  }
}

class LoomIncomingCallMonitor {
  LoomIncomingCallMonitor({
    required this.signaling,
    required this.localIdentityId,
  });

  final LoomCallSignalingConnection signaling;
  final String localIdentityId;
  final StreamController<LoomCallSignal> _incoming =
      StreamController<LoomCallSignal>.broadcast();
  StreamSubscription<LoomCallSignal>? _subscription;
  final Set<String> _seenCallIds = <String>{};
  Stream<LoomCallSignal> get incoming => _incoming.stream;

  void start() {
    _subscription ??= signaling.signals.listen((signal) {
      if (signal.kind == 'call.offer' &&
          signal.targetIdentityId == localIdentityId &&
          signal.mediaKind != null &&
          _seenCallIds.add(signal.callId)) {
        if (_seenCallIds.length > 512) _seenCallIds.clear();
        _incoming.add(signal);
      }
    }, onError: _incoming.addError);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _incoming.close();
  }
}
