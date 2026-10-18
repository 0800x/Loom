import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/groups/application/groups_controller.dart';
import 'package:loom_next/features/groups/presentation/group_join_screen.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final token = List.filled(43, 'a').join();

class _Groups extends LoomGroupsController {
  _Groups(LoomOnboardingController onboarding)
    : super(
        onboarding: onboarding,
        trustedDevice: (_) async => throw StateError('unused'),
        devicesForContact: (_) async => [],
      );
  String status = 'none';
  String mode = 'open';
  int previews = 0, joins = 0;
  bool unavailable = false;
  @override
  Future<Map<String, Object?>?> previewInvite(String token) async {
    previews++;
    if (unavailable) {
      errorCode = 'group_invite_unavailable';
      return null;
    }
    return {
      'groupId': 'g',
      'title': 'Friends',
      'memberCount': 3,
      'mode': mode,
      'status': status,
    };
  }

  @override
  Future<String?> joinInvite(String token) async {
    joins++;
    status = mode == 'open' ? 'approved' : 'pending';
    return 'g';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LoomAppLock.instance.initialize());
  test(
    'invitation links preserve only a secure node origin and an opaque token',
    () {
      final link = LoomGroupInviteLink.tryParse(
        'https://home.test:8443/g/$token',
      )!;
      expect(link.node.origin, 'https://home.test:8443');
      expect(link.token, token);
      final custom = Uri(
        scheme: 'loom',
        host: 'group',
        path: '/join',
        queryParameters: {'node': link.node.toString(), 'token': token},
      );
      expect(LoomGroupInviteLink.tryParse(custom.toString())!.node, link.node);
      final loom = custom.replace(scheme: 'loom');
      expect(LoomGroupInviteLink.tryParse(loom.toString())!.node, link.node);
      expect(LoomGroupInviteLink.tryParse('$loom&token=$token'), isNull);
      expect(LoomGroupInviteLink.tryParse('$loom#x'), isNull);
      for (final bad in [
        'http://home.test/g/$token',
        'https://user@home.test/g/$token',
        'https://home.test/g/$token?secret=1',
        'https://home.test/g/$token#x',
        'https://home.test/g/short',
        'https://home.test/other/$token',
        '$custom&token=$token',
        '$custom#x',
        'loom://group/join?node=http%3A%2F%2Fhome.test&token=$token',
        'loom://group/join?node=https%3A%2F%2Fhome.test%2Fapi&token=$token',
      ]) {
        expect(LoomGroupInviteLink.tryParse(bad), isNull, reason: bad);
      }
    },
  );
  test(
    'a generic encrypted file has a stable caption, name and attachment preview',
    () {
      const content = LoomMessageContent(
        attachment: {
          'kind': 'file',
          'url': 'https://home.test/api/v1/attachments/a',
          'key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'bytes': 100,
          'name': 'report.pdf',
        },
      );
      final decoded = LoomMessageContent.decode(content.encode());
      expect(decoded.attachment!['name'], 'report.pdf');
      expect(decoded.replyExcerpt, 'report.pdf');
      expect(decoded.preview, '📎');
    },
  );
  for (final mode in ['open', 'approval']) {
    testWidgets(
      '$mode invitation previews before joining and shows the real waiting state',
      (tester) async {
        final nodes = LoomNodeDirectoryController()
          ..selectedEndpoint = Uri.parse('https://home.test');
        final onboarding = LoomOnboardingController(nodes: nodes);
        final groups = _Groups(onboarding)..mode = mode;
        await tester.pumpWidget(
          LoomGroupsScope(
            controller: groups,
            child: MaterialApp(
              theme: LoomTheme.dark(),
              home: LoomGroupJoinScreen(
                initialLink: 'https://home.test/g/$token',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Friends'), findsOneWidget);
        expect(groups.joins, 0);
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(groups.joins, 1);
        expect(
          find.text(
            mode == 'open'
                ? 'Accepted. Waiting for an administrator device to sync the encrypted invitation.'
                : 'Waiting for administrator approval.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        groups.dispose();
        onboarding.dispose();
        nodes.dispose();
      },
    );
  }
  testWidgets(
    'a link to another Home Node never reaches the signed group client',
    (tester) async {
      final nodes = LoomNodeDirectoryController()
        ..selectedEndpoint = Uri.parse('https://home.test');
      final onboarding = LoomOnboardingController(nodes: nodes);
      final groups = _Groups(onboarding);
      await tester.pumpWidget(
        LoomGroupsScope(
          controller: groups,
          child: MaterialApp(
            home: LoomGroupJoinScreen(
              initialLink: 'https://other.test/g/$token',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(groups.previews, 0);
      expect(
        find.text('Use an invitation from your current Home Node.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      groups.dispose();
      onboarding.dispose();
      nodes.dispose();
    },
  );
  testWidgets('expired or revoked invitation offers recovery and never joins', (
    tester,
  ) async {
    final nodes = LoomNodeDirectoryController()
      ..selectedEndpoint = Uri.parse('https://home.test');
    final onboarding = LoomOnboardingController(nodes: nodes);
    final groups = _Groups(onboarding)..unavailable = true;
    await tester.pumpWidget(
      LoomGroupsScope(
        controller: groups,
        child: MaterialApp(
          home: LoomGroupJoinScreen(initialLink: 'https://home.test/g/$token'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This invitation has expired, was revoked, or is unavailable. Ask an administrator for a new link.',
      ),
      findsOneWidget,
    );
    expect(groups.joins, 0);
    expect(find.byType(FilledButton), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(groups.previews, 2);
    expect(groups.joins, 0);
    await tester.pumpWidget(const SizedBox());
    groups.dispose();
    onboarding.dispose();
    nodes.dispose();
  });

  testWidgets('malformed link is identified without a server request', (
    tester,
  ) async {
    final nodes = LoomNodeDirectoryController()
      ..selectedEndpoint = Uri.parse('https://home.test');
    final onboarding = LoomOnboardingController(nodes: nodes);
    final groups = _Groups(onboarding);
    await tester.pumpWidget(
      LoomGroupsScope(
        controller: groups,
        child: const MaterialApp(
          home: LoomGroupJoinScreen(initialLink: 'https://home.test/g/short'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This invitation link is malformed. Ask an administrator for the complete link.',
      ),
      findsOneWidget,
    );
    expect(groups.previews, 0);
    expect(groups.joins, 0);
    await tester.pumpWidget(const SizedBox());
    groups.dispose();
    onboarding.dispose();
    nodes.dispose();
  });

  testWidgets('inserting a bubble moves previous messages upward gradually', (
    tester,
  ) async {
    Widget app(bool inserted, {bool reduced = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                key: ValueKey('old'),
                height: 60,
                child: Text('Previous bubble'),
              ),
              if (inserted)
                const LoomSendReveal(
                  key: ValueKey('new'),
                  child: SizedBox(height: 100, child: Text('New bubble')),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(false));
    final before = tester.getTopLeft(find.byKey(const ValueKey('old'))).dy;
    await tester.pumpWidget(app(true));
    final start = tester.getTopLeft(find.byKey(const ValueKey('old'))).dy;
    await tester.pump(const Duration(milliseconds: 100));
    final middle = tester.getTopLeft(find.byKey(const ValueKey('old'))).dy;
    await tester.pumpAndSettle();
    final end = tester.getTopLeft(find.byKey(const ValueKey('old'))).dy;
    expect(start, closeTo(before, .01));
    expect(middle, lessThan(start));
    expect(middle, greaterThan(end));
    expect(end, closeTo(before - 100, .01));
    await tester.pumpWidget(app(false, reduced: true));
    await tester.pumpWidget(app(true, reduced: true));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('old'))).dy,
      closeTo(end, .01),
    );
  });
  testWidgets(
    'outgoing motion settles once, survives an acknowledgement rebuild and respects reduced motion',
    (tester) async {
      Widget app({bool reduced = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: const LoomSendReveal(
            key: ValueKey('stable-message-id'),
            child: Text('Sent bubble'),
          ),
        ),
      );
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(LoomSendReveal),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      await tester.pumpWidget(app());
      expect(opacity(), lessThan(1));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      await tester.pumpWidget(app());
      expect(opacity(), 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(reduced: true));
      expect(opacity(), 1);
    },
  );
}
