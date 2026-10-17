import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:loom_design/loom_design.dart';

/// Sensor ticks repaint only the wallpaper layer, never the message list.
class LoomWallpaperParallax extends StatefulWidget {
  const LoomWallpaperParallax({
    required this.enabled,
    required this.child,
    super.key,
  });
  final bool enabled;
  final Widget child;
  @override
  State<LoomWallpaperParallax> createState() => _ParallaxState();
}

class _ParallaxState extends State<LoomWallpaperParallax>
    with WidgetsBindingObserver {
  static const _channel = EventChannel('loom/wallpaper_motion');
  static final _events = _channel.receiveBroadcastStream();
  final _offset = ValueNotifier<Offset>(Offset.zero);
  StreamSubscription<dynamic>? _subscription;
  bool _resumed = true;
  bool _allowed = false;
  bool _unavailable = false;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant LoomWallpaperParallax old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final access = LoomAccessibility.fromContext(context);
    _allowed =
        widget.enabled &&
        Platform.isAndroid &&
        _resumed &&
        TickerMode.valuesOf(context).enabled &&
        !access.reduceMotion &&
        !access.highContrast &&
        !_unavailable;
    if (!_allowed) {
      _stop();
      return;
    }
    if (_subscription != null) return;
    final epoch = ++_epoch;
    _subscription = _events.listen(
      (data) {
        if (!mounted ||
            !_allowed ||
            epoch != _epoch ||
            data is! List ||
            data.length != 2 ||
            data.any((v) => v is! num || !v.isFinite)) {
          return;
        }
        final target =
            Offset(
              (data[0] as num).toDouble().clamp(-1.0, 1.0),
              (data[1] as num).toDouble().clamp(-1.0, 1.0),
            ) *
            14;
        final next = Offset.lerp(_offset.value, target, .18)!;
        if ((next - _offset.value).distance > .1) _offset.value = next;
      },
      onError: (Object _) {
        _unavailable = true;
        _stop();
      },
      onDone: () {
        _unavailable = true;
        _stop();
      },
    );
  }

  void _stop() {
    ++_epoch;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _offset.value = Offset.zero;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: ValueListenableBuilder<Offset>(
      valueListenable: _offset,
      child: RepaintBoundary(child: widget.child),
      builder: (_, offset, child) => Transform.translate(
        offset: offset,
        child: Transform.scale(scale: _allowed ? 1.12 : 1, child: child),
      ),
    ),
  );
}
