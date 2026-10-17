import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:cryptography/cryptography.dart';

/// Adapter for the native core. No Dart MLS primitives or fallback encryption.
typedef LoomGroupCryptoRunner =
    Future<({LoomMlsSealedState state, Map<String, Object?> result})> Function({
      required String operation,
      required LoomMlsSealedState? state,
      String? groupId,
      required Map<String, Object?> arguments,
    });
typedef LoomGroupTrustedDeviceResolver = Future<LoomDeviceKeyBundle> Function(
  LoomGroupMember member,
);
typedef LoomGroupHistorySealer = Future<String> Function(
  String groupId,
  Map<String, Object?> plaintext,
);

/// Device-wide serialization matters: every group shares the native key-package
/// store. Durable CAS remains the authority if a second coordinator is opened.
/// The caller MUST resolve trusted account roots, enforce App Lock and encrypt
/// local history. The resolver establishes first-use account trust separately
/// through the verified directory; invitation certificates alone create no trust.
class LoomGroupSession {
  LoomGroupSession({
    required this.accountId,
    required this.identityId,
    required this.deviceId,
    required this.client,
    required this.store,
    required this.crypto,
    required this.trustedDevice,
    required this.sealHistory,
    required this.unlocked,
  });
  final String accountId, identityId, deviceId;
  final LoomGroupClient client;
  final LoomGroupStore store;
  final LoomGroupCryptoRunner crypto;
  final LoomGroupTrustedDeviceResolver trustedDevice;
  final LoomGroupHistorySealer sealHistory;
  final bool Function() unlocked;
  Future<void> _tail = Future.value();
  final Random _random = Random.secure();
  bool _closed = false;
  void close() {
    _closed = true;
  }

  void _guard() {
    if (_closed || !unlocked())
      throw StateError('Group session is locked or closed');
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) {
      _guard();
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<({LoomMlsSealedState state, Map<String, Object?> result})> _run(
    String operation, {
    LoomMlsSealedState? state,
    String? groupId,
    Map<String, Object?> arguments = const {},
  }) async {
    _guard();
    final result = await crypto(
      operation: operation,
      state: state ?? store.state,
      groupId: groupId,
      arguments: arguments,
    );
    _guard();
    return result;
  }

  String _id() =>
      'mls_${List<int>.generate(24, (_) => _random.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  String _path(String id) => '/api/v1/groups/${Uri.encodeComponent(id)}';
  void _idle() {
    if (store.outbox.isNotEmpty)
      throw StateError('Finish pending group delivery first');
  }

  void _metadata(String title, List<LoomGroupMember> members) {
    if (title.trim().isEmpty || title.length > 100)
      throw ArgumentError('Group title must be 1..100 characters');
    LoomGroupState.fromJson({
      'id': 'validation',
      'title': title.trim(),
      'epoch': 1,
      'revision': 1,
      'sequence': 1,
      'members': members.map((m) => m.toJson()).toList(),
    });
  }

  Future<void> _verifyRoster(LoomGroupState state) async {
    if (state.members.map((m) => m.deviceId).toSet().length !=
        state.members.length)
      throw StateError('Duplicate group device');
    for (final member in state.members)
      await verifyLoomGroupMember(member, await trustedDevice(member));
    _guard();
  }

  Future<void> _verifyPackage(
    LoomGroupMember member,
    Map<String, Object?> package,
  ) async {
    if (package['deviceId'] != member.deviceId ||
        package['identityId'] != member.identityId ||
        package['accountId'] != member.accountId)
      throw StateError('Key package device mismatch');
    final expiry = DateTime.parse(package['expiresAt'] as String);
    if (!expiry.isAfter(DateTime.now().toUtc()))
      throw StateError('Key package expired');
    final device = await trustedDevice(member);
    await verifyLoomGroupMember(member, device);
    final binding = await loomKeyPackageBinding(
      identityId: member.identityId,
      deviceId: member.deviceId,
      id: package['id'] as String,
      serialized: base64Decode(package['serialized'] as String),
      expiresAt: package['expiresAt'] as String,
    );
    if (!await Ed25519().verify(
      binding,
      signature: Signature(
        base64Decode(package['signature'] as String),
        publicKey: SimplePublicKey(
          base64Decode(device.signingPublicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    ))
      throw StateError('Untrusted key package');
  }

  Future<void> initialize() => _serialized(() async {
    if (store.state == null) {
      final version = store.version, created = await _run('new');
      store.saveState(version, created.state);
    }
  });
  Future<LoomGroupMember> ownMember({String role = 'owner'}) =>
      _serialized(() => _ownMember(role));
  Future<LoomGroupMember> _ownMember(String role) async {
    _idle();
    if (store.state == null) throw StateError('Initialize MLS first');
    final version = store.version, result = await _run('pin');
    final pin = Map<String, Object?>.from(result.result['pin'] as Map);
    final key = base64Encode((pin['signature_key'] as List).cast<int>());
    final binding = utf8.encode(
      jsonEncode({
        'protocol': 'Loom-MLSDevice-v1',
        'identityId': identityId,
        'deviceId': deviceId,
        'mlsSignatureKey': key,
      }),
    );
    final signature = await client.deviceProof.signer(binding);
    _guard();
    final member = LoomGroupMember(
      accountId: accountId,
      deviceId: deviceId,
      identityId: identityId,
      role: role,
      mlsSignatureKey: key,
      mlsSignature: base64Encode(signature),
    );
    store.saveState(version, result.state);
    return member;
  }

  Future<void> publishCredential() => _serialized(() async {
    final member = await _ownMember('member');
    await client.publishCredential(member);
    _guard();
  });

  /// Keep single-use invitations available without resetting the native store.
  Future<void> ensureKeyPackages({int minimum = 5}) async {
    if (minimum < 1 || minimum > 10) {
      throw ArgumentError('Invalid key package pool size');
    }
    _guard();
    final available = await client.availableKeyPackages();
    _guard();
    for (var i = available; i < minimum; i++) {
      await publishKeyPackage();
    }
  }

  Future<void> publishKeyPackage() => _serialized(() async {
    _idle();
    final version = store.version, result = await _run('keyPackage');
    final bytes = (result.result['bytes'] as List).cast<int>(), id = _id();
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch + 7 * 86400000,
      isUtc: true,
    ).toIso8601String();
    final binding = await loomKeyPackageBinding(
      identityId: identityId,
      deviceId: deviceId,
      id: id,
      serialized: bytes,
      expiresAt: expiresAt,
    );
    final signature = await client.deviceProof.signer(binding);
    _guard();
    store.stage(
      version,
      result.state,
      LoomGroupOutbox(
        id: id,
        groupId: 'key-packages',
        path: '/api/v1/groups/key-packages',
        body: {
          'id': id,
          'serialized': base64Encode(bytes),
          'expiresAt': expiresAt,
          'signature': base64Encode(signature),
        },
        checkpoint: null,
        localPayload: null,
      ),
    );
    await _drain();
  });
  Future<List<Object>> _packages(
    List<LoomGroupMember> added,
    Map<String, String> claims,
  ) async {
    final packages = <Object>[];
    for (final member in added) {
      final claimed = await client.claim(member.deviceId);
      await _verifyPackage(member, claimed);
      claims[member.deviceId] = claimed['claimId'] as String;
      packages.add([
        base64Decode(claimed['serialized'] as String).toList(),
        member.nativePin,
      ]);
    }
    return packages;
  }

  Future<String> create({
    required String title,
    required List<LoomGroupMember> members,
  }) {
    members = List<LoomGroupMember>.unmodifiable(members);
    return _serialized(() async {
      _idle();
      _metadata(title, members);
      if (members.isEmpty ||
          !members.any(
            (m) =>
                m.deviceId == deviceId &&
                m.accountId == accountId &&
                m.role == 'owner',
          ))
        throw ArgumentError('The creator must be an owner');
      final groupId = _id(),
          operationId = _id(),
          version = store.version,
          checkpoint = store.state;
      final claims = <String, String>{},
          added = members.where((m) => m.deviceId != deviceId).toList();
      final packages = await _packages(added, claims);
      final created = await _run('create', groupId: groupId);
      final result = await _run(
        added.isEmpty ? 'rotate' : 'add',
        state: created.state,
        groupId: groupId,
        arguments: {'packages': packages},
      );
      final welcome = added.isEmpty
          ? null
          : base64Encode((result.result['welcome'] as List).cast<int>());
      final body = <String, Object?>{
        'operationId': operationId,
        'title': title.trim(),
        'epoch': result.result['epoch'],
        'members': members.map((m) => m.toJson()).toList(),
        'commit': base64Encode((result.result['commit'] as List).cast<int>()),
        'welcomes': {for (final m in added) m.deviceId: welcome},
        'claims': claims,
      };
      store.stage(
        version,
        result.state,
        LoomGroupOutbox(
          id: operationId,
          groupId: groupId,
          path: _path(groupId),
          body: body,
          checkpoint: checkpoint,
          localPayload: null,
        ),
      );
      await _drain();
      return groupId;
    });
  }

  /// One membership operation per epoch. Role/title changes rotate the epoch too.
  Future<void> update({
    required String groupId,
    required String title,
    required List<LoomGroupMember> members,
    String? joinRequestDeviceId,
  }) {
    members = List<LoomGroupMember>.unmodifiable(members);
    return _serialized(() async {
      _idle();
      _metadata(title, members);
      await _syncGroup(groupId);
      final old = store.groups.singleWhere((g) => g.id == groupId);
      final fresh = await client.get(groupId);
      if (fresh.sequence != store.cursor(groupId) ||
          fresh.revision != old.revision)
        throw StateError('Group changed; synchronize before editing');
      final actor = old.members.singleWhere((m) => m.deviceId == deviceId);
      if (actor.role == 'member')
        throw StateError('Group administrator required');
      final added = members
          .where((m) => !old.members.any((o) => o.deviceId == m.deviceId))
          .toList();
      final removed = old.members
          .where((m) => !members.any((n) => n.deviceId == m.deviceId))
          .toList();
      if (added.isNotEmpty && removed.isNotEmpty)
        throw ArgumentError('Add and remove in separate epochs');
      if (removed.any((m) => m.deviceId == deviceId))
        throw StateError('Transfer ownership and request leave');
      final claims = <String, String>{},
          version = store.version,
          checkpoint = store.state,
          operationId = _id();
      final packages = await _packages(added, claims);
      final result = await _run(
        added.isNotEmpty
            ? 'add'
            : removed.isNotEmpty
            ? 'remove'
            : 'rotate',
        groupId: groupId,
        arguments: added.isNotEmpty
            ? {'packages': packages}
            : removed.isNotEmpty
            ? {'remove': removed.map((m) => utf8.encode(m.deviceId)).toList()}
            : {},
      );
      final welcome = result.result['welcome'] == null
          ? null
          : base64Encode((result.result['welcome'] as List).cast<int>());
      final body = <String, Object?>{
        'operationId': operationId,
        if (joinRequestDeviceId != null)
          'joinRequestDeviceId': joinRequestDeviceId,
        'expectedRevision': old.revision,
        'title': title.trim(),
        'epoch': result.result['epoch'],
        'members': members.map((m) => m.toJson()).toList(),
        'commit': base64Encode((result.result['commit'] as List).cast<int>()),
        'welcomes': {for (final m in added) m.deviceId: welcome},
        'claims': claims,
      };
      store.stage(
        version,
        result.state,
        LoomGroupOutbox(
          id: operationId,
          groupId: groupId,
          path: '${_path(groupId)}/commits',
          body: body,
          checkpoint: checkpoint,
          localPayload: null,
        ),
      );
      await _drain();
    });
  }

  Future<Uint8List> exportCallKey(String groupId, String callId, int epoch) =>
      _serialized(() async {
        if (!RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
        ).hasMatch(callId)) {
          throw ArgumentError('Invalid call ID');
        }
        _idle();
        await _syncGroup(groupId);
        _idle();
        final group = store.groups.singleWhere((g) => g.id == groupId);
        if (group.epoch != epoch ||
            !group.members.any(
              (m) => m.deviceId == deviceId && m.accountId == accountId,
            )) {
          throw StateError('Group call epoch changed');
        }
        final version = store.version;
        final output = await _run(
          'exportCallKey',
          groupId: groupId,
          arguments: {
            'bytes': utf8.encode('Loom-GroupCall-v1:$callId'),
            'epoch': epoch,
          },
        );
        final bytes = output.result['bytes'] as List;
        if (bytes.length != 32 ||
            bytes.any((b) => b is! int || b < 0 || b > 255)) {
          throw StateError('Invalid group call key');
        }
        final key = Uint8List.fromList(bytes.cast<int>());
        try {
          bytes.fillRange(0, bytes.length, 0);
          _guard();
          store.saveState(version, output.state);
          return key;
        } catch (_) {
          key.fillRange(0, key.length, 0);
          rethrow;
        }
      });

  Future<void> send(String groupId, Map<String, Object?> content) {
    content = Map<String, Object?>.from(jsonDecode(jsonEncode(content)) as Map);
    return _serialized(() async {
      _idle();
      final group = store.groups.singleWhere((g) => g.id == groupId);
      if (!group.members.any((m) => m.deviceId == deviceId))
        throw StateError('No longer a group member');
      final profileEvent = content.containsKey('groupProfile');
      if (profileEvent) {
        final actor = group.members.singleWhere((m) => m.deviceId == deviceId);
        if (actor.role == 'member')
          throw StateError('Group administrator required');
        if (content.length != 1 || content['groupProfile'] is! Map) {
          throw const FormatException('Invalid group profile event');
        }
        content = {
          'groupProfile': LoomGroupProfile.fromJson(
            Map<String, Object?>.from(content['groupProfile'] as Map),
          ).toJson(),
        };
      }
      final version = store.version, operationId = _id();
      final result = await _run(
        'encrypt',
        groupId: groupId,
        arguments: {'bytes': utf8.encode(jsonEncode(content))},
      );
      final localPayload = await sealHistory(groupId, {
        'operationId': operationId,
        'senderDeviceId': deviceId,
        'receivedAt': DateTime.now().toUtc().toIso8601String(),
        'content': content,
        if (profileEvent) 'profileEvent': true,
        if (profileEvent) 'profileEpoch': group.epoch,
      });
      _guard();
      store.stage(
        version,
        result.state,
        LoomGroupOutbox(
          id: operationId,
          groupId: groupId,
          path: '${_path(groupId)}/messages',
          body: {
            'operationId': operationId,
            'epoch': result.result['epoch'],
            'ciphertext': base64Encode(
              (result.result['bytes'] as List).cast<int>(),
            ),
          },
          checkpoint: null,
          localPayload: localPayload,
        ),
      );
      await _drain();
    });
  }

  Future<void> drain() => _serialized(_drain);
  Future<void> _drain() async {
    for (final pending in store.outbox) {
      _guard();
      Map<String, Object?> receipt;
      try {
        receipt = await client.request('POST', pending.path, pending.body);
      } on LoomGroupProtocolException catch (e) {
        if (e.status == 409 &&
            e.code == 'group_epoch_conflict' &&
            pending.checkpoint != null) {
          _guard();
          store.rejectCommit(pending.id, store.version);
        }
        if (e.status == 409 &&
            e.code == 'group_epoch_conflict' &&
            pending.path.endsWith('/messages')) {
          _guard();
          store.rejectMessage(pending.id);
        }
        rethrow;
      }
      _guard();
      if (pending.groupId == 'key-packages') {
        if (receipt['id'] != pending.id)
          throw StateError('Key package receipt mismatch');
        store.acknowledge(pending.id);
        continue;
      }
      if (pending.path.endsWith('/messages')) {
        if (receipt['operationId'] != pending.id ||
            receipt['groupId'] != pending.groupId ||
            receipt['epoch'] != pending.body['epoch'])
          throw StateError('Message receipt mismatch');
        store.acknowledge(pending.id, sequence: receipt['sequence'] as int);
        continue;
      }
      final group = LoomGroupState.fromJson(receipt);
      await _verifyRoster(group);
      final wanted =
          (pending.body['members'] as List)
              .map((m) => Map<String, Object?>.from(m as Map))
              .toList()
            ..sort(
              (a, b) =>
                  (a['deviceId'] as String).compareTo(b['deviceId'] as String),
            );
      if (group.id != pending.groupId ||
          group.title != pending.body['title'] ||
          group.epoch != pending.body['epoch'] ||
          jsonEncode(group.members.map((m) => m.toJson()).toList()) !=
              jsonEncode(wanted))
        throw StateError('Group receipt mismatch');
      final version = store.version,
          result = await _run(
            'acceptPending',
            groupId: group.id,
            arguments: {'pins': group.nativePins},
          );
      store.acknowledge(
        pending.id,
        next: result.state,
        expectedVersion: version,
        group: group,
      );
    }
  }

  Future<void> sync() => _serialized(() async {
    await _drain();
    for (final groupId in await client.list()) await _syncGroup(groupId);
  });
  Future<void> _syncGroup(String groupId) async {
    var more = true;
    while (more) {
      final page = await client.inbox(groupId, store.cursor(groupId));
      for (final raw in page['events'] as List)
        await _apply(groupId, Map<String, Object?>.from(raw as Map));
      more = page['hasMore'] == true;
      if (more && (page['events'] as List).isEmpty)
        throw StateError('Empty group sync page');
    }
  }

  Future<void> _apply(String groupId, Map<String, Object?> event) async {
    _guard();
    final sequence = event['sequence'] as int;
    if (event['groupId'] != groupId || sequence <= store.cursor(groupId))
      throw StateError('Invalid group event sequence');
    final previous = store.groups.where((g) => g.id == groupId).firstOrNull;
    final state = event['state'] == null
        ? previous
        : LoomGroupState.fromJson(
            Map<String, Object?>.from(event['state'] as Map),
          );
    if (state == null || state.id != groupId)
      throw StateError('Missing group epoch');
    if (previous != null && sequence != store.cursor(groupId) + 1)
      throw StateError('Group event gap');
    final own = store.isOwnOperation(
      groupId,
      sequence,
      event['operationId'] as String?,
    );
    if (own) {
      final expected = store.ownCommitState(groupId, sequence);
      if (expected != null &&
          jsonEncode(expected.toJson()) != jsonEncode(state.toJson()))
        throw StateError('Own commit echo mismatch');
      store.acknowledgeEcho(state, sequence);
      return;
    }
    final kind = event['kind'] as String;
    await _verifyRoster(state);
    if (kind == 'welcome' && previous != null)
      throw StateError('Unexpected repeated Welcome');
    if (kind == 'commit' &&
        (previous == null ||
            state.epoch != previous.epoch + 1 ||
            state.revision != previous.revision + 1))
      throw StateError('Group commit epoch gap');
    if (kind == 'message' &&
        (previous == null || event['epoch'] != previous.epoch))
      throw StateError('Group message epoch gap');
    final bytes = base64Decode(
      event[kind == 'welcome'
              ? 'welcome'
              : kind == 'commit'
              ? 'commit'
              : 'ciphertext']
          as String,
    );
    final version = store.version,
        result = await _run(
          kind == 'welcome' ? 'join' : 'receive',
          groupId: groupId,
          arguments: {'bytes': bytes.toList(), 'pins': state.nativePins},
        );
    String? encrypted;
    if (kind == 'message') {
      final application = Map<String, Object?>.from(
        result.result['Application'] as Map,
      );
      final sender = utf8.decode((application['sender'] as List).cast<int>());
      if (sender != event['senderDeviceId'] ||
          !state.members.any(
            (m) =>
                m.deviceId == sender && m.accountId == event['senderAccountId'],
          ))
        throw StateError('MLS sender mismatch');
      final content = Map<String, Object?>.from(
        jsonDecode(utf8.decode((application['plaintext'] as List).cast<int>()))
            as Map,
      );
      final profileEvent = content.containsKey('groupProfile');
      if (profileEvent) {
        final actor = state.members.singleWhere((m) => m.deviceId == sender);
        LoomGroupProfile? profile;
        if (actor.role != 'member' && content['groupProfile'] is Map) {
          try {
            profile = LoomGroupProfile.fromJson(
              Map<String, Object?>.from(content['groupProfile'] as Map),
            );
          } on FormatException {
            /* Consume invalid control events without poisoning sync. */
          }
        }
        content.clear();
        if (profile != null) content['groupProfile'] = profile.toJson();
      }
      encrypted = await sealHistory(groupId, {
        'operationId': event['operationId'],
        'senderDeviceId': sender,
        if (profileEvent) 'profileEvent': true,
        if (profileEvent) 'profileEpoch': state.epoch,
        'receivedAt': DateTime.now().toUtc().toIso8601String(),
        'content': content,
      });
    } else if (kind == 'commit') {
      final commit = Map<String, Object?>.from(result.result['Commit'] as Map);
      final sender = utf8.decode((commit['sender'] as List).cast<int>());
      final actor = previous!.members.singleWhere((m) => m.deviceId == sender);
      if (sender != event['senderDeviceId'] || actor.role == 'member')
        throw StateError('Unauthorized group commit');
    }
    _guard();
    store.apply(
      version,
      result.state,
      state,
      sequence,
      encryptedPayload: encrypted,
    );
  }
}
