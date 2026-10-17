import 'dart:convert';
import 'dart:io';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/groups/application/groups_controller.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

class _Onboarding extends LoomOnboardingController {
  _Onboarding({required super.nodes, required this.proof});
  final LoomDeviceRequestProofProvider proof;
  @override
  Future<LoomDeviceRequestProofProvider> deviceRequestProofProvider() async =>
      proof;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LoomAppLock.instance.initialize());
  final library = Platform.environment['LOOM_TEST_MLS_LIBRARY'];
  test(
    'production controller: native groups, encrypted restart history, notifications and removal',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        FlutterSecureStorage.setMockInitialValues({});
        LoomAppLock.instance.enabled = false;
        LoomAppLock.instance.locked = false;
        final support = await Directory.systemTemp.createTemp(
          'loom-app-mls-',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        messenger.setMockMethodCallHandler(paths, (_) async => support.path);
        final node = await Process.start(
          'node',
          [
            '--experimental-strip-types',
            '../../services/loom_server/test/helpers/mls_http_fixture.ts',
          ],
          environment: {'NODE_NO_WARNINGS': '1'},
        );
        final stderr = <String>[];
        node.stderr.transform(utf8.decoder).listen(stderr.add);
        final config =
            jsonDecode(
                  await node.stdout
                      .transform(utf8.decoder)
                      .transform(const LineSplitter())
                      .first
                      .timeout(const Duration(seconds: 15)),
                )
                as Map;
        final fixtures = config['fixtures'] as List;
        final bundles = fixtures
            .map(
              (f) => LoomDeviceKeyBundle.fromJson(
                Map<String, Object?>.from(f['bundle'] as Map),
              ),
            )
            .toList();
        for (var i = 0; i < bundles.length; i++) {
          await LoomDeviceBundleVerifier().verify(
            bundle: bundles[i],
            identityId: bundles[i].identityId,
            identityPublicKey: fixtures[i]['identityPublicKey'] as String,
          );
        }
        final onboardings = <_Onboarding>[];
        final controllers = <LoomGroupsController>[];
        final incoming = <String>[];
        LoomGroupsController make(int i) => LoomGroupsController(
          onboarding: onboardings[i],
          native: LoomNativeMlsCore(libraryPath: library),
          historyCodec: LoomSelfMessageCodec(
            recoveryEntropyProvider: () async => List<int>.filled(32, i + 1),
          ),
          trustedDevice: (member) async =>
              bundles.singleWhere((b) => b.deviceId == member.deviceId),
          devicesForContact: (address) async => [
            bundles[fixtures.indexWhere(
                  (f) => f['receipt']['address'] == address,
                )]
                .deviceId,
          ],
          onIncoming: (id, _) => incoming.add('$i:$id'),
        );
        try {
          for (var i = 0; i < fixtures.length; i++) {
            final receipt = fixtures[i]['receipt'] as Map;
            final public = base64Decode(bundles[i].signingPublicKey);
            final key = SimpleKeyPairData(
              base64Decode(fixtures[i]['signingSeed'] as String),
              type: KeyPairType.ed25519,
              publicKey: SimplePublicKey(public, type: KeyPairType.ed25519),
            );
            final onboarding = _Onboarding(
              nodes: LoomNodeDirectoryController()
                ..selectedEndpoint = Uri.parse(config['baseUri'] as String),
              proof: LoomDeviceRequestProofProvider(
                deviceId: bundles[i].deviceId,
                signer: (bytes) async =>
                    (await Ed25519().sign(bytes, keyPair: key)).bytes,
              ),
            );
            onboarding.receipt = LoomRegistrationReceipt(
              accountId: receipt['accountId'] as String,
              deviceId: bundles[i].deviceId,
              address: receipt['address'] as String,
              homeNode: 'localhost',
            );
            onboarding.committedIdentity = LoomIdentityPublic(
              identityId: bundles[i].identityId,
              publicKey: fixtures[i]['identityPublicKey'] as String,
              fingerprint: 'test',
              createdAt: DateTime.now().toUtc(),
            );
            onboarding.accessToken = receipt['accessToken'] as String;
            onboarding.status = LoomOnboardingStatus.complete;
            onboardings.add(onboarding);
            controllers.add(make(i));
            expect(
              await controllers[i].open(),
              isTrue,
              reason: controllers[i].error,
            );
          }
          final id = await controllers[0].create('Friends', [
            onboardings[1].receipt!.address,
          ]);
          expect(id, isNotNull, reason: controllers[0].error);
          expect(
            await controllers[1].open(),
            isTrue,
            reason: controllers[1].error,
          );
          expect(
            await controllers[0].send(id!, 'private hello'),
            isTrue,
            reason: controllers[0].error,
          );
          expect(
            await controllers[1].open(),
            isTrue,
            reason: controllers[1].error,
          );
          const room = '12345678-1234-1234-1234-123456789abc';
          final aliceKey = await controllers[0].exportCallKey(id, room, 1);
          final bobKey = await controllers[1].exportCallKey(id, room, 1);
          expect(aliceKey, bobKey);
          expect(aliceKey.length, 32);
          aliceKey.fillRange(0, aliceKey.length, 0);
          bobKey.fillRange(0, bobKey.length, 0);
          expect(controllers[1].messages[id]!.single.text, 'private hello');
          expect(incoming, contains('1:$id'));
          expect(controllers[1].unreadCounts[id], 1);
          controllers[1].markGroupRead(id);
          expect(
            controllers[1].activeGroupId,
            isNull,
            reason:
                'Mark as read does not suppress future closed-chat notifications',
          );
          expect(controllers[1].unreadCounts[id], 0);
          expect(controllers[1].messages[id]!.single.createdAt, isNotNull);
          controllers[1].setActiveGroup(id);
          expect(controllers[1].unreadCounts[id], 0);
          controllers[1].dispose();
          controllers[1] = make(1);
          expect(
            await controllers[1].open(),
            isTrue,
            reason: controllers[1].error,
          );
          expect(controllers[1].messages[id]!.single.text, 'private hello');
          expect(controllers[1].unreadCounts[id], 0);
          for (final file in support.listSync().whereType<File>()) {
            expect(
              utf8.decode(file.readAsBytesSync(), allowMalformed: true),
              isNot(contains('private hello')),
            );
          }
          expect(
            await controllers[0].addContact(
              id,
              onboardings[2].receipt!.address,
            ),
            isTrue,
            reason: controllers[0].error,
          );
          expect(
            await controllers[2].open(),
            isTrue,
            reason: controllers[2].error,
          );
          final group = controllers[0].groups.single;
          expect(
            await controllers[0].update(
              id,
              group.title,
              group.members
                  .where((m) => m.deviceId != bundles[1].deviceId)
                  .toList(),
              expectedRevision: group.revision,
            ),
            isTrue,
            reason: controllers[0].error,
          );
          expect(
            await controllers[1].open(),
            isTrue,
            reason: controllers[1].error,
          );
          expect(await controllers[1].send(id, 'should fail'), isFalse);
          expect(
            await controllers[2].send(id, 'new epoch'),
            isTrue,
            reason: controllers[2].error,
          );
          expect(
            await controllers[0].open(),
            isTrue,
            reason: controllers[0].error,
          );
          expect(controllers[0].messages[id]!.last.text, 'new epoch');
          final previousUnread = controllers[2].unreadCounts[id] ?? 0;
          final now = DateTime.now().millisecondsSinceEpoch;
          for (var update = 0; update < 3; update++) {
            expect(
              await controllers[0].sendContent(
                id,
                LoomMessageContent(
                  location: {
                    'session': 'live-native',
                    'lat': 35.0 + update / 100,
                    'lon': 51.0,
                    'at': now + update,
                    'until': now + 60000,
                    'stopped': update == 2,
                  },
                ),
              ),
              isTrue,
              reason: controllers[0].error,
            );
          }
          expect(
            await controllers[2].open(),
            isTrue,
            reason: controllers[2].error,
          );
          final shares = controllers[2].messages[id]!
              .where((m) => m.location?['session'] == 'live-native')
              .toList();
          expect(shares.length, 1);
          expect(shares.single.location!['stopped'], true);
          expect(shares.single.location!['lat'], 35.02);
          expect(controllers[2].unreadCounts[id], previousUnread + 1);
          // Owner-only groups and token joins never require a saved contact.
          final inviteId = await controllers[0].create('Invite-only', []);
          expect(inviteId, isNotNull, reason: controllers[0].error);
          expect(
            await controllers[0].send(inviteId!, 'earlier private history'),
            isTrue,
          );
          final photo = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZbkAAAAASUVORK5CYII=',
          );
          expect(
            await controllers[0].setGroupPhoto(inviteId, photo),
            isTrue,
            reason: controllers[0].error,
          );
          expect(controllers[0].messages[inviteId]!.length, 1);
          final inviteLink = await controllers[0].createInvite(
            inviteId,
            'open',
          );
          expect(inviteLink, isNotNull, reason: controllers[0].error);
          final token = Uri.parse(inviteLink!).pathSegments.last;
          final preview = await controllers[2].previewInvite(token);
          expect(preview!['memberCount'], 1);
          expect(await controllers[2].joinInvite(token), inviteId);
          expect(controllers[2].groups.any((g) => g.id == inviteId), isFalse);
          expect(
            await controllers[0].open(),
            isTrue,
            reason: controllers[0].error,
          );
          expect(
            await controllers[2].open(),
            isTrue,
            reason: controllers[2].error,
          );
          expect(controllers[2].groups.any((g) => g.id == inviteId), isTrue);
          expect(controllers[2].messages[inviteId] ?? [], isEmpty);
          expect(controllers[2].groupPhoto(inviteId), photo);
          expect(await controllers[2].setGroupPhoto(inviteId, null), isFalse);
          expect(
            await controllers[0].memberAddress(
              controllers[0].groups
                  .firstWhere((g) => g.id == inviteId)
                  .members
                  .singleWhere((m) => m.deviceId == bundles[2].deviceId),
            ),
            '@carol:localhost',
          );
          final carolMember = controllers[0].groups
              .firstWhere((g) => g.id == inviteId)
              .members
              .singleWhere((m) => m.deviceId == bundles[2].deviceId);
          expect(controllers[0].memberLabel(carolMember), 'Display carol');
          expect(
            controllers[0].memberCachedAddress(carolMember),
            '@carol:localhost',
          );
          await expectLater(
            controllers[0].memberAddress(
              LoomGroupMember(
                accountId: carolMember.accountId,
                deviceId: carolMember.deviceId,
                identityId: bundles[1].identityId,
                role: carolMember.role,
                mlsSignatureKey: carolMember.mlsSignatureKey,
                mlsSignature: carolMember.mlsSignature,
              ),
            ),
            throwsStateError,
          );
          expect(controllers[0].memberLabel(carolMember), 'Display carol');
          const fileContent = LoomMessageContent(
            text: 'encrypted caption',
            attachment: {
              'kind': 'file',
              'url': 'https://localhost/api/v1/attachments/test',
              'key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
              'bytes': 100,
              'name': 'report.pdf',
            },
          );
          expect(
            await controllers[2].sendContent(inviteId, fileContent),
            isTrue,
            reason: controllers[2].error,
          );
          expect(
            await controllers[0].open(),
            isTrue,
            reason: controllers[0].error,
          );
          expect(
            controllers[0].messages[inviteId]!.last.attachment!['name'],
            'report.pdf',
          );
          expect(
            controllers[0].messages[inviteId]!.last.text,
            'encrypted caption',
          );
          final moderated = await controllers[0].createInvite(
            inviteId,
            'approval',
          );
          final moderatedToken = Uri.parse(moderated!).pathSegments.last;
          expect(await controllers[1].joinInvite(moderatedToken), inviteId);
          expect(
            await controllers[0].open(),
            isTrue,
            reason: controllers[0].error,
          );
          expect(
            controllers[0].joinRequests[inviteId]!.single['status'],
            'pending',
          );
          expect(controllers[1].groups.any((g) => g.id == inviteId), isFalse);
          expect(
            await controllers[0].decideJoin(
              inviteId,
              bundles[1].deviceId,
              true,
            ),
            isTrue,
            reason: controllers[0].error,
          );
          expect(
            await controllers[1].open(),
            isTrue,
            reason: controllers[1].error,
          );
          expect(controllers[1].groups.any((g) => g.id == inviteId), isTrue);
          expect(controllers[1].messages[inviteId] ?? [], isEmpty);
          expect(controllers[1].groupPhoto(inviteId), photo);
          final sensitivePhoto = controllers[0].groupPhoto(inviteId)!;
          expect(await controllers[0].revokeInvites(inviteId), isTrue);
          expect(await controllers[1].previewInvite(moderatedToken), isNull);
          LoomAppLock.instance.locked = true;
          LoomAppLock.instance.notifyListeners();
          expect(sensitivePhoto.every((byte) => byte == 0), isTrue);
          for (final c in controllers) {
            expect(c.groupPhoto(inviteId), isNull);
            expect(c.ready, isFalse);
            expect(c.messages, isEmpty);
            expect(c.groups, isEmpty);
            expect(c.memberCachedAddress(carolMember), isNull);
            c.saveDraft(id, 'late keyboard event');
            expect(c.draft(id), isEmpty);
          }
        } finally {
          for (final c in controllers) {
            c.dispose();
          }
          for (final o in onboardings) {
            o.dispose();
            o.nodes.dispose();
          }
          LoomAppLock.instance.locked = false;
          node.stdin.writeln('stop');
          await node.stdin.flush();
          await node.exitCode.timeout(const Duration(seconds: 10));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          messenger.setMockMethodCallHandler(paths, null);
          await support.delete(recursive: true);
        }
      }, _RealHttp());
    },
    skip: library == null
        ? 'Set LOOM_TEST_MLS_LIBRARY to run the real native integration.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
