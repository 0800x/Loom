import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('composer gates blank text and sends with Ctrl Enter', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sends = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.dark(),
        home: LoomGlassScope(
          quality: LoomGlassQuality.disabled,
          child: Scaffold(
            body: LoomGlassComposer(
              controller: controller,
              hintText: 'Message',
              attachTooltip: 'Attach',
              voiceTooltip: 'Voice',
              sendTooltip: 'Send',
              onSend: () => sends++,
            ),
          ),
        ),
      ),
    );
    IconButton sendButton() => tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, LoomIcons.arrow_upward_rounded),
    );
    expect(sendButton().onPressed, isNull);
    expect(find.byTooltip('Attach'), findsNothing);
    expect(find.byTooltip('Voice'), findsNothing);
    await tester.enterText(find.byType(TextField), '  \n ');
    await tester.pump();
    expect(sendButton().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(sendButton().onPressed, isNotNull);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(sends, 1);
    expect(controller.text, 'hello');
  });
}
