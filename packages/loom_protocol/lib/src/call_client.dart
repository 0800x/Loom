import 'transport_security.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';

import 'device_request_proof.dart';
import 'node_client.dart';

// Unlike identifiers and HTTP credentials, SDP must retain its line breaks.
String? _callSdp(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      utf8.encode(value).length > 512 * 1024 ||
      value.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'))) {
    return null;
  }
  return value;
}

/// A definitive server rejection tied to one call, not a socket outage.
class LoomCallSignalingException extends LoomProtocolException {
  const LoomCallSignalingException(this.callId, String reason) : super(reason);
  final String callId;
}

abstract interface class LoomCallApi {
  Future<LoomRtcConfiguration> fetchRtcConfiguration();
  Future<List<LoomPendingCall>> fetchPendingCalls();
}

class LoomCallClient implements LoomCallApi {
  LoomCallClient({
    required this.baseUri,
    required this.accessTokenProvider,
    required this.deviceProofProvider,
    this.refreshRejectedToken,
    this.trace,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final Uri baseUri;
  final Future<String> Function() accessTokenProvider;
  final LoomDeviceRequestProofProvider deviceProofProvider;
  final Future<bool> Function(String rejectedToken)? refreshRejectedToken;

  /// Receives stage names only, never credentials, SDP, identities or payloads.
  final void Function(String stage)? trace;
  final HttpClient _http;

  void close() => _http.close(force: true);

  @override
  Future<LoomRtcConfiguration> fetchRtcConfiguration() async {
    final json = await _getJson('/api/v1/calls/rtc-config');
    final servers = json['iceServers'];
    final expiresAt = json['expiresAt'];
    if (servers is! List || servers.length > 16 || expiresAt is! String) {
      throw const LoomProtocolException('Malformed RTC configuration');
    }
    final parsed = <LoomIceServer>[];
    for (final value in servers) {
      if (value is! Map<String, Object?>) {
        throw const LoomProtocolException('Malformed ICE server');
      }
      final urlsValue = value['urls'];
      final urls = urlsValue is String
          ? <String>[urlsValue]
          : urlsValue is List
          ? urlsValue.whereType<String>().toList(growable: false)
          : const <String>[];
      if (urls.isEmpty ||
          urls.length > 8 ||
          urls.any((url) => !_validIceUrl(url))) {
        throw const LoomProtocolException('Invalid ICE server URL');
      }
      final username = value['username'];
      final credential = value['credential'];
      if (username != null && (username is! String || username.length > 512)) {
        throw const LoomProtocolException('Invalid TURN username');
      }
      if (credential != null &&
          (credential is! String ||
              credential.length > 2048 ||
              credential.contains(RegExp(r'[\r\n]')))) {
        throw const LoomProtocolException('Invalid TURN credential');
      }
      if (urls.any((url) => url.toLowerCase().startsWith('turn')) &&
          (username is! String || credential is! String)) {
        throw const LoomProtocolException(
          'TURN server is missing authentication',
        );
      }
      parsed.add(
        LoomIceServer(
          urls: urls,
          username: username as String?,
          credential: credential as String?,
        ),
      );
    }
    final expiry = DateTime.tryParse(expiresAt)?.toUtc();
    if (expiry == null || expiry.isBefore(DateTime.now().toUtc())) {
      throw const LoomProtocolException('RTC configuration has expired');
    }
    return LoomRtcConfiguration(iceServers: parsed, expiresAt: expiry);
  }

  @override
  Future<List<LoomPendingCall>> fetchPendingCalls() async {
    trace?.call('pending_http_start');
    final json = await _getJson('/api/v1/calls/pending');
    final calls = json['calls'];
    if (calls is! List || calls.length > 32) {
      throw const LoomProtocolException('Malformed pending-call response');
    }
    final result = <LoomPendingCall>[];
    for (final value in calls) {
      if (value is! Map<String, Object?>) {
        continue;
      }
      try {
        final kind = _kind(value['kind']);
        final createdAt = DateTime.parse(_required(value, 'createdAt', 80))
            .toUtc();
        final expiresAt = DateTime.parse(_required(value, 'expiresAt', 80))
            .toUtc();
        if (expiresAt.isBefore(DateTime.now().toUtc())) {
          trace?.call('pending_rejected:expired');
          continue;
        }
        if (expiresAt.difference(createdAt) > const Duration(minutes: 2)) {
          trace?.call('pending_rejected:lifetime');
          continue;
        }
        final offer = _callSdp(value['offerSdp']);
        if (offer == null) {
          trace?.call('pending_rejected:sdp');
          continue;
        }
        result.add(
          LoomPendingCall(
            callId: _required(value, 'callId', 200),
            conversationId: _required(value, 'conversationId', 256),
            callerIdentityId: _required(value, 'callerIdentityId', 128),
            kind: kind,
            createdAt: createdAt,
            expiresAt: expiresAt,
            offerSdp: offer,
          ),
        );
      } catch (_) {
        trace?.call('pending_rejected:fields');
        // One malformed pending call must not hide otherwise valid calls.
      }
    }
    trace?.call('pending_http_ok:${result.length}');
    return List<LoomPendingCall>.unmodifiable(result);
  }

  Future<Map<String, Object?>> _getJson(
    String path, {
    bool retryAuthentication = true,
  }) async {
    _requireSafeBaseUri(baseUri);
    final token = await accessTokenProvider();
    _requireBearer(token);
    final uri = baseUri.resolve(path);
    final proofHeaders = await deviceProofProvider.headers(
      method: 'GET',
      uri: uri,
      credential: token,
    );
    final request = await _http.getUrl(uri).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final response = await request.close().timeout(const Duration(seconds: 12));
    trace?.call('call_http_status:${response.statusCode}');
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 12))) {
      bytes.addAll(chunk);
      if (bytes.length > 1024 * 1024) {
        throw const LoomProtocolException('Call response exceeds size limit');
      }
    }
    if (response.statusCode == HttpStatus.unauthorized &&
        retryAuthentication &&
        refreshRejectedToken != null &&
        await refreshRejectedToken!(token)) {
      return _getJson(path, retryAuthentication: false);
    }
    if (response.statusCode != HttpStatus.ok) {
      var detail = 'Call request failed with HTTP ${response.statusCode}';
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, Object?> && decoded['error'] is String) {
          detail = decoded['error'] as String;
        }
      } catch (_) {}
      throw LoomProtocolException(switch (detail) {
        'calls_disabled' => 'Calls are not enabled on your Home Node.',
        'unauthorized' => 'Your session expired. Reconnect to sign in again.',
        'rtc_unavailable' ||
        'turn_required' ||
        'turn_credentials_unavailable' =>
          'Your Home Node is not ready for calls yet.',
        _ => detail,
      });
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const LoomProtocolException('Invalid call JSON response');
    }
    return decoded;
  }

  bool _validIceUrl(String url) {
    if (url.isEmpty || url.length > 2048 || url.contains(RegExp(r'[\r\n]'))) {
      return false;
    }
    final lower = url.toLowerCase();
    return lower.startsWith('stun:') ||
        lower.startsWith('turn:') ||
        lower.startsWith('turns:');
  }

  LoomCallKind _kind(Object? value) => switch (value) {
    'audio' => LoomCallKind.audio,
    'video' => LoomCallKind.video,
    _ => throw const FormatException('Invalid call kind'),
  };

  String _required(Map<String, Object?> json, String key, int max) {
    final value = json[key];
    if (value is! String ||
        value.isEmpty ||
        value.length > max ||
        value.contains(RegExp(r'[\r\n]'))) {
      throw FormatException('Invalid $key');
    }
    return value;
  }

  void _requireBearer(String token) {
    if (token.trim().isEmpty ||
        token.length > 8192 ||
        token.contains(RegExp(r'[\r\n]'))) {
      throw const LoomProtocolException('Invalid access token');
    }
  }

  void _requireSafeBaseUri(Uri uri) => requireLoomTransport(uri);
}

class LoomCallSignalingConnection {
  LoomCallSignalingConnection({
    required this.baseUri,
    required this.accessTokenProvider,
    required this.deviceProofProvider,
    this.trace,
  });

  final Uri baseUri;
  final Future<String> Function() accessTokenProvider;
  final LoomDeviceRequestProofProvider deviceProofProvider;

  /// Receives stage names only, never credentials, SDP, identities or payloads.
  final void Function(String stage)? trace;
  final StreamController<LoomCallSignal> _controller =
      StreamController<LoomCallSignal>.broadcast();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _connecting;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  bool _manualClose = false;

  Stream<LoomCallSignal> get signals => _controller.stream;
  bool get connected => _socket?.readyState == WebSocket.open;

  Future<void> connect() => _connecting ??= _connectWithRecovery().whenComplete(
    () => _connecting = null,
  );

  Future<void> _connectWithRecovery() async {
    try {
      await _connectOnce();
    } catch (error) {
      trace?.call('socket_failed:${error.runtimeType}');
      // Initial WebSocket failures used to leave the call channel permanently
      // disconnected until the whole app/session was recreated. Keep retrying
      // while the signed-in session is alive.
      _scheduleReconnect();
      rethrow;
    }
  }

  Future<void> _connectOnce() async {
    if (_disposed || connected) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _manualClose = false;
    await _subscription?.cancel();
    await _socket?.close();
    _socket = null;

    trace?.call('socket_connect_start');
    final token = await accessTokenProvider();
    if (token.trim().isEmpty ||
        token.length > 8192 ||
        token.contains(RegExp(r'[\r\n]'))) {
      throw const LoomProtocolException('Invalid signaling token');
    }
    final uri = _webSocketUri(baseUri);
    final proof = await deviceProofProvider.headers(
      method: 'GET',
      uri: uri,
      credential: token,
    );
    final headers = <String, dynamic>{
      HttpHeaders.authorizationHeader: 'Bearer $token',
      ...proof,
    };
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: headers,
    ).timeout(const Duration(seconds: 10));
    if (_disposed) {
      await socket.close();
      return;
    }
    _socket = socket;
    trace?.call('socket_connected');
    _reconnectAttempt = 0;
    _subscription = socket.listen(
      _onData,
      onError: (Object error, StackTrace stack) {
        trace?.call('socket_error:${error.runtimeType}');
        if (!_disposed) {
          _controller.addError(error, stack);
        }
        _scheduleReconnect();
      },
      onDone: _scheduleReconnect,
      cancelOnError: false,
    );
  }

  Future<void> send(LoomCallSignal signal) async {
    if (!connected) {
      await connect();
    }
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw const LoomProtocolException('Call signaling is not connected');
    }
    final payload = <String, Object?>{
      'kind': signal.kind,
      'callId': signal.callId,
      'conversationId': signal.conversationId,
      'targetIdentityId': signal.targetIdentityId,
      'sequence': signal.sequence,
      'createdAt': signal.createdAt.toUtc().toIso8601String(),
      if (signal.sdp != null) 'sdp': signal.sdp,
      if (signal.sdpType != null) 'sdpType': signal.sdpType,
      if (signal.candidate != null) 'candidate': signal.candidate,
      if (signal.sdpMid != null) 'sdpMid': signal.sdpMid,
      if (signal.sdpMLineIndex != null) 'sdpMLineIndex': signal.sdpMLineIndex,
      if (signal.reason != null) 'reason': signal.reason,
      if (signal.mediaKind != null) 'mediaKind': signal.mediaKind!.name,
    };
    socket.add(jsonEncode(payload));
    if (signal.kind == 'call.offer') trace?.call('offer_socket_queued');
  }

  void _onData(dynamic data) {
    try {
      if (data is! String || utf8.encode(data).length > 768 * 1024) {
        return;
      }
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, Object?>) {
        return;
      }
      final kind = decoded['kind'];
      if (kind == 'call.offer') trace?.call('offer_frame_received');
      if (kind == 'call.error') {
        trace?.call('call_error_received');
        final callId = _safe(decoded['callId'], 200);
        if (callId == null) {
          return;
        }
        final reason = _safe(decoded['reason'], 256);
        _controller.addError(
          LoomCallSignalingException(callId, reason ?? 'call_signaling_failed'),
        );
        return;
      }
      if (kind is! String || !_supportedSignalKind(kind)) {
        return;
      }
      final callId = _safe(decoded['callId'], 200);
      final conversationId = _safe(decoded['conversationId'], 256);
      final senderIdentityId = _safe(decoded['senderIdentityId'], 128);
      final targetIdentityId = _safe(decoded['targetIdentityId'], 128);
      final sequence = decoded['sequence'];
      final createdAtValue = decoded['createdAt'];
      if (callId == null ||
          conversationId == null ||
          senderIdentityId == null ||
          targetIdentityId == null ||
          sequence is! num ||
          sequence < 0 ||
          sequence.toInt() != sequence ||
          createdAtValue is! String) {
        if (kind == 'call.offer') trace?.call('offer_rejected:fields');
        return;
      }
      final createdAt = DateTime.tryParse(createdAtValue)?.toUtc();
      final now = DateTime.now().toUtc();
      if (createdAt == null) {
        if (kind == 'call.offer') trace?.call('offer_rejected:date');
        return;
      }
      if (createdAt.isBefore(now.subtract(const Duration(minutes: 3)))) {
        if (kind == 'call.offer') trace?.call('offer_rejected:clock_old');
        return;
      }
      if (createdAt.isAfter(now.add(const Duration(minutes: 1)))) {
        if (kind == 'call.offer') trace?.call('offer_rejected:clock_future');
        return;
      }
      final sdp = _callSdp(decoded['sdp']);
      if (decoded['sdp'] != null && sdp == null) {
        if (kind == 'call.offer') trace?.call('offer_rejected:sdp');
        return;
      }
      final sdpType = _optional(decoded['sdpType'], 16);
      final candidate = _optional(decoded['candidate'], 16 * 1024);
      final sdpMid = _optional(decoded['sdpMid'], 256);
      final mline = decoded['sdpMLineIndex'];
      final reason = _optional(decoded['reason'], 128);
      final mediaValue = decoded['mediaKind'];
      final mediaKind = switch (mediaValue) {
        'audio' => LoomCallKind.audio,
        'video' => LoomCallKind.video,
        _ => null,
      };
      if (kind == 'call.offer' &&
          (sdp == null || sdpType != 'offer' || mediaKind == null)) {
        trace?.call('offer_rejected:media_or_sdp');
        return;
      }
      if (kind == 'call.answer' && (sdp == null || sdpType != 'answer')) {
        return;
      }
      if (kind == 'call.ice' && candidate == null) {
        return;
      }
      if (mline != null &&
          (mline is! num || mline < 0 || mline.toInt() != mline)) {
        return;
      }
      final sdpMLineIndex = mline is num ? mline.toInt() : null;

      if (kind == 'call.offer') trace?.call('offer_parsed:${mediaKind!.name}');

      _controller.add(
        LoomCallSignal(
          callId: callId,
          conversationId: conversationId,
          senderIdentityId: senderIdentityId,
          targetIdentityId: targetIdentityId,
          kind: kind,
          sequence: sequence.toInt(),
          createdAt: createdAt,
          sdp: sdp,
          sdpType: sdpType,
          candidate: candidate,
          sdpMid: sdpMid,
          sdpMLineIndex: sdpMLineIndex,
          reason: reason,
          mediaKind: mediaKind,
        ),
      );
    } catch (_) {
      trace?.call('frame_rejected:decode');
      // Malformed signaling is ignored instead of crashing the call session.
    }
  }

  bool _supportedSignalKind(String kind) => const <String>{
    'call.offer',
    'call.ringing',
    'call.answer',
    'call.ice',
    'call.media',
    'call.reject',
    'call.busy',
    'call.end',
  }.contains(kind);

  String? _safe(Object? value, int max) {
    if (value is! String ||
        value.isEmpty ||
        value.length > max ||
        value.contains(RegExp(r'[\r\n]'))) {
      return null;
    }
    return value;
  }

  String? _optional(Object? value, int max) {
    if (value == null) {
      return null;
    }
    return _safe(value, max);
  }

  void _scheduleReconnect() {
    if (_disposed || _manualClose) {
      return;
    }
    trace?.call('socket_reconnecting');
    _socket = null;
    _reconnectTimer?.cancel();
    final index = _reconnectAttempt.clamp(0, 4).toInt();
    final seconds = <int>[1, 2, 4, 8, 10][index];
    _reconnectAttempt += 1;
    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      if (_disposed || _manualClose) {
        return;
      }
      try {
        await connect();
      } catch (error, stack) {
        if (!_disposed) {
          _controller.addError(error, stack);
        }
        // connect() already schedules the next retry on failure.
      }
    });
  }

  Uri _webSocketUri(Uri base) {
    requireLoomTransport(base);
    return base
        .resolve('/realtime/v1')
        .replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');
  }

  Future<void> close() async {
    _manualClose = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await close();
    await _controller.close();
  }
}
