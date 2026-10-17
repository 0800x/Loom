import 'package:flutter/widgets.dart';

enum LoomChatDensity { comfortable, compact }

/// Message spacing only; text scaling, media geometry and controls stay intact.
class LoomChatLayoutScope extends InheritedTheme {
  const LoomChatLayoutScope({
    this.density = LoomChatDensity.comfortable,
    required super.child,
    super.key,
  });

  final LoomChatDensity density;

  static LoomChatDensity of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LoomChatLayoutScope>()
          ?.density ??
      LoomChatDensity.comfortable;

  @override
  bool updateShouldNotify(LoomChatLayoutScope oldWidget) =>
      oldWidget.density != density;

  @override
  Widget wrap(BuildContext context, Widget child) =>
      LoomChatLayoutScope(density: density, child: child);
}
