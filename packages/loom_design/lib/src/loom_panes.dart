import 'package:flutter/foundation.dart';

@immutable
class LoomPaneRange {
  const LoomPaneRange({
    required this.min,
    required this.preferred,
    required this.max,
  })  : assert(min <= preferred),
        assert(preferred <= max);

  final double min;
  final double preferred;
  final double max;

  double clamp(double value) => value.clamp(min, max).toDouble();
}

abstract final class LoomPaneSpecs {
  static const conversationList = LoomPaneRange(
    min: 300,
    preferred: 356,
    max: 420,
  );

  static const details = LoomPaneRange(min: 300, preferred: 344, max: 420);
}

/// State boundary for future user-resizable desktop panes.
///
/// Phase 1.5 does not render drag handles or persist widths. Keeping the width
/// policy here prevents future resize logic from leaking into feature widgets.
class LoomPaneController extends ChangeNotifier {
  LoomPaneController({double? conversationListWidth, double? detailsWidth})
      : _conversationListWidth = LoomPaneSpecs.conversationList.clamp(
          conversationListWidth ?? LoomPaneSpecs.conversationList.preferred,
        ),
        _detailsWidth = LoomPaneSpecs.details.clamp(
          detailsWidth ?? LoomPaneSpecs.details.preferred,
        );

  double _conversationListWidth;
  double _detailsWidth;

  double get conversationListWidth => _conversationListWidth;
  double get detailsWidth => _detailsWidth;

  void setConversationListWidth(double value) {
    final next = LoomPaneSpecs.conversationList.clamp(value);
    if (next == _conversationListWidth) return;
    _conversationListWidth = next;
    notifyListeners();
  }

  void setDetailsWidth(double value) {
    final next = LoomPaneSpecs.details.clamp(value);
    if (next == _detailsWidth) return;
    _detailsWidth = next;
    notifyListeners();
  }
}
