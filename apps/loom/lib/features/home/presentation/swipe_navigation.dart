import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

/// Vertical lists retain their recognizer. A completed horizontal drag moves
/// one section; disabled inside conversations so message replies stay local.
class LoomSectionSwipe extends StatefulWidget {
  const LoomSectionSwipe({
    required this.child,
    this.onNext,
    this.onPrevious,
    this.enabled = true,
    super.key,
  });
  final Widget child;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final bool enabled;
  @override
  State<LoomSectionSwipe> createState() => _LoomSectionSwipeState();
}

class _LoomSectionSwipeState extends State<LoomSectionSwipe> {
  double _distance = 0;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    dragStartBehavior: DragStartBehavior.down,
    onHorizontalDragStart: widget.enabled ? (_) => _distance = 0 : null,
    onHorizontalDragUpdate: widget.enabled
        ? (details) {
            _distance += details.delta.dx;
          }
        : null,
    onHorizontalDragCancel: widget.enabled ? () => _distance = 0 : null,
    onHorizontalDragEnd: widget.enabled
        ? (details) {
            final logical =
                _distance *
                (Directionality.of(context) == TextDirection.rtl ? -1 : 1);
            _distance = 0;
            final velocity =
                (details.primaryVelocity ?? 0) *
                (Directionality.of(context) == TextDirection.rtl ? -1 : 1);
            final threshold = (MediaQuery.sizeOf(context).width * .18).clamp(
              64.0,
              120.0,
            );
            final fling =
                logical.abs() >= 24 &&
                velocity.abs() >= 700 &&
                logical.sign == velocity.sign;
            if (logical <= -threshold || (fling && logical < 0)) {
              widget.onNext?.call();
            }
            if (logical >= threshold || (fling && logical > 0)) {
              widget.onPrevious?.call();
            }
          }
        : null,
    child: widget.child,
  );
}

/// The inner folder pager wins the gesture arena. At its last edge, hand off
/// one completed drag to the shell, rather than competing with a second pager.
class LoomFolderSwipeBoundary extends StatefulWidget {
  const LoomFolderSwipeBoundary({
    required this.child,
    this.onNext,
    super.key,
  });
  final Widget child;
  final VoidCallback? onNext;
  @override
  State<LoomFolderSwipeBoundary> createState() =>
      _LoomFolderSwipeBoundaryState();
}

class _LoomFolderSwipeBoundaryState extends State<LoomFolderSwipeBoundary> {
  double _overscroll = 0;
  bool _drag = false;
  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (event) {
          if (event.depth != 0 || event.metrics.axis != Axis.horizontal) {
            return false;
          }
          if (event is ScrollStartNotification) {
            _drag = event.dragDetails != null;
            _overscroll = 0;
          } else if (event is OverscrollNotification &&
              _drag &&
              event.dragDetails != null) {
            _overscroll = (_overscroll + event.overscroll).clamp(0.0, 1000.0);
          } else if (event is ScrollUpdateNotification &&
              event.dragDetails != null) {
            // Reversing back into the pager disarms the handoff.
            _overscroll = 0;
          } else if (event is ScrollEndNotification) {
            final advance = _drag && _overscroll >= 48;
            _drag = false;
            _overscroll = 0;
            if (advance) {
              widget.onNext?.call();
            }
          }
          return false;
        },
        child: widget.child,
      );
}
