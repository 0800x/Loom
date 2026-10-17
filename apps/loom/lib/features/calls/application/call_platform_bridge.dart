import 'package:flutter/services.dart';

/// Small platform boundary for call notifications / foreground call lifetime.
///
/// Android implements incoming/ongoing call notifications and actions. Windows
/// implements native taskbar attention while the process is alive. Other
/// platforms may leave the channel unimplemented; the Dart WebRTC engine stays
/// functional while platform-specific background UX remains capability-gated.
class LoomCallPlatformBridge {
  static const MethodChannel _channel = MethodChannel('loom/calls');

  bool _initialized = false;
  Future<void> Function(String callId)? _onAccept;
  Future<void> Function(String callId)? _onDecline;

  Future<void> initialize({
    required Future<void> Function(String callId) onAccept,
    required Future<void> Function(String callId) onDecline,
  }) async {
    _onAccept = onAccept;
    _onDecline = onDecline;
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'callAction') {
        return;
      }
      await _handleAction(call.arguments);
    });
    try {
      // Native stores a launch action until Dart registers this handler.
      final pending = await _channel.invokeMapMethod<String, Object?>(
        'prepare',
      );
      await _handleAction(pending);
    } on MissingPluginException {
      // No native notification surface on this platform.
    } on PlatformException {
      // WebRTC and the in-app surface remain usable.
    }
  }

  Future<void> _handleAction(Object? args) async {
    if (args is! Map) {
      return;
    }
    final action = args['action'];
    final callId = args['callId'];
    if (action is! String || callId is! String || callId.isEmpty) {
      return;
    }
    if (action == 'accept') {
      await _onAccept?.call(callId);
    } else if (action == 'decline') {
      await _onDecline?.call(callId);
    }
  }

  Future<void> showIncoming({
    required String callId,
    required String callerName,
    required String callerAddress,
    required bool video,
    required DateTime expiresAt,
  }) => _invoke('showIncoming', <String, Object?>{
    'callId': callId,
    'callerName': callerName,
    'callerAddress': callerAddress,
    'video': video,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
  });

  Future<void> clearIncoming(String callId) =>
      _invoke('clearIncoming', <String, Object?>{'callId': callId});

  Future<void> startOngoing({
    required String callId,
    required String peerName,
    required bool video,
    bool microphoneActive = true,
    bool? cameraActive,
  }) async {
    // Ask only once the user is actually using calling; do not request this
    // notification permission at app install/startup for unrelated workflows.
    await requestNotificationPermission();
    await _invoke('startOngoing', <String, Object?>{
      'callId': callId,
      'peerName': peerName,
      'video': video,
      'microphoneActive': microphoneActive,
      'cameraActive': cameraActive ?? video,
    });
  }

  Future<void> stopOngoing() => _invoke('stopOngoing');

  /// Idempotent native ringback, stopped before media connects or on teardown.
  Future<void> setRingback(bool playing) =>
      _invoke('setRingback', <String, Object?>{'playing': playing});

  Future<void> requestNotificationPermission() =>
      _invoke('requestNotificationPermission');

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Platform integration is optional outside platforms with an
      // implementation. Do not break a live WebRTC call because a native
      // notification surface is unavailable.
    } on PlatformException {
      // Native call UX is best effort and must not tear down WebRTC media.
    }
  }
}

/// Opens Android's existing incoming-call notification channel controls.
class LoomCallPlatformSettings {
  const LoomCallPlatformSettings();
  static const _channel = MethodChannel('loom/calls');

  Future<void> openIncomingSettings() async {
    try {
      await _channel.invokeMethod<void>('openIncomingSettings');
    } on MissingPluginException {
      // Other platforms expose their own notification settings.
    } on PlatformException {
      // System settings may be unavailable on managed devices.
    }
  }
}
