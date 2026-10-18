import 'dart:async';

import 'package:flutter/widgets.dart';

/// Keeps the durable account cursor moving while the app is active.
///
/// Loom's REST sync remains authoritative even when the optional realtime
/// transport is unavailable. This heartbeat is intentionally app-lifecycle
/// aware and non-overlapping, so delivery receipts and inbound messages are
/// eventually applied without requiring a manual refresh.
class LoomMessagingSyncHeartbeat extends StatefulWidget {
  const LoomMessagingSyncHeartbeat({
    required this.child,
    required this.shouldSync,
    required this.synchronize,
    this.interval = const Duration(seconds: 5),
    super.key,
  });

  final Widget child;
  final bool Function() shouldSync;
  final Future<void> Function() synchronize;
  final Duration interval;

  @override
  State<LoomMessagingSyncHeartbeat> createState() =>
      _LoomMessagingSyncHeartbeatState();
}

class _LoomMessagingSyncHeartbeatState extends State<LoomMessagingSyncHeartbeat>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _running = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant LoomMessagingSyncHeartbeat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interval != widget.interval) _restartTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      unawaited(_tick());
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.interval <= Duration.zero) return;
    _timer = Timer.periodic(widget.interval, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (!mounted ||
        _running ||
        _lifecycleState != AppLifecycleState.resumed ||
        !widget.shouldSync()) {
      return;
    }
    _running = true;
    try {
      await widget.synchronize();
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
