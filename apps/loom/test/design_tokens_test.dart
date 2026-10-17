import 'package:loom_design/loom_design.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('breakpoints are monotonic and explicit', () {
    expect(LoomBreakpoints.ofWidth(599), LoomWindowClass.compact);
    expect(LoomBreakpoints.ofWidth(600), LoomWindowClass.medium);
    expect(LoomBreakpoints.ofWidth(960), LoomWindowClass.expanded);
    expect(LoomBreakpoints.ofWidth(1440), LoomWindowClass.ultraWide);
  });

  test('minimum touch target remains accessible', () {
    expect(LoomSizing.minTouch, greaterThanOrEqualTo(48));
  });
}
