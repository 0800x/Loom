import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_next/features/onboarding/presentation/identity_creation_screen.dart';
import 'package:loom_next/features/onboarding/presentation/onboarding_node_selection_screen.dart';
import 'package:loom_next/features/onboarding/presentation/restore_identity_screen.dart';
import 'package:loom_next/features/onboarding/presentation/sign_in_screen.dart';
import 'package:loom_next/features/onboarding/presentation/startup_gate.dart';
import 'package:loom_next/features/onboarding/presentation/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_smoke_test.dart' show host, usePhoneViewport;

const _node = LoomNodeDescriptor(
  nodeId: 'test',
  name: 'Test server',
  domain: 'chat.example.org',
  operatorCountry: '—',
  networkLocation: '—',
  registration: 'open',
  federation: true,
  protocols: ['test'],
  publicKey: 'test',
  fingerprint: 'test',
  capabilities: [],
);

class _Nodes extends LoomNodeDirectoryController {
  _Nodes() {
    state = LoomNodeDirectoryState.ready;
    nodes = [_node];
  }
  @override
  bool get selectedNodeVerified => selectedNode != null;
  @override
  Future<void> selectRegistryNode(LoomNodeDescriptor node) async {
    selectedNode = node;
    selectedEndpoint = Uri.https(node.domain);
    selectedLiveInfo = LoomNodeLiveInfo(
      nodeId: node.nodeId,
      serverVersion: 'test',
      protocolVersion: 'test',
      registration: node.registration,
      federationMode: 'enabled',
      capabilities: node.capabilities,
    );
    notifyListeners();
  }
}

class _Onboarding extends LoomOnboardingController {
  _Onboarding({required super.nodes});
  int createCount = 0;
  int restoreCount = 0;
  int startupCount = 0;
  @override
  Future<bool> createIdentity({
    required String username,
    required String displayName,
    required String password,
  }) async {
    createCount++;
    return false;
  }

  @override
  Future<bool> restoreIdentityWords(String sentence) async {
    restoreCount++;
    return true;
  }

  @override
  Future<bool> restorePersistedSession() async {
    startupCount++;
    if (startupCount == 1) {
      throw StateError('Locked key store');
    }
    return false;
  }
}

Widget _scope(
  _Nodes nodes,
  _Onboarding onboarding,
  Widget child, {
  Map<String, WidgetBuilder> routes = const {},
}) => LoomGlassScope(
  quality: LoomGlassQuality.disabled,
  child: LoomNodeDirectoryScope(
    controller: nodes,
    child: LoomOnboardingScope(
      controller: onboarding,
      child: host(child, routes: routes),
    ),
  ),
);

void main() {
  late _Nodes nodes;
  late _Onboarding onboarding;
  setUp(() {
    nodes = _Nodes();
    onboarding = _Onboarding(nodes: nodes);
  });
  tearDown(() {
    onboarding.dispose();
    nodes.dispose();
  });

  testWidgets(
    'choosing a server from sign-in returns to the same populated form',
    (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        _scope(
          nodes,
          onboarding,
          LoomSignInScreen(localIdentityProbe: () async => true),
          routes: {
            '/nodes': (_) => const LoomOnboardingNodeSelectionScreen(),
            '/identity': (_) => const Text('WRONG: create a new account'),
          },
        ),
      );
      await tester.pumpAndSettle();
      final username = find
          .byWidgetPredicate(
            (widget) =>
                widget is TextFormField &&
                widget.controller != null &&
                widget.controller!.text.isEmpty,
          )
          .at(1);
      await tester.enterText(username, 'alice');
      await tester.ensureVisible(find.text('Choose home server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose home server'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Test server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test server'));
      await tester.pumpAndSettle();
      expect(find.text('Server identity verified'), findsOneWidget);
      await tester.ensureVisible(find.text('Continue with this server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with this server'));
      await tester.pumpAndSettle();
      expect(find.byType(LoomSignInScreen), findsOneWidget);
      final values = tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .map((field) => field.controller!.text);
      expect(values, containsAll(['alice', 'chat.example.org']));
      expect(find.text('WRONG: create a new account'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid setup fields are caught before identity generation', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      _scope(nodes, onboarding, const IdentityCreationScreen()),
    );
    await tester.ensureVisible(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(onboarding.createCount, 0);
    expect(find.text('Enter the name people will see.'), findsOneWidget);
    expect(find.text('Use a password with 12–256 characters.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restoring words continues to sign-in, not back to welcome', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      _scope(
        nodes,
        onboarding,
        const RestoreIdentityScreen(),
        routes: {
          '/sign-in': (_) => const Scaffold(body: Text('Restored sign-in')),
        },
      ),
    );
    await tester.enterText(
      find.byType(TextField),
      List.filled(24, 'test').join(' '),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Restore account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore account'));
    await tester.pumpAndSettle();
    expect(onboarding.restoreCount, 1);
    expect(find.text('Restored sign-in'), findsOneWidget);
  });

  testWidgets('failed device probe offers a retry without leaving a spinner', (
    tester,
  ) async {
    usePhoneViewport(tester);
    var attempts = 0;
    await tester.pumpWidget(
      _scope(
        nodes,
        onboarding,
        LoomSignInScreen(
          localIdentityProbe: () async {
            if (++attempts == 1) {
              throw StateError('Unavailable');
            }
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Retry device check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry device check'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Retry device check'), findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets(
    'startup restore failure is recoverable without clearing an account',
    (tester) async {
      await tester.pumpWidget(
        _scope(
          nodes,
          onboarding,
          LoomStartupGate(
            controller: onboarding,
            onThemeChanged: (_) {},
            onLocaleChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(onboarding.startupCount, 2);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.text('Let’s get started'), findsOneWidget);
    },
  );
}
