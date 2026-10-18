import 'package:flutter/material.dart';

import 'loom_accessibility.dart';
import 'loom_icons.dart';
import 'loom_theme.dart';
import 'loom_tokens.dart';

/// Adds tactile feedback without replacing a button's gestures or semantics.
class LoomPressable extends StatefulWidget {
  const LoomPressable({required this.child, this.enabled = true, super.key});
  final Widget child;
  final bool enabled;

  @override
  State<LoomPressable> createState() => _LoomPressableState();
}

class _LoomPressableState extends State<LoomPressable> {
  bool _pressed = false;

  void _press(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: widget.enabled ? (_) => _press(true) : null,
        onPointerUp: (_) => _press(false),
        onPointerCancel: (_) => _press(false),
        child: AnimatedScale(
          scale: widget.enabled &&
                  _pressed &&
                  !LoomAccessibility.fromContext(context).reduceMotion
              ? .97
              : 1,
          duration: LoomAccessibility.fromContext(context).reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 90),
          curve: LoomMotion.standard,
          child: widget.child,
        ),
      );
}

/// A one-time entry transition. Rebuilding an existing keyed item does not
/// replay it. Keep long lists unanimated; use this for newly inserted content.
class LoomReveal extends StatelessWidget {
  const LoomReveal({
    required this.child,
    this.animate = true,
    this.offset = 12,
    this.order = 0,
    this.onEnd,
    super.key,
  });
  final Widget child;
  final bool animate;
  final double offset;
  final int order;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    final moving =
        animate && !LoomAccessibility.fromContext(context).reduceMotion;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: moving ? 0 : 1, end: 1),
      duration: moving
          ? Duration(milliseconds: 280 + order.clamp(0, 4).toInt() * 35)
          : Duration.zero,
      onEnd: onEnd,
      curve: LoomMotion.emphasized,
      child: child,
      builder: (context, progress, child) => Opacity(
        opacity: progress,
        child: Transform.translate(
          offset: Offset(0, offset * (1 - progress)),
          child: child,
        ),
      ),
    );
  }
}

/// New outgoing bubbles rise from the composer edge and settle into place.
/// The stable message key prevents sync acknowledgements replaying the motion.
class LoomSendReveal extends StatelessWidget {
  const LoomSendReveal({
    required this.child,
    this.animate = true,
    this.outgoing = true,
    this.onEnd,
    super.key,
  });
  final Widget child;
  final bool animate;
  final bool outgoing;
  final VoidCallback? onEnd;
  @override
  Widget build(BuildContext context) {
    final moving =
        animate && !LoomAccessibility.fromContext(context).reduceMotion;
    return TweenAnimationBuilder<double>(
      key: ValueKey(moving),
      tween: Tween(begin: moving ? 0 : 1, end: 1),
      duration: moving ? const Duration(milliseconds: 330) : Duration.zero,
      curve: Curves.easeOutCubic,
      onEnd: onEnd,
      child: child,
      builder: (context, progress, child) => ClipRect(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: moving ? progress : 1,
          child: Opacity(
            opacity: ((outgoing ? .25 : 0) + progress * (outgoing ? .75 : 1))
                .clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(
                (Directionality.of(context) == TextDirection.rtl ? -1 : 1) *
                    (outgoing ? 14 : 0) *
                    (1 - progress),
                (outgoing ? 38 : 8) * (1 - progress),
              ),
              child: Transform.scale(
                scale: outgoing ? .94 + .06 * progress : 1,
                alignment: AlignmentDirectional.bottomEnd.resolve(
                  Directionality.of(context),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A decorative connection pulse, never a simulated microphone level.
class LoomConnectionPulse extends StatefulWidget {
  const LoomConnectionPulse({
    required this.child,
    required this.active,
    this.size = 144,
    this.color,
    super.key,
  });
  final Widget child;
  final bool active;
  final double size;
  final Color? color;

  @override
  State<LoomConnectionPulse> createState() => _LoomConnectionPulseState();
}

class _LoomConnectionPulseState extends State<LoomConnectionPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  void _sync() {
    final animate = widget.active &&
        TickerMode.valuesOf(context).enabled &&
        !LoomAccessibility.fromContext(context).reduceMotion;
    if (animate && !_pulse.isAnimating) {
      _pulse.repeat();
    }
    if (!animate) {
      _pulse.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant LoomConnectionPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.loom.primary;
    final moving =
        widget.active && !LoomAccessibility.fromContext(context).reduceMotion;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _pulse,
          child: Center(child: widget.child),
          builder: (context, child) => Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < (moving ? 2 : 1); i++)
                ExcludeSemantics(
                  child: Transform.scale(
                    scale: moving
                        ? .74 + .26 * ((_pulse.value + i * .5) % 1)
                        : .85,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color.withAlphaFraction(
                            moving
                                ? .35 * (1 - ((_pulse.value + i * .5) % 1))
                                : .25,
                          ),
                          width: 1.5,
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              child!,
            ],
          ),
        ),
      ),
    );
  }
}

/// Preserve native swipe-back on iOS; other platforms share a quiet page entry.
class LoomPageTransitionsBuilder extends PageTransitionsBuilder {
  const LoomPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (LoomAccessibility.fromContext(context).reduceMotion) {
      return child;
    }
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      // Use this SDK's native builder: its concrete class moved out of the
      // material library in newer Flutter versions. Do not use the ambient
      // theme here, which points back to this builder.
      final nativeBuilder =
          const PageTransitionsTheme().builders[TargetPlatform.iOS]!;
      return nativeBuilder.buildTransitions<T>(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    final curve = animation.drive(CurveTween(curve: LoomMotion.emphasized));
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(.035 * direction, .015),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
    );
  }
}

/// Amicons glyphs do not mirror automatically. Use this for directional chrome.
class LoomDirectionalIcon extends StatelessWidget {
  const LoomDirectionalIcon(this.icon, {this.size, this.color, super.key});
  final IconData icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Transform.flip(
        flipX: Directionality.of(context) == TextDirection.rtl,
        child: Icon(icon, size: size, color: color),
      );
}

class LoomBusyIndicator extends StatelessWidget {
  const LoomBusyIndicator({this.color, this.size = 20, super.key});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: LoomAccessibility.fromContext(context).reduceMotion
            ? Icon(LoomIcons.schedule_rounded, size: size, color: color)
            : CircularProgressIndicator(strokeWidth: 2, color: color),
      );
}

/// Small, shared transition for composer and preview action icons.
/// Keys identify the action; gestures and accessibility stay with the button.
class LoomComposerMorph extends StatelessWidget {
  const LoomComposerMorph({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final reduced = LoomAccessibility.fromContext(context).reduceMotion;
    return AnimatedSize(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 260),
      curve: Curves.easeInOutCubicEmphasized,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: reduced ? Duration.zero : const Duration(milliseconds: 200),
        reverseDuration:
            reduced ? Duration.zero : const Duration(milliseconds: 140),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => reduced
            ? child
            : FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, .12),
                    end: Offset.zero,
                  ).animate(animation),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: .86, end: 1).animate(animation),
                    child: child,
                  ),
                ),
              ),
        child: child,
      ),
    );
  }
}
