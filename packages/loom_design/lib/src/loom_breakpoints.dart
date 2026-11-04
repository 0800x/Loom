import 'package:flutter/widgets.dart';

enum LoomWindowClass { compact, medium, expanded, ultraWide }

abstract final class LoomBreakpoints {
  static const double medium = 600;
  static const double expanded = 960;
  static const double ultraWide = 1440;

  static LoomWindowClass ofWidth(double width) {
    if (width < medium) return LoomWindowClass.compact;
    if (width < expanded) return LoomWindowClass.medium;
    if (width < ultraWide) return LoomWindowClass.expanded;
    return LoomWindowClass.ultraWide;
  }

  static LoomWindowClass of(BuildContext context) =>
      ofWidth(MediaQuery.sizeOf(context).width);
}

class LoomResponsive extends StatelessWidget {
  const LoomResponsive({
    required this.compact,
    this.medium,
    this.expanded,
    this.ultraWide,
    super.key,
  });

  final WidgetBuilder compact;
  final WidgetBuilder? medium;
  final WidgetBuilder? expanded;
  final WidgetBuilder? ultraWide;

  @override
  Widget build(BuildContext context) {
    return switch (LoomBreakpoints.of(context)) {
      LoomWindowClass.compact => compact(context),
      LoomWindowClass.medium => (medium ?? compact)(context),
      LoomWindowClass.expanded => (expanded ?? medium ?? compact)(context),
      LoomWindowClass.ultraWide => (ultraWide ?? expanded ?? medium ?? compact)(
        context,
      ),
    };
  }
}
