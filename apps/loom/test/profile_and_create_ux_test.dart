import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/home/presentation/create_dial.dart';
import 'package:loom_next/features/profile/presentation/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_smoke_test.dart' show host;

void main() {
  testWidgets('create actions expand inline, invoke once and dismiss', (
    tester,
  ) async {
    var chats = 0;
    await tester.pumpWidget(
      host(
        LoomGlassScope(
          quality: LoomGlassQuality.disabled,
          child: Scaffold(
            body: LoomCreateDial(
              onChat: () => chats++,
              onContact: () {},
              onCall: () {},
              onSaved: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('New chat'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('create-dial-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    for (final label in [
      'New chat',
      'Add contact',
      'New call',
      'Saved messages',
    ]) {
      expect(find.byTooltip(label).hitTestable(), findsOneWidget);
    }
    await tester.tap(find.byTooltip('New chat'));
    await tester.pumpAndSettle();
    expect(chats, 1);
    expect(find.byTooltip('New chat'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('create-dial-toggle')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byTooltip('New chat'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('create-dial-toggle')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('New chat'), findsNothing);
  });

  testWidgets('Persian dial respects large text, reduced motion and Back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(
        LoomGlassScope(
          quality: LoomGlassQuality.disabled,
          child: MediaQuery(
            data: const MediaQueryData(
              disableAnimations: true,
              textScaler: TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: LoomCreateDial(
                onChat: () {},
                onContact: () {},
                onCall: () {},
                onSaved: () {},
              ),
            ),
          ),
        ),
        locale: const Locale('fa'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('create-dial-toggle')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('گفتگوی جدید').hitTestable(), findsOneWidget);
    final toggleCenter = tester.getCenter(
      find.byKey(const ValueKey('create-dial-toggle')),
    );
    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      final finder = find.byWidget(button);
      expect(
        tester.getCenter(finder).dx,
        closeTo(toggleCenter.dx, .5),
        reason: 'RTL action circles share the plus button axis',
      );
    }
    expect(tester.takeException(), isNull);
    final context = tester.element(find.byType(LoomCreateDial));
    await Navigator.of(context).maybePop();
    await tester.pumpAndSettle();
    expect(find.byTooltip('گفتگوی جدید'), findsNothing);
    expect(find.byType(LoomCreateDial), findsOneWidget);
  });

  testWidgets('hidden Chats dial does not keep a Back blocker', (tester) async {
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LoomGlassScope(
              quality: LoomGlassQuality.disabled,
              child: Scaffold(
                body: TickerMode(
                  enabled: visible,
                  child: LoomCreateDial(
                    onChat: () {},
                    onContact: () {},
                    onCall: () {},
                    onSaved: () {},
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('create-dial-toggle')));
    await tester.pumpAndSettle();
    update(() => visible = false);
    await tester.pump();
    expect(
      tester
          .widget<PopScope<void>>(
            find.byKey(const ValueKey('create-dial-pop-scope')),
          )
          .canPop,
      isTrue,
    );
    update(() => visible = true);
    await tester.pumpAndSettle();
    expect(find.byTooltip('New chat'), findsNothing);
  });

  testWidgets(
    'profile has no false online state and fits narrow RTL large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          const LoomGlassScope(
            quality: LoomGlassQuality.disabled,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(1.7)),
              child: ProfileScreen(preview: true),
            ),
          ),
          locale: const Locale('fa'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('آنلاین'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('عکس و آواتار'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('profile-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('روی همین دستگاه'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
