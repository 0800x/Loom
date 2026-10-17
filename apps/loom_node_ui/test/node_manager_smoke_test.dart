import 'package:loom_node_ui/src/node_manager_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('manager starts disconnected without fake status', (
    tester,
  ) async {
    await tester.pumpWidget(const LoomNodeManagerApp());
    expect(find.text('Connect to your Node'), findsOneWidget);
    expect(find.text('Accounts'), findsNothing);
  });
}
