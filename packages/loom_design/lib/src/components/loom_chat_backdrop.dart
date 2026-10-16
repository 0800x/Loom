import 'package:flutter/material.dart';
import '../loom_theme.dart';
import '../loom_accessibility.dart';

/// Original Loom doodles, faintly tinted to the shared theme.
/// High contrast stays plain; OLED preserves its black base.
class LoomChatBackdrop extends StatelessWidget {
  const LoomChatBackdrop({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final palette = context.loom;
    final highContrast = LoomAccessibility.fromContext(context).highContrast;
    return ColoredBox(
      color: palette.background,
      child: Stack(
        children: [
          if (!highContrast) Positioned.fill(
            child: IgnorePointer(
              child: Image.asset(
                'assets/wallpapers/loom-doodles.png',
                package: 'loom_design',
                repeat: ImageRepeat.repeat,
                fit: BoxFit.none,
                scale: 2.5,
                alignment: Alignment.topLeft,
                color: palette.textMuted.withValues(alpha: .09),
                colorBlendMode: BlendMode.srcIn,
                excludeFromSemantics: true,
                errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
