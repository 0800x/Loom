import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

/// The texture, initialization placeholder and retake preview share one clip.
class LoomCircularVideoPreview extends StatelessWidget {
  const LoomCircularVideoPreview({
    required this.diameter,
    required this.child,
    this.progress,
    super.key,
  });
  final double diameter;
  final Widget child;
  final double? progress;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: diameter,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: const EdgeInsets.all(3),
          child: ClipOval(
            child: ColoredBox(color: Colors.black, child: child),
          ),
        ),
        if (progress != null)
          IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress!.clamp(0.0, 1.0)),
              duration: LoomAccessibility.fromContext(context).reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              builder: (context, value, _) => CircularProgressIndicator(
                value: value,
                strokeWidth: 3,
                color: context.loom.critical,
                backgroundColor: Colors.white24,
              ),
            ),
          ),
      ],
    ),
  );
}
