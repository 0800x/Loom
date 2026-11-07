import 'dart:async';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../messaging/application/messaging_session_controller.dart';

/// Session-local deduplication. Loading older history never rings as new mail.
class LoomMessageNotificationPolicy {
  LoomMessageNotificationPolicy({DateTime? startedAt})
    : startedAt = startedAt ?? DateTime.now().toUtc();
  final DateTime startedAt;
  final _seen = <String>{};

  bool shouldNotify(
    LoomMessageRecord message, {
    required String ownAddress,
    required bool muted,
    required bool visible,
  }) {
    final key = '${message.conversationId}:${message.clientId}';
    if (!_seen.add(key)) return false;
    while (_seen.length > 4096) {
      _seen.remove(_seen.first);
    }
    return message.createdAt.isAfter(startedAt) &&
        message.senderAddress.toLowerCase() != ownAddress.toLowerCase() &&
        message.deliveryState != LoomDeliveryState.read &&
        !muted &&
        !visible;
  }
}

class LoomMessageNotificationBridge {
  static const channel = MethodChannel('loom/notifications');
  Future<void> initialize(
    void Function(String) onOpen, {
    void Function(bool granted)? onPermissionResult,
    void Function(String conversationId, String text)? onQuickReply,
  }) async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openInbox') onOpen('');
      if (call.method == 'openConversation' && call.arguments is String) {
        onOpen(call.arguments as String);
      }
      if (call.method == 'permissionResult') {
        onPermissionResult?.call(call.arguments == true);
      }
      if (call.method == 'quickReply' && call.arguments is Map) {
        final args = call.arguments as Map;
        final conversationId = args['conversationId'];
        final text = args['text'];
        if (conversationId is String && text is String) {
          onQuickReply?.call(conversationId, text);
        }
      }
    });
    try {
      final pending = await channel.invokeMethod<String>('prepare');
      if (pending != null && pending.isNotEmpty) onOpen(pending);
    } on MissingPluginException {
      /* Unsupported platform. */
    }
  }

  Future<void> show(String conversationId, String title) async {
    try {
      await channel.invokeMethod<void>('showMessage', {
        'conversationId': conversationId, 'title': title,
        // Never pass message plaintext, attachments or key material to the OS.
        'body': 'New encrypted message',
      });
    } on MissingPluginException {
      /* Unsupported platform. */
    } on PlatformException {
      /* OS notification policy remains authoritative. */
    }
  }

  Future<void> clear(String conversationId) async {
    try {
      await channel.invokeMethod<void>('clearMessage', conversationId);
    } on MissingPluginException {
      /* Unsupported platform. */
    } on PlatformException {
      /* Best effort. */
    }
  }

  Future<void> enable() => channel.invokeMethod<void>('enable');
  Future<void> settings() => channel.invokeMethod<void>('openSettings');
  Future<Map<String, Object?>> status() async =>
      await channel.invokeMapMethod<String, Object?>('status') ?? const {};

  // ── Background connection (Android foreground service) ─────────────────
  // An opt-in keep-alive so the realtime message socket survives the app
  // being swiped away. Not push: nothing arrives if the process is killed
  // by the OS or the device restarts.
  Future<void> startStayConnected() async {
    try {
      await channel.invokeMethod<void>('startMessagingService');
    } on MissingPluginException {
      /* Unsupported platform. */
    } on PlatformException {
      /* OEM restrictions stay authoritative. */
    }
  }

  Future<void> stopStayConnected() async {
    try {
      await channel.invokeMethod<void>('stopMessagingService');
    } on MissingPluginException {
      /* Unsupported platform. */
    } on PlatformException {
      /* Best effort. */
    }
  }

  Future<bool> stayConnectedRunning() async {
    try {
      return await channel.invokeMethod<bool>('messagingServiceRunning') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

class LoomMessageNotifications with WidgetsBindingObserver {
  LoomMessageNotifications({
    required this.messaging,
    required this.onOpen,
    LoomMessageNotificationBridge? bridge,
    LoomMessageNotificationPolicy? policy,
    void Function(bool granted)? onPermissionResult,
    void Function(String conversationId, String text)? onQuickReply,
  }) : bridge = bridge ?? LoomMessageNotificationBridge(),
       policy = policy ?? LoomMessageNotificationPolicy() {
    WidgetsBinding.instance.addObserver(this);
    messaging.addListener(_changed);
    unawaited(
      this.bridge
          .initialize(
            onOpen,
            onPermissionResult: onPermissionResult,
            onQuickReply: onQuickReply,
          )
          .catchError((Object _) {}),
    );
  }
  final LoomMessagingSessionController messaging;
  final void Function(String) onOpen;
  final LoomMessageNotificationBridge bridge;
  final LoomMessageNotificationPolicy policy;
  bool _disposed = false;
  bool _permissionNudged = false;
  AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _lifecycle = state;
  void _changed() {
    if (_disposed) return;
    final own = messaging.onboarding.receipt?.address;
    if (own == null) return;
    // Ask for the OS notification permission once, right after sign-in, so
    // message notifications actually have a channel to arrive on. The OS
    // dialog only ever appears once per install; later refusals route the
    // user to system settings via the Notifications pane.
    if (!_permissionNudged) {
      _permissionNudged = true;
      unawaited(_nudgePermission());
    }
    for (final conversation in messaging.conversations) {
      final visible =
          !LoomAppLock.instance.locked &&
          _lifecycle == AppLifecycleState.resumed &&
          messaging.activeConversationId == conversation.id;
      if (visible || conversation.unreadCount == 0) {
        unawaited(bridge.clear(conversation.id));
      }
      var notify = false;
      for (final message in messaging.visibleMessagesFor(conversation.id)) {
        if (policy.shouldNotify(
          message.record,
          ownAddress: own,
          muted: conversation.isMuted,
          visible: visible,
        )) {
          notify = true;
        }
      }
      if (notify) {
        unawaited(
          bridge.show(
            conversation.id,
            LoomAppLock.instance.locked ? 'Loom' : conversation.title ?? 'Loom',
          ),
        );
      }
    }
  }

  /// Re-queries the OS state after the permission dialog resolves so the
  /// settings switch reflects reality instead of an optimistic assumption.
  Future<Map<String, Object?>> refreshStatus() => bridge.status();

  Future<void> _nudgePermission() async {
    try {
      final status = await bridge.status();
      if (status['enabled'] == true) return;
      await bridge.enable();
    } catch (_) {
      _permissionNudged = false;
    }
  }

  void dispose() {
    _disposed = true;
    messaging.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
  }
}
