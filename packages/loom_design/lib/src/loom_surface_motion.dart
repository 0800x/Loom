import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'loom_accessibility.dart';
import 'loom_theme.dart';

/// Geometry is captured before focus changes or the source is hidden.
abstract final class LoomOrigin {
  static Rect? of(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return rect.isFinite && !rect.isEmpty ? rect : null;
  }
}

/// A critically damped spring, normalized to land exactly at the endpoint.
class LoomSpringCurve extends Curve {
  const LoomSpringCurve();
  @override
  double transformInternal(double t) {
    double spring(double x) => 1 - (1 + 8 * x) * math.exp(-8 * x);
    return (spring(t) / spring(1)).clamp(0.0, 1.0);
  }
}

/// One surface changes geometry, rather than swapping two faded widgets.
/// The destination keeps its layout throughout the transition; animation ticks
/// update only its transform and clip, not its contents.
class LoomContainerTransform extends StatelessWidget {
  const LoomContainerTransform({
    required this.animation,
    required this.origin,
    required this.destination,
    required this.child,
    this.radius = 28,
    this.sourceRadius = 24,
    this.linear = false,
    this.curvedStretch = false,
    super.key,
  });
  final Animation<double> animation;
  final Rect origin, destination;
  final Widget child;
  final double radius, sourceRadius;
  final bool linear;

  /// Gentle, continuous edge curvature for large expanding surfaces.
  /// Small menus keep the simpler rounded container transform.
  final bool curvedStretch;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: RepaintBoundary(child: child),
    builder: (context, child) {
      final reduced = LoomAccessibility.fromContext(context).reduceMotion;
      final t = reduced
          ? 1.0
          : linear
          ? animation.value
          : const LoomSpringCurve().transform(animation.value);
      final rect = Rect.lerp(origin, destination, t)!;
      final sx = rect.width / destination.width;
      final sy = rect.height / destination.height;
      return Positioned.fromRect(
        rect: destination,
        child: Transform(
          alignment: Alignment.topLeft,
          transform: Matrix4.identity()
            ..translateByDouble(
              rect.left - destination.left,
              rect.top - destination.top,
              0,
              1,
            )
            ..scaleByDouble(sx, sy, 1, 1),
          child: ClipPath(
            clipper: LoomSurfaceClipper(
              progress: t,
              curvedStretch: curvedStretch,
              radius: Radius.elliptical(
                (sourceRadius + (radius - sourceRadius) * t) /
                    math.max(sx, .001),
                (sourceRadius + (radius - sourceRadius) * t) /
                    math.max(sy, .001),
              ),
            ),
            child: child,
          ),
        ),
      );
    },
  );
}

/// Keeps the cached child intact while the outline stretches and settles.
/// This is curved clipping, not a per-pixel macOS window warp.
class LoomSurfaceClipper extends CustomClipper<Path> {
  const LoomSurfaceClipper({
    required this.progress,
    required this.radius,
    this.curvedStretch = false,
  });
  final double progress;
  final Radius radius;
  final bool curvedStretch;

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    if (!curvedStretch || progress <= 0 || progress >= 1) {
      return Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
    }
    final rx = math.min(radius.x, size.width / 2);
    final ry = math.min(radius.y, size.height / 2);
    final bow = size.width * .075 * math.sin(math.pi * progress);
    return Path()
      ..moveTo(rx, 0)
      ..lineTo(size.width - rx, 0)
      ..quadraticBezierTo(size.width, 0, size.width, ry)
      ..quadraticBezierTo(
        size.width - 2 * bow,
        size.height / 2,
        size.width,
        size.height - ry,
      )
      ..quadraticBezierTo(size.width, size.height, size.width - rx, size.height)
      ..lineTo(rx, size.height)
      ..quadraticBezierTo(0, size.height, 0, size.height - ry)
      ..quadraticBezierTo(2 * bow, size.height / 2, 0, ry)
      ..quadraticBezierTo(0, 0, rx, 0)
      ..close();
  }

  @override
  bool shouldReclip(LoomSurfaceClipper oldClipper) =>
      progress != oldClipper.progress ||
      radius != oldClipper.radius ||
      curvedStretch != oldClipper.curvedStretch;
}

/// A grabber that reads as a control rather than a line: a translucent
/// capsule well cradles the pill, and on fullscreen surfaces it performs a
/// single downward nudge when it first appears to teach the pull gesture.
class LoomGrabHandle extends StatefulWidget {
  const LoomGrabHandle({super.key, this.hint = false, this.dragging = false});

  /// Play the pull-down teaching nudge once when mounted.
  final bool hint;

  /// Visually engaged while the user is dragging the surface.
  final bool dragging;
  @override
  State<LoomGrabHandle> createState() => _LoomGrabHandleState();
}

class _LoomGrabHandleState extends State<LoomGrabHandle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _nudge = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..value = 1;

  @override
  void initState() {
    super.initState();
    if (!widget.hint) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (LoomAccessibility.fromContext(context).reduceMotion) return;
      _nudge.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _nudge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final pill = onSurface.withValues(alpha: widget.dragging ? .62 : .38);
    return AnimatedBuilder(
      animation: _nudge,
      builder: (context, child) {
        final t = _nudge.value;
        final dy = math.sin(math.pi * t) * 5;
        return Transform.translate(
          offset: Offset(0, dy),
          child: child,
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
        decoration: BoxDecoration(
          color: onSurface.withValues(alpha: widget.dragging ? .14 : .09),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: onSurface.withValues(alpha: widget.dragging ? .16 : .10),
          ),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: widget.dragging ? 42 : 36,
          height: 5,
          decoration: BoxDecoration(
            color: pill,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

/// Pull-to-dismiss for plain routes (call screens): a grabber rides above the
/// status bar, dragging it follows the finger with rubber-band resistance and
/// a fling (or crossing the threshold) minimizes the screen.
class LoomPullToDismiss extends StatefulWidget {
  const LoomPullToDismiss({
    required this.child,
    required this.onDismiss,
    this.grabberOffset = 4,
    this.dismissVelocity = 900,
    super.key,
  });

  /// Extra distance below the status bar where the grabber floats.
  final double grabberOffset;
  final Widget child;
  final VoidCallback onDismiss;
  final double dismissVelocity;

  @override
  State<LoomPullToDismiss> createState() => _LoomPullToDismissState();
}

class _LoomPullToDismissState extends State<LoomPullToDismiss>
    with SingleTickerProviderStateMixin {
  final _offset = ValueNotifier(0.0);
  double _springFrom = 0;
  double _raw = 0;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  )..addListener(() {
    _offset.value = _springFrom *
        (1 - Curves.easeOutCubic.transform(_settle.value));
  });

  @override
  void dispose() {
    _settle.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _start(DragStartDetails _) {
    _settle.stop();
    _raw = 0;
  }

  void _update(DragUpdateDetails details) {
    _raw = math.max(0, _raw + details.delta.dy);
    // Rubber band: the further down, the harder it resists.
    _offset.value = 130 * (1 - math.exp(-_raw / 160));
  }

  void _end(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_raw > 120 || velocity > widget.dismissVelocity) {
      _raw = 0;
      _offset.value = 0;
      widget.onDismiss();
      return;
    }
    _springFrom = _offset.value;
    if (_springFrom <= 0) return;
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top + widget.grabberOffset;
    return Stack(
      children: [
        ValueListenableBuilder<double>(
          valueListenable: _offset,
          builder: (context, dy, child) =>
              Transform.translate(offset: Offset(0, dy), child: child),
          child: widget.child,
        ),
        Padding(
          padding: EdgeInsets.only(top: topInset),
          child: Align(
            alignment: AlignmentDirectional.topCenter,
            child: SizedBox(
              width: 150,
              height: 46,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _start,
                onVerticalDragUpdate: _update,
                onVerticalDragEnd: _end,
                onVerticalDragCancel: () {
                  _springFrom = _offset.value;
                  if (_springFrom > 0) _settle.forward(from: 0);
                },
                child: Center(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _offset,
                    builder: (context, dy, _) =>
                        LoomGrabHandle(dragging: dy > 0.5, hint: true),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Popup lifetime, barrier, keyboard focus, back handling and reverse animation
/// belong to Navigator. A header drag can interrupt and reverse the same clock.
class LoomSurfaceRoute<T> extends PopupRoute<T> {
  LoomSurfaceRoute({
    required this.builder,
    required this.origin,
    required this.barrierLabel,
    this.fullscreen = false,
    this.reducedMotion = false,
    this.backgroundColor = const Color(0xffFFFFFF),
    Color? barrierColor,
    super.settings,
  }) : _barrierColor = barrierColor;
  final WidgetBuilder builder;
  final Rect? origin;
  final bool fullscreen, reducedMotion;
  final Color backgroundColor;
  final Color? _barrierColor;
  @override
  final String barrierLabel;
  @override
  bool get barrierDismissible => true;
  @override
  Color get barrierColor => _barrierColor ?? const Color(0x66000000);
  @override
  Duration get transitionDuration =>
      reducedMotion ? Duration.zero : const Duration(milliseconds: 280);
  @override
  Duration get reverseTransitionDuration =>
      reducedMotion ? Duration.zero : const Duration(milliseconds: 180);
  double _dragStart = 1;
  final _interactive = ValueNotifier(false);
  void _start(DragStartDetails _) {
    if (!isCurrent ||
        reducedMotion ||
        controller == null ||
        animation?.status == AnimationStatus.reverse) {
      return;
    }
    _drag = 0;
    controller!.stop();
    // Preserve the current geometry when interrupting an opening spring.
    if (!_interactive.value) {
      controller!.value = const LoomSpringCurve().transform(controller!.value);
      _interactive.value = true;
    }
    _dragStart = controller!.value;
  }

  double _drag = 0;
  void _update(DragUpdateDetails details) {
    if (!isCurrent || reducedMotion || !_interactive.value) return;
    _drag += details.delta.dy;
    controller?.value = (_dragStart - _drag / 400).clamp(0.0, 1.0);
  }

  void _end(DragEndDetails details) {
    _drag = 0;
    if (!isCurrent || !_interactive.value) return;
    if ((controller?.value ?? 1) < .72 ||
        details.velocity.pixelsPerSecond.dy > 850) {
      navigator?.pop();
    } else {
      _settle();
    }
  }

  void _settle() {
    controller?.forward().whenCompleteOrCancel(() {
      if (controller?.value == 1) _interactive.value = false;
    });
  }

  @override
  void dispose() {
    _interactive.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return LayoutBuilder(
      builder: (context, bounds) {
        final media = MediaQuery.of(context);
        final viewport = Size(bounds.maxWidth, bounds.maxHeight);
        final available = Rect.fromLTRB(
          8,
          media.padding.top + 8,
          viewport.width - 8,
          viewport.height - media.viewInsets.bottom - media.padding.bottom - 8,
        );
        final width = math.min(600.0, available.width);
        final height = math.max(
          1.0,
          math.min(available.height, viewport.height * .82),
        );
        final destination = fullscreen
            ? Offset.zero & viewport
            : Rect.fromLTWH(
                available.center.dx - width / 2,
                available.bottom - height,
                width,
                height,
              );
        final overlayBox = Navigator.of(context).overlay?.context
            .findRenderObject();
        final source = origin == null
            ? Rect.fromCenter(
                center: destination.bottomCenter,
                width: 48,
                height: 48,
              )
            : overlayBox is RenderBox
            ? overlayBox.globalToLocal(origin!.topLeft) & origin!.size
            : origin!;
        return Stack(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: _interactive,
              builder: (context, interactive, child) => LoomContainerTransform(
                animation: animation,
                origin: source,
                destination: destination,
                radius: fullscreen ? 0 : 28,
                linear: interactive,
                curvedStretch: fullscreen,
                child: child!,
              ),
              child: Material(
                color: backgroundColor,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Column(
                      children: [
                        if (!fullscreen)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragStart: _start,
                            onVerticalDragUpdate: _update,
                            onVerticalDragEnd: _end,
                            onVerticalDragCancel: () {
                              _drag = 0;
                              if (_interactive.value) _settle();
                            },
                            child: SizedBox(
                              height: 34,
                              width: double.infinity,
                              child: Center(
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: _interactive,
                                  builder: (context, interactive, _) =>
                                      LoomGrabHandle(dragging: interactive),
                                ),
                              ),
                            ),
                          ),
                        Expanded(child: builder(context)),
                      ],
                    ),
                    if (fullscreen)
                      Positioned(
                        top: media.padding.top + 2,
                        left: viewport.width / 2 - 90,
                        width: 180,
                        height: 46,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragStart: _start,
                          onVerticalDragUpdate: _update,
                          onVerticalDragEnd: _end,
                          onVerticalDragCancel: () {
                            if (_interactive.value) _settle();
                          },
                          child: Center(
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _interactive,
                              builder: (context, interactive, _) => LoomGrabHandle(
                                hint: true,
                                dragging: interactive,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Keep the guard through reverse-route disposal, not just the pop result.
final _surfaces = <NavigatorState, Set<Object>>{};
Future<T?> showLoomSurface<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Rect? origin,
  Object? identity,
  bool fullscreen = false,
}) async {
  final navigator = Navigator.of(context);
  final key = identity ?? builder;
  final active = _surfaces.putIfAbsent(navigator, () => {});
  if (!active.add(key)) return null;
  final focus = FocusManager.instance.primaryFocus;
  final access = LoomAccessibility.fromContext(context);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final palette = Theme.of(context).extension<LoomPalette>();
  final route = LoomSurfaceRoute<T>(
    origin: origin,
    reducedMotion: access.reduceMotion,
    fullscreen: fullscreen,
    backgroundColor: Theme.of(context).colorScheme.surface,
    barrierColor: palette?.scrim ?? Theme.of(context).colorScheme.scrim,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    builder: (context) => themes.wrap(builder(context)),
  );
  focus?.unfocus();
  try {
    final value = await navigator.push(route);
    await route.completed;
    return value;
  } finally {
    active.remove(key);
    if (active.isEmpty) _surfaces.remove(navigator);
    if (focus?.context?.mounted == true && focus!.canRequestFocus) {
      focus.requestFocus();
    }
  }
}
