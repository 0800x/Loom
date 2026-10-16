import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Retains the same recognizers when recording changes the button appearance.
class LoomHoldRecordAction extends StatelessWidget {
  const LoomHoldRecordAction({
    required this.child,
    required this.onStart,
    required this.onMove,
    required this.onEnd,
    required this.onCancel,
    this.onTap,
    super.key,
  });
  final Widget child;
  final GestureLongPressStartCallback onStart;
  final GestureLongPressMoveUpdateCallback onMove;
  final GestureLongPressEndCallback onEnd;
  final VoidCallback onCancel;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              duration: const Duration(milliseconds: 200),
            ),
            (r) => r
              ..onLongPressStart = onStart
              ..onLongPressMoveUpdate = onMove
              ..onLongPressEnd = onEnd
              ..onLongPressCancel = onCancel,
          ),
      TapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            TapGestureRecognizer.new,
            (r) => r.onTap = onTap,
          ),
    },
    child: child,
  );
}
