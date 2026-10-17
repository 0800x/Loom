import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final key in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
  ]) {
    testWidgets('Windows $key sends once and retains focus', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      var sends = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.light(),
          home: Scaffold(
            body: LoomGlassComposer(
              controller: controller,
              focusNode: focus,
              hintText: 'Message',
              attachTooltip: 'Attach',
              voiceTooltip: 'Voice',
              sendTooltip: 'Send',
              onSend: () {
                sends++;
                controller.clear();
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'سلام 🌍\nsecond line');
      await tester.sendKeyDownEvent(key, platform: 'linux');
      await tester.sendKeyRepeatEvent(key, platform: 'linux');
      await tester.sendKeyUpEvent(key, platform: 'linux');
      await tester.pump();
      expect(sends, 1);
      expect(controller.text, isEmpty);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(key, platform: 'linux');
      expect(sends, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('Shift+Enter inserts a newline and active IME never sends', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sends = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.light(),
        home: Scaffold(
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
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(controller.text, 'hello\n');
    expect(sends, 0);
    controller.value = const TextEditingValue(
      text: '你好',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
