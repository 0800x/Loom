import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

import '../../loom_crypto_bridge/lib/src/native_mls_core.dart';

class LostAckClient extends LoomGroupClient {
  LostAckClient({
    required super.baseUri,
    required super.accessTokenProvider,
    required super.deviceProof,
  });
  bool loseNextReceipt = false;
  Future<void> Function()? beforeCommit;
  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    if (path.endsWith('/commits') && beforeCommit != null) {
      final action = beforeCommit!;
      beforeCommit = null;
      await action();
    }
    final response = await super.request(method, path, body);
    if (loseNextReceipt && path.endsWith('/messages')) {
      loseNextReceipt = false;
      throw const SocketException(
        'Simulated lost receipt after durable acceptance',
      );
    }
    return response;
  }
}

void main() {
  final library = Platform.environment['LOOM_TEST_MLS_LIBRARY'];
  test(
    'real native MLS + signed Node API: invitation, messaging, restart and removal',
    () async {
      final node = await Process.start(
        'node',
        [
          '--experimental-strip-types',
          File('../../services/loom_server/test/helpers/mls_http_fixture.ts')
              .absolute
              .path,
        ],
        environment: {'NODE_NO_WARNINGS': '1'},
      );
      final stderr = <String>[];
      node.stderr.transform(utf8.decoder).listen(stderr.add);
      addTearDown(() async {
        node.stdin.writeln('stop');
        await node.stdin.flush();
        await node.exitCode.timeout(const Duration(seconds: 10));
      });
      final output = await node.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final config = jsonDecode(output) as Map,
          fixtures = config['fixtures'] as List;
      final bundles = fixtures
          .map(
            (f) => LoomDeviceKeyBundle.fromJson(
              Map<String, Object?>.from(f['bundle'] as Map),
            ),
          )
          .toList();
      // Pin the generated account roots independently of the delivery responses.
      for (var i = 0; i < bundles.length; i++)
        await LoomDeviceBundleVerifier().verify(
          bundle: bundles[i],
          identityId: bundles[i].identityId,
          identityPublicKey: fixtures[i]['identityPublicKey'] as String,
        );
      final directory = await Directory.systemTemp.createTemp(
        'loom-group-client-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final stores = <LoomGroupStore>[],
          clients = <LoomGroupClient>[],
          sessions = <LoomGroupSession>[];
      final cipher = AesGcm.with256bits(),
          key = SecretKey(List<int>.filled(32, 11));
      Future<String> seal(String groupId, Map<String, Object?> plain) async {
        final box = await cipher.encrypt(
          utf8.encode(jsonEncode(plain)),
          secretKey: key,
          aad: utf8.encode(groupId),
        );
        return base64Encode([
          ...box.nonce,
          ...box.cipherText,
          ...box.mac.bytes,
        ]);
      }

      Future<Map<String, Object?>> open(String groupId, String payload) async {
        final b = base64Decode(payload);
        final plain = await cipher.decrypt(
          SecretBox(
            b.sublist(12, b.length - 16),
            nonce: b.sublist(0, 12),
            mac: Mac(b.sublist(b.length - 16)),
          ),
          secretKey: key,
          aad: utf8.encode(groupId),
        );
        return Map<String, Object?>.from(jsonDecode(utf8.decode(plain)) as Map);
      }

      LoomGroupSession session(int i, LoomGroupStore store) {
        final native = LoomNativeMlsCore(libraryPath: library),
            receipt = fixtures[i]['receipt'] as Map;
        return LoomGroupSession(
          accountId: receipt['accountId'] as String,
          identityId: bundles[i].identityId,
          deviceId: bundles[i].deviceId,
          client: clients[i],
          store: store,
          unlocked: () => true,
          trustedDevice: (member) async =>
              bundles.singleWhere((b) => b.deviceId == member.deviceId),
          sealHistory: seal,
          crypto:
              ({
                required operation,
                required state,
                groupId,
                required arguments,
              }) async {
                final result = await native.execute(
                  deviceId: bundles[i].deviceId,
                  sealingKey: List<int>.filled(32, i + 1),
                  operation: operation,
                  state: state,
                  groupId: groupId,
                  arguments: arguments,
                );
                return (state: result.state, result: result.result);
              },
        );
      }

      for (var i = 0; i < fixtures.length; i++) {
        final fixture = fixtures[i] as Map, receipt = fixture['receipt'] as Map;
        final seed = base64Decode(fixture['signingSeed'] as String),
            public = base64Decode(bundles[i].signingPublicKey);
        final signingKey = SimpleKeyPairData(
          seed,
          type: KeyPairType.ed25519,
          publicKey: SimplePublicKey(public, type: KeyPairType.ed25519),
        );
        clients.add(
          LostAckClient(
            baseUri: Uri.parse(config['baseUri'] as String),
            accessTokenProvider: () async => receipt['accessToken'] as String,
            deviceProof: LoomDeviceRequestProofProvider(
              deviceId: bundles[i].deviceId,
              signer: (bytes) async =>
                  (await Ed25519().sign(bytes, keyPair: signingKey)).bytes,
            ),
          ),
        );
        stores.add(
          LoomGroupStore.openFile('${directory.path}/device-$i.sqlite'),
        );
        sessions.add(session(i, stores[i]));
        await sessions[i].initialize();
        await sessions[i].publishCredential();
        await sessions[i].publishKeyPackage();
      }
      addTearDown(() {
        for (final s in sessions) s.close();
        for (final c in clients) c.close();
        for (final s in stores) s.close();
      });
      final owner = await sessions[0].ownMember(),
          bob = await clients[0].credential(bundles[1].deviceId),
          carol = await clients[0].credential(bundles[2].deviceId);
      final selected = [owner, bob];
      final creation = sessions[0].create(title: 'Friends', members: selected);
      selected.add(carol);
      final id = await creation;
      expect(stores[0].groups.single.members.length, 2);
      await sessions[1].sync();
      expect(stores[1].groups.single.epoch, 1);
      const room = '12345678-1234-1234-1234-123456789abc';
      final aliceCallKey = await sessions[0].exportCallKey(id, room, 1);
      final bobCallKey = await sessions[1].exportCallKey(id, room, 1);
      expect(aliceCallKey, bobCallKey);
      expect(aliceCallKey.length, 32);
      final otherRoom = await sessions[0].exportCallKey(
        id,
        '12345678-1234-1234-1234-123456789abd',
        1,
      );
      expect(otherRoom, isNot(aliceCallKey));
      await expectLater(
        sessions[1].exportCallKey(id, room, 2),
        throwsStateError,
      );
      await sessions[0].send(id, {'text': 'hello'});
      await sessions[0].sync();
      await sessions[1].sync();
      expect(
        (await open(id, stores[1].history(id).single.payload))['content'],
        {'text': 'hello'},
      );
      final mutable = <String, Object?>{'text': 'immutable snapshot'};
      final send = sessions[0].send(id, mutable);
      mutable['text'] = 'changed after send';
      await send;
      await sessions[0].sync();
      await sessions[1].sync();
      expect((await open(id, stores[1].history(id).last.payload))['content'], {
        'text': 'immutable snapshot',
      });
      (clients[0] as LostAckClient).loseNextReceipt = true;
      await expectLater(
        sessions[0].send(id, {'text': 'lost receipt'}),
        throwsA(isA<SocketException>()),
      );
      final exact = Map<String, Object?>.of(stores[0].outbox.single.body),
          generation = stores[0].state!.generation;
      sessions[0].close();
      stores[0].close();
      stores[0] = LoomGroupStore.openFile('${directory.path}/device-0.sqlite');
      sessions[0] = session(0, stores[0]);
      expect(stores[0].outbox.single.body, exact);
      await sessions[0].drain();
      expect(stores[0].state!.generation, generation);
      expect(stores[0].outbox, isEmpty);
      await sessions[0].sync();
      await sessions[1].sync();
      expect(stores[1].history(id).length, 3);
      // Reopen SQLite and rebuild the stateless native bridge with its sealed state.
      sessions[1].close();
      stores[1].close();
      stores[1] = LoomGroupStore.openFile('${directory.path}/device-1.sqlite');
      sessions[1] = session(1, stores[1]);
      await sessions[1].send(id, {'text': 'after restart'});
      await sessions[0].sync();
      (clients[0] as LostAckClient).beforeCommit = () =>
          sessions[1].send(id, {'text': 'during commit'});
      await sessions[0].update(
        groupId: id,
        title: 'Friends',
        members: [owner, bob, carol],
      );
      await sessions[0].sync();
      await sessions[1].sync();
      await sessions[2].sync();
      expect(stores[2].groups.single.epoch, 2);
      await sessions[0].update(
        groupId: id,
        title: 'Friends',
        members: [owner, carol],
      );
      await sessions[0].sync();
      await sessions[1].sync();
      await sessions[2].sync();
      await expectLater(
        sessions[1].send(id, {'text': 'not allowed'}),
        throwsStateError,
      );
      await expectLater(
        sessions[1].exportCallKey(id, room, 3),
        throwsStateError,
      );
      final currentCallKey = await sessions[0].exportCallKey(id, room, 3);
      expect(currentCallKey, isNot(aliceCallKey));
      for (final key in [aliceCallKey, bobCallKey, otherRoom, currentCallKey]) {
        key.fillRange(0, key.length, 0);
      }
      await sessions[0].send(id, {'text': 'after removal'});
      await sessions[2].sync();
      expect(
        (await open(id, stores[2].history(id).single.payload))['content'],
        {'text': 'after removal'},
      );
      // Profiles use the real MLS/application and encrypted history path.
      final photo = LoomGroupProfile.fromJson({
        'v': 1,
        'png': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZbkAAAAASUVORK5CYII=',
      });
      (clients[0] as LostAckClient).loseNextReceipt = true;
      await expectLater(
        sessions[0].send(id, {'groupProfile': photo.toJson()}),
        throwsA(isA<SocketException>()),
      );
      expect(stores[0].outbox.length, 1);
      await sessions[0].sync();
      expect(stores[0].outbox, isEmpty);
      await sessions[2].sync();
      final delivered = await open(id, stores[2].history(id).last.payload);
      expect(delivered['profileEvent'], true);
      expect(delivered['profileEpoch'], 3);
      expect((delivered['content'] as Map)['groupProfile'], photo.toJson());
      expect(
        stores[2].history(id).last.payload.contains(photo.png!),
        false,
        reason: 'Plain image must never enter SQLite history',
      );
      await expectLater(
        sessions[2].send(id, {'groupProfile': photo.toJson()}),
        throwsStateError,
      );
      // A malicious authenticated ordinary member can craft MLS ciphertext even
      // when the production sender rejects it. Receive must consume but ignore it.
      final forged = await sessions[2].crypto(
        operation: 'encrypt',
        state: stores[2].state,
        groupId: id,
        arguments: {
          'bytes': utf8.encode(jsonEncode({'groupProfile': photo.toJson()})),
        },
      );
      stores[2].saveState(stores[2].version, forged.state);
      await clients[2].request('POST', '/api/v1/groups/$id/messages', {
        'operationId': 'mls_${List.filled(48, 'a').join()}',
        'epoch': forged.result['epoch'],
        'ciphertext': base64Encode(
          (forged.result['bytes'] as List).cast<int>(),
        ),
      });
      await sessions[0].sync();
      final ignored = await open(id, stores[0].history(id).last.payload);
      expect(ignored['profileEvent'], true);
      expect((ignored['content'] as Map).containsKey('groupProfile'), false);
      await sessions[0].send(id, {
        'groupProfile': const LoomGroupProfile().toJson(),
      });
      expect(stderr.where((s) => s.contains('request failed')), isEmpty);
    },
    skip: library == null
        ? 'Set LOOM_TEST_MLS_LIBRARY to the compiled native library'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
