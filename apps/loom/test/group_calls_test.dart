import 'dart:async';
import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/groups/application/groups_controller.dart';
import 'package:loom_next/features/groups/application/group_call_controller.dart';
import 'package:loom_next/features/groups/application/group_call_models.dart';
import 'package:loom_next/features/groups/application/group_call_media.dart';
import 'package:loom_next/features/groups/presentation/group_call_screen.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const callId = '12345678-1234-1234-1234-123456789abc',
    participantId = 'p_12345678-1234-1234-1234-123456789abc';
LoomGroupMember member(String id, String role) => LoomGroupMember(
  accountId: id,
  deviceId: 'device-$id',
  identityId: 'identity-$id',
  role: role,
  mlsSignatureKey: '',
  mlsSignature: '',
);
final state = LoomGroupState(
  id: 'g',
  title: 'Friends',
  epoch: 1,
  revision: 1,
  sequence: 1,
  members: [member('a', 'owner'), member('b', 'member')],
);
Map<String, Object?> snapshot({bool publish = true}) => {
  'id': callId,
  'groupId': 'g',
  'epoch': 1,
  'revision': 1,
  'phase': 'active',
  'kind': 'video',
  'mode': 'approval',
  'joinLocked': false,
  'participants': <Map<String, Object?>>[
    {
      'id': participantId,
      'accountId': 'a',
      'deviceId': 'device-a',
      'name': 'Alice',
      'role': 'owner',
      'state': 'connected',
      'subscribe': true,
      'microphone': publish,
      'camera': publish,
    },
  ],
};

class Groups extends LoomGroupsController {
  Groups(LoomOnboardingController onboarding)
    : super(
        onboarding: onboarding,
        trustedDevice: (_) async => throw StateError('unused'),
        devicesForContact: (_) async => [],
      );
  final keys = <Uint8List>[];
  bool publish = true;
  String url = 'wss://home.test/conference';
  @override
  Future<Uint8List> exportCallKey(String id, String call, int epoch) async {
    final key = Uint8List.fromList(List.filled(32, 7));
    keys.add(key);
    return key;
  }

  @override
  Future<Map<String, Object?>> callRequest(
    String id,
    String action, [
    Map<String, Object?>? body,
  ]) async => {
    'available': true,
    'video': true,
    'maximum': 16,
    'call': snapshot(publish: publish),
    if (action == 'join') ...{
      'participantId': participantId,
      'token': 'test',
      'url': url,
    },
  };
}

class Media extends LoomGroupCallMedia {
  bool closed = false, mic = false, cam = false, wait = false;
  final hold = Completer<void>();
  int microphoneStarts = 0;
  @override
  bool get connected => !closed;
  @override
  bool get microphoneEnabled => mic;
  @override
  bool get cameraEnabled => cam;
  @override
  Set<String> get speakers => {};
  @override
  Future<void> connect(Uri uri, String token, Uint8List key) async {
    if (wait) {
      await hold.future;
    }
  }

  @override
  Future<void> applyPolicy(LoomGroupCallSnapshot call, String ownId) async {
    final p = call.participants.single;
    if (!p.microphone) {
      mic = false;
    }
    if (!p.camera) {
      cam = false;
    }
  }

  @override
  Future<void> microphone(bool enabled) async {
    mic = enabled;
    if (enabled) {
      microphoneStarts++;
    }
    notifyListeners();
  }

  @override
  Future<void> camera(bool enabled) async {
    cam = enabled;
    notifyListeners();
  }

  @override
  Future<void> speakerphone(bool enabled) async {}
  @override
  Future<void> switchCamera() async {}
  @override
  Widget? video(String id) => null;
  @override
  Future<void> close() async {
    closed = true;
    mic = false;
    cam = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LoomAppLock.instance.initialize());
  late LoomNodeDirectoryController nodes;
  late LoomOnboardingController onboarding;
  late Groups groups;
  late Media media;
  late LoomGroupCallController calls;
  setUp(() {
    LoomAppLock.instance.enabled = false;
    LoomAppLock.instance.locked = false;
    nodes = LoomNodeDirectoryController();
    onboarding = LoomOnboardingController(nodes: nodes)
      ..receipt = const LoomRegistrationReceipt(
        accountId: 'a',
        deviceId: 'device-a',
        address: '@alice:home.test',
        homeNode: 'home.test',
      );
    groups = Groups(onboarding)
      ..ready = true
      ..groups = [state];
    media = Media();
    calls = LoomGroupCallController(
      groups: groups,
      otherCallActive: () => false,
      mediaFactory: () => media,
      heartbeatInterval: const Duration(milliseconds: 20),
    );
  });
  tearDown(() async {
    await calls.leave();
    calls.dispose();
    groups.dispose();
    onboarding.dispose();
    nodes.dispose();
  });
  test(
    'joining leaves capture off, wipes the export, and app lock closes media',
    () async {
      expect(await calls.join('g'), true);
      expect(media.microphoneStarts, 0);
      expect(media.cameraEnabled, false);
      expect(groups.keys.single.every((b) => b == 0), true);
      await calls.toggleMicrophone();
      expect(media.microphoneStarts, 1);
      LoomAppLock.instance.locked = true;
      LoomAppLock.instance.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(media.closed, true);
      expect(calls.isActive, false);
      LoomAppLock.instance.locked = false;
    },
  );
  test('foreign media endpoint is rejected and key wiped', () async {
    groups.url = 'wss://elsewhere.test/conference';
    expect(await calls.join('g'), false);
    expect(calls.isActive, false);
    expect(groups.keys.single.every((b) => b == 0), true);
  });
  test(
    'permission revocation stops capture and membership change ends the call',
    () async {
      expect(await calls.join('g'), true);
      await calls.toggleMicrophone();
      await calls.toggleCamera();
      groups.publish = false;
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(media.mic, false);
      expect(media.cam, false);
      groups.groups = [];
      groups.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(media.closed, true);
      expect(calls.error, 'keys_changed');
    },
  );
  test('cancelled connect cannot wipe a later session key', () async {
    media.wait = true;
    final joining = calls.join('g');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final old = media;
    await calls.leave();
    media = Media()..wait = true;
    final next = calls.join('g');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(groups.keys.last.any((b) => b != 0), true);
    old.hold.complete();
    expect(await joining, false);
    expect(groups.keys.last.any((b) => b != 0), true);
    media.hold.complete();
    expect(await next, true);
    expect(groups.keys.last.every((b) => b == 0), true);
  });
  test(
    'malformed epoch, duplicate account and unverified role are rejected',
    () {
      final bad = snapshot();
      (bad['participants'] as List).add(
        Map<String, Object?>.from((bad['participants'] as List).first as Map),
      );
      expect(
        () => LoomGroupCallSnapshot.fromJson(bad, state),
        throwsFormatException,
      );
      expect(
        () => LoomGroupCallSnapshot.fromJson(snapshot()..['epoch'] = -1, state),
        throwsFormatException,
      );
      final role = snapshot();
      ((role['participants'] as List).first as Map)['role'] = 'member';
      expect(
        () => LoomGroupCallSnapshot.fromJson(role, state),
        throwsFormatException,
      );
    },
  );
  for (final locale in ['en', 'fa']) {
    testWidgets(
      '320px large-text $locale controls require explicit capture and expose moderation',
      (tester) async {
        tester.view.physicalSize = const Size(320, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final actions = <String>[], json = snapshot(publish: false);
        (json['participants'] as List).add(<String, Object?>{
          'id': 'p_12345678-1234-1234-1234-123456789abd',
          'accountId': 'b',
          'deviceId': 'device-b',
          'name': 'Bob',
          'role': 'member',
          'state': 'connected',
          'subscribe': true,
          'microphone': false,
          'camera': false,
          'handRaisedAt': 1,
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('en'), Locale('fa')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: SafeArea(
                child: LoomGroupCallSurface(
                  call: LoomGroupCallSnapshot.fromJson(json, state),
                  ownId: participantId,
                  admin: true,
                  owner: true,
                  joining: false,
                  busy: false,
                  microphone: false,
                  camera: false,
                  speaker: true,
                  speakers: const {},
                  video: (_) => null,
                  onMicrophone: () => actions.add('mic'),
                  onCamera: () => actions.add('camera'),
                  onSpeaker: () => actions.add('speaker'),
                  onSwitchCamera: () => actions.add('switch'),
                  onLeave: () => actions.add('leave'),
                  onControl: (a, p) => actions.add(a),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(actions, isEmpty);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, LoomIcons.mic_off_rounded),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.widgetWithText(
            TextButton,
            locale == 'fa' ? 'درخواست صحبت' : 'Request to speak',
          ),
        );
        await tester.pump();
        expect(actions, ['raise_hand']);
        final moderation = find.byTooltip(
          locale == 'fa' ? 'کنترل شرکت‌کننده' : 'Participant controls',
        );
        await tester.scrollUntilVisible(
          moderation,
          200,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(moderation);
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(locale == 'fa' ? 'اجازهٔ صحبت' : 'Allow to speak'),
        );
        await tester.pumpAndSettle();
        expect(actions.last, 'allow_speak');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
