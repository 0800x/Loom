import 'package:flutter/widgets.dart';

/// Keeps history's viewport behind the composer. The builder must reserve
/// the supplied bottom extent inside its scroll content, not outside the scroll viewport.
class LoomComposerOverlay extends StatefulWidget {
  const LoomComposerOverlay({
    required this.historyBuilder,
    required this.composer,
    super.key,
  });

  final Widget Function(BuildContext context, double bottomExtent)
  historyBuilder;
  final Widget composer;

  @override
  State<LoomComposerOverlay> createState() => _LoomComposerOverlayState();
}

class _LoomComposerOverlayState extends State<LoomComposerOverlay> {
  final _composerKey = GlobalKey();
  double _extent = 96;
  bool _measurementScheduled = false;

  void _scheduleMeasurement() {
    if (_measurementScheduled) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      _measurementScheduled = false;
      if (!mounted) return;
      final render = _composerKey.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return;
      final next = render.size.height;
      if ((next - _extent).abs() > .5) {
        setState(() => _extent = next);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasurement();
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: widget.historyBuilder(context, _extent)),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: NotificationListener<SizeChangedLayoutNotification>(
            onNotification: (notification) {
              _scheduleMeasurement();
              return false;
            },
            child: SizeChangedLayoutNotifier(
              child: SizedBox(key: _composerKey, child: widget.composer),
            ),
          ),
        ),
      ],
    );
  }
}
