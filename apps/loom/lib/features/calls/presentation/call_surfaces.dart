import '../../groups/application/group_call_controller.dart';
import 'dart:async';

import 'package:loom_calls/loom_calls.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/call_platform_bridge.dart';
import '../application/call_session_controller.dart';
import '../application/call_diagnostics.dart';
import 'active_call_screen.dart';
import 'call_error.dart';

const loomActiveCallRouteName = '/active-call';

class LoomCallRouteObserver extends NavigatorObserver {
  final ValueNotifier<bool> activeCallVisible = ValueNotifier<bool>(false);

  void _sync(Route<dynamic>? route) {
    activeCallVisible.value = route?.settings.name == loomActiveCallRouteName;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _sync(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _sync(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _sync(newRoute);
  }
}

String _peerLabel(LoomCallSessionController calls) {
  final state = calls.engine?.state;
  final peer = calls.currentPeer;
  if (peer?.displayName.trim().isNotEmpty == true) {
    return peer!.displayName;
  }
  if (peer?.address.trim().isNotEmpty == true) {
    return peer!.address;
  }
  return state?.peerIdentityId ?? 'Loom';
}

Future<void> openActiveCallRoute(BuildContext context) async {
  final calls = LoomCallSessionScope.of(context);
  await calls.open();
  final engine = calls.engine;
  if (!context.mounted) return;
  if (engine == null || engine.state.callId == null) {
    throw LoomCallUnavailableException(
      'call_unavailable',
      calls.errorMessage ?? 'The call could not connect.',
    );
  }
  // Keep terminal outcomes visible if failure/end races the route opening.
  // Otherwise the caller only sees its spinner disappear without explanation.
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: loomActiveCallRouteName),
      builder: (_) => LoomActiveCallScreen(
        engine: engine,
        peerLabel: _peerLabel(calls),
        peerAddress: calls.currentPeer?.address,
      ),
    ),
  );
}

Future<void> startConversationCallFromUi(
  BuildContext context,
  LoomConversation conversation,
  LoomCallKind kind,
) async {
  try {
    final calls = LoomCallSessionScope.of(context);
    await LoomCallPlatformBridge().requestNotificationPermission();
    if (!context.mounted) {
      return;
    }
    await calls.startConversationCall(conversation, kind);
    if (context.mounted) {
      await openActiveCallRoute(context);
    }
  } catch (error) {
    if (context.mounted) {
      _showCallError(context, error);
    }
  }
}

Future<void> startAddressCallFromUi(
  BuildContext context,
  String address,
  LoomCallKind kind,
) async {
  try {
    final calls = LoomCallSessionScope.of(context);
    await LoomCallPlatformBridge().requestNotificationPermission();
    if (!context.mounted) {
      return;
    }
    await calls.callAddress(address, kind);
    if (context.mounted) {
      await openActiveCallRoute(context);
    }
  } catch (error) {
    if (context.mounted) {
      _showCallError(context, error);
    }
  }
}

void _showCallError(BuildContext context, Object error) {
  unawaited(showCallFailure(context, error));
}

class LoomCallOverlayHost extends StatefulWidget {
  const LoomCallOverlayHost({
    required this.child,
    required this.navigatorKey,
    required this.routeObserver,
    super.key,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  final LoomCallRouteObserver routeObserver;

  @override
  State<LoomCallOverlayHost> createState() => _LoomCallOverlayHostState();
}

class _LoomCallOverlayHostState extends State<LoomCallOverlayHost> {
  final LoomCallPlatformBridge _platform = LoomCallPlatformBridge();
  final LoomAppLock _lock = LoomAppLock.instance;
  LoomCallSessionController? _calls;
  ({String callId, bool accept, DateTime expiresAt})? _queuedAction;
  bool _handlingAction = false;
  Timer? _ticker;
  bool _platformReady = false;
  String? _nativeIncomingId;
  String? _nativeIncomingLabel;
  String? _nativeOngoingId;
  bool _nativeRingback = false;
  String? _tracedIncomingId;
  bool? _tracedIncomingVisible;

  bool _nativeSyncScheduled = false;
  bool _syncingNative = false;
  bool _syncNativeAgain = false;

  @override
  void initState() {
    super.initState();
    _lock.addListener(_stateChanged);
  }

  void _stateChanged() {
    final calls = _calls;
    if (mounted && calls != null) {
      _scheduleNativeSync(calls);
    }
  }

  void _syncTicker(bool ticking) {
    if (ticking) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final calls = LoomCallSessionScope.of(context);
    if (!identical(calls, _calls)) {
      _calls?.removeListener(_stateChanged);
      _calls = calls;
      calls.addListener(_stateChanged);
      _scheduleNativeSync(calls);
    }
    if (_platformReady) {
      return;
    }
    _platformReady = true;
    unawaited(
      _platform.initialize(onAccept: _nativeAccept, onDecline: _nativeDecline),
    );
  }

  @override
  void dispose() {
    _lock.removeListener(_stateChanged);
    _calls?.removeListener(_stateChanged);
    _ticker?.cancel();
    unawaited(_platform.setRingback(false));
    if (_nativeIncomingId != null) {
      unawaited(_platform.clearIncoming(_nativeIncomingId!));
    }
    unawaited(_platform.stopOngoing());
    super.dispose();
  }

  Future<void> _nativeAccept(String callId) async {
    _queuedAction = (
      callId: callId,
      accept: true,
      expiresAt: DateTime.now().add(const Duration(seconds: 45)),
    );
    await _drainNativeAction();
  }

  Future<void> _nativeDecline(String callId) async {
    if (mounted) {
      final group = LoomGroupCallScope.maybeOf(context);
      if (group?.call?.id == callId) {
        await group!.leave();
        return;
      }
    }
    _queuedAction = (
      callId: callId,
      accept: false,
      expiresAt: DateTime.now().add(const Duration(seconds: 45)),
    );
    await _drainNativeAction();
  }

  Future<void> _drainNativeAction() async {
    final action = _queuedAction;
    final calls = _calls;
    if (action == null || calls == null || _handlingAction || !mounted) {
      return;
    }
    if (!action.expiresAt.isAfter(DateTime.now())) {
      _queuedAction = null;
      return;
    }
    // The notification can launch the Activity before startup or while the
    // vault is locked. Keep the user's action until the matching offer and
    // unlocked navigator are ready; never open media behind App Lock.
    final context = widget.navigatorKey.currentContext;
    if (_lock.locked ||
        context == null ||
        calls.incomingCall?.callId != action.callId) {
      return;
    }
    _queuedAction = null;
    _handlingAction = true;
    try {
      if (action.accept) {
        await calls.acceptIncoming();
        if (mounted) {
          unawaited(_open(calls));
        }
      } else {
        await calls.declineIncoming();
      }
    } catch (error) {
      if (context.mounted) {
        _showCallError(context, error);
      }
    } finally {
      _handlingAction = false;
    }
  }

  Future<void> _open(LoomCallSessionController calls) async {
    final navigator = widget.navigatorKey.currentState;
    final engine = calls.engine;
    if (navigator == null || engine == null || !engine.state.active) {
      return;
    }
    if (widget.routeObserver.activeCallVisible.value) {
      return;
    }
    await navigator.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: loomActiveCallRouteName),
        builder: (_) => LoomActiveCallScreen(
          engine: engine,
          peerLabel: _peerLabel(calls),
          peerAddress: calls.currentPeer?.address,
        ),
      ),
    );
  }

  void _scheduleNativeSync(LoomCallSessionController calls) {
    if (_nativeSyncScheduled) {
      return;
    }
    _nativeSyncScheduled = true;
    // Android may stop producing Flutter frames when the app is backgrounded.
    // Native ringing must follow the controller, not a future paint callback.
    scheduleMicrotask(() {
      _nativeSyncScheduled = false;
      if (mounted && identical(calls, _calls)) {
        unawaited(_syncNative(calls));
        unawaited(_drainNativeAction());
      }
    });
  }

  Future<void> _syncNative(LoomCallSessionController calls) async {
    _syncNativeAgain = true;
    if (_syncingNative) {
      return;
    }
    _syncingNative = true;
    try {
      do {
        _syncNativeAgain = false;
        await _syncNativeState(calls);
      } while (mounted && _syncNativeAgain);
    } finally {
      _syncingNative = false;
    }
  }

  Future<void> _syncNativeState(LoomCallSessionController calls) async {
    final pending = calls.incomingCall;
    final peer = calls.incomingPeer;
    final callerName = _lock.locked
        ? 'Loom'
        : peer?.displayName.trim().isNotEmpty == true
        ? peer!.displayName
        : peer?.address ?? pending?.callerIdentityId ?? 'Loom';
    final callerAddress = _lock.locked
        ? ''
        : peer?.address ?? pending?.callerIdentityId ?? '';
    final label = '$callerName\n$callerAddress';
    if (pending != null &&
        (pending.callId != _nativeIncomingId ||
            label != _nativeIncomingLabel)) {
      final newlyRinging = pending.callId != _nativeIncomingId;
      if (_nativeIncomingId != null && newlyRinging) {
        await _platform.clearIncoming(_nativeIncomingId!);
      }
      _nativeIncomingId = pending.callId;
      _nativeIncomingLabel = label;
      if (newlyRinging &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          !_lock.locked) {
        await _platform.requestNotificationPermission();
      }
      if (!mounted || calls.incomingCall?.callId != pending.callId) {
        await _platform.clearIncoming(pending.callId);
        _nativeIncomingId = null;
        _syncNativeAgain = mounted;
        return;
      }
      await _platform.showIncoming(
        callId: pending.callId,
        callerName: callerName,
        callerAddress: callerAddress,
        video: pending.kind == LoomCallKind.video,
        expiresAt: pending.expiresAt,
      );
    } else if (pending == null && _nativeIncomingId != null) {
      await _platform.clearIncoming(_nativeIncomingId!);
      _nativeIncomingId = null;
      _nativeIncomingLabel = null;
    }

    final state = calls.engine?.state;
    final ringback =
        state?.direction == LoomCallDirection.outgoing &&
        state?.lifecycle == LoomCallLifecycle.ringing;
    if (ringback != _nativeRingback) {
      _nativeRingback = ringback;
      await _platform.setRingback(ringback);
    }
    // The engine becomes "active" before getUserMedia has completed. Starting
    // an Android microphone/camera foreground service during that preparing
    // window can crash the process on modern Android because the runtime media
    // permission is not granted yet. Ringing/connecting only happen after
    // local media preparation succeeded, so start the native service then.
    final mediaReady =
        state?.active == true &&
        state!.lifecycle != LoomCallLifecycle.preparing;
    final activeId = mediaReady ? state.callId : null;
    if (activeId != null && activeId != _nativeOngoingId) {
      _nativeOngoingId = activeId;
      await _platform.startOngoing(
        callId: activeId,
        peerName: _peerLabel(calls),
        video: state!.kind == LoomCallKind.video,
      );
    } else if (activeId == null && _nativeOngoingId != null) {
      await _platform.stopOngoing();
      _nativeOngoingId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final calls = LoomCallSessionScope.of(context);
    _scheduleNativeSync(calls);
    // MaterialApp.builder places this host above the Navigator. The incoming
    // and mini-call surfaces are siblings of its Overlay, so their tooltips
    // need an app-level Overlay of their own (also while App Lock unmounts the
    // Navigator). Putting the host inside a route hides this production bug.
    return Overlay.wrap(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          widget.routeObserver.activeCallVisible,
          _lock,
        ]),
        builder: (context, _) {
          _scheduleNativeSync(calls);
          final canShowCall = !_lock.locked;
          final pending = calls.incomingCall;
          if (pending != null &&
              (_tracedIncomingId != pending.callId ||
                  _tracedIncomingVisible != canShowCall)) {
            _tracedIncomingId = pending.callId;
            _tracedIncomingVisible = canShowCall;
            traceLoomCall(
              canShowCall
                  ? 'incoming_surface_build:${pending.kind.name}'
                  : 'incoming_surface_hidden:locked',
            );
          } else if (pending == null) {
            _tracedIncomingId = null;
            _tracedIncomingVisible = null;
          }
          final state = calls.engine?.state;
          final showMini =
              canShowCall &&
              state?.active == true &&
              calls.incomingCall == null &&
              !widget.routeObserver.activeCallVisible.value;
          _syncTicker(showMini && state?.answeredAt != null);
          return Stack(
            children: [
              ExcludeFocus(
                excluding: canShowCall && calls.incomingCall != null,
                child: widget.child,
              ),
              if (showMini)
                PositionedDirectional(
                  top: MediaQuery.paddingOf(context).top + 8,
                  start: 12,
                  end: 12,
                  child: LoomReveal(
                    offset: -12,
                    child: _MiniCallBar(
                      calls: calls,
                      onTap: () => unawaited(_open(calls)),
                    ),
                  ),
                ),
              if (canShowCall && calls.incomingCall != null)
                Positioned.fill(
                  child: BlockSemantics(
                    child: FocusScope(
                      autofocus: true,
                      child: _IncomingCallSurface(
                        calls: calls,
                        onAccept: () async {
                          await calls.acceptIncoming();
                          if (mounted) {
                            await _open(calls);
                          }
                        },
                        onDecline: calls.declineIncoming,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MiniCallBar extends StatelessWidget {
  const _MiniCallBar({required this.calls, required this.onTap});
  final LoomCallSessionController calls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final state = calls.engine!.state;
    return Material(
      color: Colors.transparent,
      child: LoomGlassSurface(
        strength: LoomGlassStrength.strong,
        radius: LoomRadii.control,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              LoomAvatar(label: _peerLabel(calls), size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _peerLabel(calls),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _stateOrDuration(context, state),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.loom.connectivity,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                state.kind == LoomCallKind.video
                    ? LoomIcons.videocam_rounded
                    : LoomIcons.call_rounded,
                color: context.loom.connectivity,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IncomingCallSurface extends StatefulWidget {
  const _IncomingCallSurface({
    required this.calls,
    required this.onAccept,
    required this.onDecline,
  });
  final LoomCallSessionController calls;
  final Future<void> Function() onAccept;
  final Future<void> Function() onDecline;
  @override
  State<_IncomingCallSurface> createState() => _IncomingCallSurfaceState();
}

class _IncomingCallSurfaceState extends State<_IncomingCallSurface> {
  bool _busy = false;
  Future<void> _respond(bool accept) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await (accept ? widget.onAccept() : widget.onDecline());
    } catch (error) {
      if (mounted) {
        _showCallError(context, error);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.calls.incomingCall!;
    final peer = widget.calls.incomingPeer;
    final name = peer?.displayName.trim().isNotEmpty == true
        ? peer!.displayName
        : peer?.address ?? pending.callerIdentityId;
    return Material(
      color: Colors.black.withAlphaFraction(.58),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: LoomReveal(
                child: LoomGlassSurface(
                  strength: LoomGlassStrength.strong,
                  radius: LoomRadii.sheet,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LoomConnectionPulse(
                        active: !_busy,
                        size: 124,
                        child: LoomAvatar(label: name, size: 90),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      if (peer?.address.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(
                          peer!.address,
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 10),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          pending.kind == LoomCallKind.video
                              ? tr(
                                  context,
                                  'Incoming video call',
                                  'تماس ویدیویی ورودی',
                                )
                              : tr(
                                  context,
                                  'Incoming audio call',
                                  'تماس صوتی ورودی',
                                ),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(color: context.loom.connectivity),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          Expanded(
                            child: _IncomingButton(
                              label: tr(context, 'Decline', 'رد تماس'),
                              icon: LoomIcons.call_end_rounded,
                              destructive: true,
                              onTap: _busy ? null : () => _respond(false),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _IncomingButton(
                              label: tr(context, 'Accept', 'پذیرش'),
                              icon: pending.kind == LoomCallKind.video
                                  ? LoomIcons.videocam_rounded
                                  : LoomIcons.call_rounded,
                              onTap: _busy ? null : () => _respond(true),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IncomingButton extends StatelessWidget {
  const _IncomingButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      LoomPressable(
        enabled: onTap != null,
        child: IconButton.filled(
          onPressed: onTap,
          tooltip: label,
          icon: Icon(icon),
          iconSize: 28,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(64),
            backgroundColor: destructive
                ? const Color(0xFFBB3342)
                : const Color(0xFF087E63),
            foregroundColor: Colors.white,
          ),
        ),
      ),
      const SizedBox(height: 8),
      ExcludeSemantics(child: Text(label, textAlign: TextAlign.center)),
    ],
  );
}

String _stateOrDuration(BuildContext context, LoomCallSnapshot state) {
  final answered = state.answeredAt;
  if (answered != null &&
      (state.lifecycle == LoomCallLifecycle.connected ||
          state.lifecycle == LoomCallLifecycle.reconnecting)) {
    final duration = DateTime.now().toUtc().difference(answered);
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
  return switch (state.lifecycle) {
    LoomCallLifecycle.preparing => tr(
      context,
      'Preparing…',
      'در حال آماده‌سازی…',
    ),
    LoomCallLifecycle.ringing when !state.remoteRinging => tr(
      context,
      'Calling…',
      'در حال تماس…',
    ),
    LoomCallLifecycle.ringing => tr(context, 'Ringing…', 'در حال زنگ خوردن…'),
    LoomCallLifecycle.connecting => tr(context, 'Connecting…', 'در حال اتصال…'),
    LoomCallLifecycle.reconnecting => tr(
      context,
      'Reconnecting…',
      'اتصال مجدد…',
    ),
    LoomCallLifecycle.connected => tr(context, 'Connected', 'متصل'),
    _ => tr(context, 'Call', 'تماس'),
  };
}
