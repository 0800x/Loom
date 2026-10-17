import 'dart:async';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/people/application/people_controller.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:flutter_test/flutter_test.dart';

LoomDeviceRequestProofProvider _proof() => LoomDeviceRequestProofProvider(
  deviceId: 'dev_00000000-0000-4000-8000-000000000001',
  signer: (_) async => List<int>.filled(64, 0),
);

LoomResolvedUserSecurity _resolved({
  required String address,
  String identityId = 'chn:peer',
  String displayName = 'Peer',
}) => LoomResolvedUserSecurity(
  address: address,
  displayName: displayName,
  identityId: identityId,
  identityPublicKey: 'test-public-key',
  identityFingerprint: 'TEST FP',
  devices: const [],
);

void main() {
  test(
    'stale search and a disposed screen cannot replace current contacts',
    () async {
      final store = LoomContactStore.openInMemory();
      addTearDown(store.close);
      final first = Completer<LoomResolvedUserSecurity>();
      final second = Completer<LoomResolvedUserSecurity>();
      final started = Completer<void>();
      final controller = LoomPeopleController(
        homeNodeProvider: () => 'node-a.example',
        endpointProvider: () => Uri.parse('https://node-a.example'),
        accessTokenProvider: () async => 'token',
        deviceProofProvider: () async => _proof(),
        contactStore: store,
        resolver:
            ({
              required baseUri,
              required accessToken,
              required address,
              required deviceProofProvider,
            }) {
              if (address.contains('alice')) {
                started.complete();
                return first.future;
              }
              return second.future;
            },
      );
      await controller.open();
      final oldSearch = controller.search('alice');
      await started.future;
      final newSearch = controller.search('bob');
      second.complete(_resolved(address: '@bob:node-a.example'));
      await newSearch;
      first.complete(_resolved(address: '@alice:node-a.example'));
      await oldSearch;
      expect(controller.results.single.canonicalAddress, '@bob:node-a.example');
      controller.clearSearch();
      expect(controller.results, isEmpty);
      controller.dispose();
      await controller.search('unused');
    },
  );

  test(
    'bare username resolves on own Home Node and can persist as contact',
    () async {
      final store = LoomContactStore.openInMemory();
      final seen = <String>[];
      final controller = LoomPeopleController(
        homeNodeProvider: () => 'node-a.example',
        endpointProvider: () => Uri.parse('https://node-a.example'),
        accessTokenProvider: () async => 'token',
        deviceProofProvider: () async => _proof(),
        contactStore: store,
        resolver:
            ({
              required baseUri,
              required accessToken,
              required address,
              required deviceProofProvider,
            }) async {
              seen.add(address);
              return _resolved(address: address, displayName: 'Alice');
            },
      );
      addTearDown(controller.dispose);
      addTearDown(store.close);

      await controller.open();
      await controller.search('alice');

      expect(seen.single, '@alice:node-a.example');
      expect(controller.state, LoomPeopleState.ready);
      expect(controller.results.single.sameNode, isTrue);
      expect(controller.addContact(controller.results.single), isTrue);
      expect(
        controller.contacts.single.canonicalAddress,
        '@alice:node-a.example',
      );
      expect(controller.contacts.single.accountId, isNull);
    },
  );

  test(
    'username@remote-node resolves federation-aware canonical address',
    () async {
      final store = LoomContactStore.openInMemory();
      String? resolvedAddress;
      final controller = LoomPeopleController(
        homeNodeProvider: () => 'node-a.example',
        endpointProvider: () => Uri.parse('https://node-a.example'),
        accessTokenProvider: () async => 'token',
        deviceProofProvider: () async => _proof(),
        contactStore: store,
        resolver:
            ({
              required baseUri,
              required accessToken,
              required address,
              required deviceProofProvider,
            }) async {
              resolvedAddress = address;
              return _resolved(address: address);
            },
      );
      addTearDown(controller.dispose);
      addTearDown(store.close);

      await controller.open();
      await controller.search('alice@node-b.example');

      expect(resolvedAddress, '@alice:node-b.example');
      expect(controller.results.single.sameNode, isFalse);
      expect(controller.results.single.homeNode, 'node-b.example');
    },
  );

  test(
    'not found becomes an empty result instead of fake people data',
    () async {
      final store = LoomContactStore.openInMemory();
      final controller = LoomPeopleController(
        homeNodeProvider: () => 'node-a.example',
        endpointProvider: () => Uri.parse('https://node-a.example'),
        accessTokenProvider: () async => 'token',
        deviceProofProvider: () async => _proof(),
        contactStore: store,
        resolver:
            ({
              required baseUri,
              required accessToken,
              required address,
              required deviceProofProvider,
            }) async => throw const LoomProtocolException('user_not_found'),
      );
      addTearDown(controller.dispose);
      addTearDown(store.close);

      await controller.open();
      await controller.search('nobody');

      expect(controller.state, LoomPeopleState.empty);
      expect(controller.results, isEmpty);
      expect(controller.errorMessage, isNull);
    },
  );

  test('node failure is surfaced and no static result is injected', () async {
    final store = LoomContactStore.openInMemory();
    final controller = LoomPeopleController(
      homeNodeProvider: () => 'node-a.example',
      endpointProvider: () => Uri.parse('https://node-a.example'),
      accessTokenProvider: () async => 'token',
      deviceProofProvider: () async => _proof(),
      contactStore: store,
      resolver:
          ({
            required baseUri,
            required accessToken,
            required address,
            required deviceProofProvider,
          }) async => throw const LoomProtocolException(
            'federation_user_lookup_http_503',
          ),
    );
    addTearDown(controller.dispose);
    addTearDown(store.close);

    await controller.open();
    await controller.search('alice@node-b.example');

    expect(controller.state, LoomPeopleState.error);
    expect(controller.results, isEmpty);
    expect(controller.errorMessage, contains('could not be reached'));
  });

  test('saved contact blocks silent identity replacement', () async {
    final store = LoomContactStore.openInMemory();
    final now = DateTime.utc(2026, 9, 4);
    store.upsert(
      LoomContact(
        identityId: 'chn:old',
        username: 'alice',
        displayName: 'Alice',
        canonicalAddress: '@alice:node-b.example',
        homeNode: 'node-b.example',
        securityState: LoomContactSecurityState.resolved,
        createdAt: now,
        updatedAt: now,
        lastResolvedAt: now,
      ),
    );
    final controller = LoomPeopleController(
      homeNodeProvider: () => 'node-a.example',
      endpointProvider: () => Uri.parse('https://node-a.example'),
      accessTokenProvider: () async => 'token',
      deviceProofProvider: () async => _proof(),
      contactStore: store,
      resolver:
          ({
            required baseUri,
            required accessToken,
            required address,
            required deviceProofProvider,
          }) async => _resolved(address: address, identityId: 'chn:new'),
    );
    addTearDown(controller.dispose);
    addTearDown(store.close);

    await controller.open();
    await controller.search('alice@node-b.example');

    expect(
      controller.results.single.securityState,
      LoomContactSecurityState.changed,
    );
    expect(controller.addContact(controller.results.single), isFalse);
    expect(store.findByAddress('@alice:node-b.example')!.identityId, 'chn:old');
  });

  test(
    'add is idempotent, survives reopen and rejects stale identity at save time',
    () async {
      final dir = Directory.systemTemp.createTempSync('loom_contacts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/contacts.sqlite3';
      var store = LoomContactStore.openFile(path);
      final controller = LoomPeopleController(
        homeNodeProvider: () => 'node-a.example',
        endpointProvider: () => Uri.parse('https://node-a.example'),
        accessTokenProvider: () async => 'token',
        deviceProofProvider: () async => _proof(),
        contactStore: store,
        resolver:
            ({
              required baseUri,
              required accessToken,
              required address,
              required deviceProofProvider,
            }) async => _resolved(address: address, identityId: 'chn:old'),
      );
      await controller.open();
      await controller.search('alice');
      final result = controller.results.single;
      expect(controller.addContact(result), isTrue);
      expect(controller.addContact(result), isTrue);
      expect(controller.contacts, hasLength(1));
      final original = store.findByAddress(result.canonicalAddress)!;
      // A save in another surface happens after this result was resolved.
      store.upsert(
        LoomContact(
          identityId: 'chn:verified-new',
          username: original.username,
          displayName: original.displayName,
          canonicalAddress: original.canonicalAddress,
          homeNode: original.homeNode,
          securityState: original.securityState,
          createdAt: original.createdAt,
          updatedAt: original.updatedAt,
          lastResolvedAt: original.lastResolvedAt,
        ),
      );
      expect(controller.addContact(result), isFalse);
      controller.dispose();
      store.close();
      store = LoomContactStore.openFile(path);
      expect(
        store.findByAddress(result.canonicalAddress)!.identityId,
        'chn:verified-new',
      );
      store.close();
    },
  );

  test('storage failure produces a retryable UI error', () async {
    final store = LoomContactStore.openInMemory();
    final controller = LoomPeopleController(
      homeNodeProvider: () => 'node-a.example',
      endpointProvider: () => Uri.parse('https://node-a.example'),
      accessTokenProvider: () async => 'token',
      deviceProofProvider: () async => _proof(),
      contactStore: store,
      resolver:
          ({
            required baseUri,
            required accessToken,
            required address,
            required deviceProofProvider,
          }) async => _resolved(address: address),
    );
    addTearDown(controller.dispose);
    await controller.open();
    await controller.search('alice');
    store.close();
    expect(controller.addContact(controller.results.single), isFalse);
    expect(controller.state, LoomPeopleState.error);
    expect(controller.errorMessage, contains('could not be saved'));
  });
}
