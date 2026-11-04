import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../onboarding/application/onboarding_controller.dart';
import '../../messaging/application/message_content.dart';
import '../../messaging/application/live_location_projection.dart';

class LoomGroupMessage {
  const LoomGroupMessage(
    this.sequence,
    this.operationId,
    this.senderDeviceId,
    this.text, {
    this.attachment,
    this.reply,
    this.location,
    this.createdAt,
  });
  final int sequence;
  final String operationId, senderDeviceId, text;
  final Map<String, Object?>? attachment, reply, location;
  final DateTime? createdAt;
}

/// Uses the dedicated MLS inbox/outbox. Never sends through the legacy codec.
class LoomGroupsController extends ChangeNotifier {
  LoomGroupsController({
    required this.onboarding,
    required this.trustedDevice,
    required this.devicesForContact,
    LoomNativeMlsCore? native,
    LoomSelfMessageCodec? historyCodec,
    this.onIncoming,
    this.onRead,
    this.identityLabel,
    this.sendAttachment,
  }) : native = native ?? const LoomNativeMlsCore(),
       historyCodec = historyCodec ?? LoomSelfMessageCodec() {
    LoomAppLock.instance.addListener(_lockChanged);
  }
  final LoomOnboardingController onboarding;
  final LoomGroupTrustedDeviceResolver trustedDevice;
  final Future<List<String>> Function(String) devicesForContact;
  final LoomNativeMlsCore native;
  final LoomSelfMessageCodec historyCodec;
  final void Function(String id, String title)? onIncoming;
  final void Function(String id)? onRead;
  final String? Function(String identityId)? identityLabel;
  final Future<bool> Function(
    String groupId,
    File file,
    String kind,
    String caption,
  )?
  sendAttachment;
  final joinRequests = <String, List<Map<String, Object?>>>{};
  final _memberNames = <String, String>{};
  final _memberAddresses = <String, String>{};
  final _profileLoads = <String, Future<void>>{};
  String memberLabel(LoomGroupMember member) =>
      _memberNames[member.identityId] ??
      identityLabel?.call(member.identityId) ??
      _memberAddresses[member.identityId] ??
      member.identityId;
  String? memberCachedAddress(LoomGroupMember member) =>
      _memberAddresses[member.identityId];

  /// Profile labels are transient and must match the authenticated MLS roster.
  /// Limit concurrent directory lookups when opening a large member list.
  Future<void> loadMemberProfiles(
    List<LoomGroupMember> members, {
    bool force = false,
  }) async {
    final epoch = _epoch;
    final pending = members.iterator;
    Future<void> worker() async {
      while (!_disposed &&
          epoch == _epoch &&
          !LoomAppLock.instance.locked &&
          pending.moveNext()) {
        final member = pending.current;
        if (!force && _memberAddresses.containsKey(member.identityId)) continue;
        try {
          await (_profileLoads[member.identityId] ??= memberAddress(member)
              .then<void>((_) {})
              .whenComplete(() {
                if (epoch == _epoch) _profileLoads.remove(member.identityId);
              }));
        } catch (_) {
          // Keep the verified local label; a failed lookup never changes pins.
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
  }

  String senderLabel(String deviceId) {
    final member = groups
        .expand((g) => g.members)
        .where((m) => m.deviceId == deviceId)
        .firstOrNull;
    return member == null ? deviceId : memberLabel(member);
  }

  String? activeGroupId;
  final _lastNotified = <String, int>{};
  final unreadCounts = <String, int>{};
  DateTime? _packagesCheckedAt;
  LoomGroupStore? _store;
  LoomGroupSession? _session;
  LoomGroupClient? _client;
  List<int>? _key;
  Future<void> _tail = Future.value();
  int _epoch = 0;
  bool _disposed = false;
  bool ready = false, busy = false;
  String? error;
  String? errorCode;
  List<LoomGroupState> groups = const [];
  Map<String, List<LoomGroupMessage>> messages = const {};
  final _drafts = <String, String>{};
  final _profiles = <String, LoomGroupProfile>{};
  final _profileEpochs = <String, int>{};
  final _photos = <String, Uint8List>{};

  Uint8List? groupPhoto(String id) =>
      LoomAppLock.instance.locked ? null : _photos[id];

  void _clearPhoto(String id) {
    final bytes = _photos.remove(id);
    if (bytes != null) {
      unawaited(MemoryImage(bytes).evict());
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _clearProfiles() {
    for (final id in _photos.keys.toList()) {
      _clearPhoto(id);
    }
    _profiles.clear();
    _profileEpochs.clear();
  }

  Future<bool> setGroupPhoto(String id, Uint8List? png) {
    final profile = LoomGroupProfile.fromJson({
      'v': 1,
      'png': png == null ? null : base64Encode(png),
    });
    return _operation((epoch) async {
      await _initialize(epoch);
      final payload = <String, Object?>{'groupProfile': profile.toJson()};
      final recoveringSame = await _pendingContentMatches(id, payload, epoch);
      await _session!.sync();
      _guard(epoch);
      if (!recoveringSame) await _session!.send(id, payload);
    });
  }

  /// A Welcome intentionally contains no earlier messages. Re-share only the
  /// current profile after a roster epoch changes so new members see it too.
  Future<bool> _republishProfiles(int epoch) async {
    var sent = false;
    for (final group in groups) {
      final profile = _profiles[group.id];
      final actor = group.members
          .where((m) => m.deviceId == ownDeviceId)
          .firstOrNull;
      if (profile?.png != null &&
          _profileEpochs[group.id] != group.epoch &&
          actor != null &&
          actor.role != 'member') {
        await _session!.send(group.id, {'groupProfile': profile!.toJson()});
        _guard(epoch);
        sent = true;
      }
    }
    return sent;
  }

  String draft(String id) =>
      LoomAppLock.instance.locked ? '' : _drafts[id] ?? '';
  void saveDraft(String id, String value) {
    if (_disposed || LoomAppLock.instance.locked) return;
    if (value.isEmpty) {
      _drafts.remove(id);
    } else {
      _drafts[id] = value;
    }
  }

  String? get ownDeviceId => onboarding.receipt?.deviceId;
  String? get ownAccountId => onboarding.receipt?.accountId;
  int get pendingCount => _store?.outbox.length ?? 0;

  void _guard(int epoch) {
    if (_disposed || epoch != _epoch || LoomAppLock.instance.locked) {
      throw StateError('Groups are locked');
    }
  }

  Future<bool> _operation(
    Future<void> Function(int) action, {
    bool republishProfiles = false,
  }) {
    final epoch = _epoch;
    final result = _tail.then((_) async {
      try {
        _guard(epoch);
        busy = true;
        error = null;
        errorCode = null;
        notifyListeners();
        await action(epoch);
        _guard(epoch);
        await _reload(epoch);
        if (republishProfiles && await _republishProfiles(epoch)) {
          await _reload(epoch);
        }
        _guard(epoch);
        return true;
      } catch (e) {
        if (!_disposed && epoch == _epoch && !LoomAppLock.instance.locked) {
          errorCode = e is LoomGroupProtocolException ? e.code : null;
          error = e is LoomGroupProtocolException
              ? (e.status == 404 && e.code == 'not_found'
                    ? 'سرور Home Node از API گروه و لینک دعوت پشتیبانی نمی‌کند. سرور را به نسخهٔ 0.10.6 یا جدیدتر به‌روزرسانی کنید. / Update your Home Node to 0.10.6 or later; its group API is unavailable (404).'
                    : e.toString())
              : e is ArgumentError || e is StateError
              ? e.toString()
              : 'MLS unavailable. Check the native library, Home Node and trusted contacts.';
        }
        return false;
      } finally {
        if (!_disposed && epoch == _epoch) {
          busy = false;
          notifyListeners();
        }
      }
    });
    _tail = result.then<void>((_) {});
    return result;
  }

  Future<void> _initialize(int epoch) async {
    if (_session != null) return;
    final receipt = onboarding.receipt, identity = onboarding.committedIdentity;
    final endpoint = onboarding.nodes.selectedEndpoint;
    if (receipt == null || identity == null || endpoint == null) {
      throw StateError('Sign in first');
    }
    final support = await getApplicationSupportDirectory();
    _guard(epoch);
    final name = base64UrlEncode(
      utf8.encode('${identity.identityId}:${receipt.deviceId}'),
    ).replaceAll('=', '');
    final path = '${support.path}/mls-device-$name.sqlite3';
    final store = LoomGroupStore.openFile(path);
    _store = store;
    for (final group in store.groups) {
      _lastNotified[group.id] =
          store.history(group.id).lastOrNull?.sequence ?? 0;
    }
    try {
      final key = await LoomMlsStateKeyVault().open(
        identityId: identity.identityId,
        deviceId: receipt.deviceId,
        lockPath: '$path.lock',
        hasNativeState: store.state != null,
      );
      try {
        _guard(epoch);
      } catch (_) {
        key.fillRange(0, key.length, 0);
        rethrow;
      }
      _key = key;
      final proof = await onboarding.deviceRequestProofProvider();
      _guard(epoch);
      final client = LoomGroupClient(
        baseUri: endpoint,
        accessTokenProvider: () async {
          _guard(epoch);
          if (onboarding.accessToken == null ||
              onboarding.accessTokenExpiresAt?.isBefore(
                    DateTime.now().toUtc().add(const Duration(seconds: 30)),
                  ) ==
                  true) {
            if (!await onboarding.refreshAccessToken()) {
              throw StateError('Reconnect the Home Node');
            }
          }
          _guard(epoch);
          return onboarding.accessToken!;
        },
        deviceProof: proof,
      );
      _client = client;
      final session = LoomGroupSession(
        accountId: receipt.accountId,
        identityId: identity.identityId,
        deviceId: receipt.deviceId,
        client: client,
        store: store,
        unlocked: () =>
            !_disposed && epoch == _epoch && !LoomAppLock.instance.locked,
        trustedDevice: trustedDevice,
        sealHistory: (id, plain) => historyCodec.encryptText(
          identityId: identity.identityId,
          conversationId: 'mls-history:$id',
          plaintext: jsonEncode(plain),
        ),
        crypto:
            ({
              required operation,
              required state,
              groupId,
              required arguments,
            }) async {
              _guard(epoch);
              final result = await native.execute(
                deviceId: receipt.deviceId,
                sealingKey: key,
                operation: operation,
                state: state,
                groupId: groupId,
                arguments: arguments,
              );
              _guard(epoch);
              return (state: result.state, result: result.result);
            },
      );
      _session = session;
      await session.initialize();
      await session.drain();
      await session.publishCredential();
      await session.ensureKeyPackages();
      _packagesCheckedAt = DateTime.now().toUtc();
      _guard(epoch);
      ready = true;
    } catch (_) {
      if (identical(_store, store)) {
        _session?.close();
        _session = null;
        _client?.close();
        _client = null;
        _key?.fillRange(0, _key!.length, 0);
        _key = null;
        store.close();
        _store = null;
        ready = false;
      }
      rethrow;
    }
  }

  Future<bool> open() => _operation((epoch) async {
    await _initialize(epoch);
    await _session!.sync();
    await _processJoinRequests(epoch);
    if (_packagesCheckedAt == null ||
        DateTime.now().toUtc().difference(_packagesCheckedAt!) >
            const Duration(minutes: 1)) {
      await _session!.ensureKeyPackages();
      _packagesCheckedAt = DateTime.now().toUtc();
    }
  }, republishProfiles: true);
  Future<void> _processJoinRequests(int epoch) async {
    for (final group in List<LoomGroupState>.of(_store!.groups)) {
      final actor = group.members
          .where((m) => m.deviceId == ownDeviceId)
          .firstOrNull;
      if (actor == null || actor.role == 'member') continue;
      final requests = await _client!.joinRequests(group.id);
      _guard(epoch);
      joinRequests[group.id] = requests;
      for (final request in requests.where((r) => r['status'] == 'approved')) {
        final current = _store!.groups.singleWhere((g) => g.id == group.id);
        final requested = LoomGroupMember.fromJson(
          Map<String, Object?>.from(request['member'] as Map),
        );
        final role =
            current.members
                .where((m) => m.accountId == requested.accountId)
                .firstOrNull
                ?.role ??
            'member';
        final member = LoomGroupMember(
          accountId: requested.accountId,
          deviceId: requested.deviceId,
          identityId: requested.identityId,
          role: role,
          mlsSignatureKey: requested.mlsSignatureKey,
          mlsSignature: requested.mlsSignature,
        );
        if (current.members.any((m) => m.deviceId == member.deviceId)) continue;
        try {
          await _session!.update(
            groupId: current.id,
            title: current.title,
            members: [...current.members, member],
            joinRequestDeviceId: member.deviceId,
          );
          await _session!.sync();
          _guard(epoch);
        } catch (e) {
          _guard(epoch);
          error = 'A group join is waiting for retry: $e';
          if (_store!.outbox.isNotEmpty) break;
        }
      }
      joinRequests[group.id] = await _client!.joinRequests(group.id);
    }
  }

  Future<String?> createInvite(String id, String mode) async {
    String? link;
    final ok = await _operation((epoch) async {
      await _initialize(epoch);
      final invite = await _client!.createInvite(id, mode);
      _guard(epoch);
      final node = onboarding.nodes.selectedEndpoint!;
      link = node.resolve('/g/${invite['token']}').toString();
    });
    return ok ? link : null;
  }

  Future<bool> revokeInvites(String id) => _operation((epoch) async {
    await _initialize(epoch);
    await _client!.revokeInvites(id);
  });
  Future<Map<String, Object?>?> previewInvite(String token) async {
    Map<String, Object?>? preview;
    final ok = await _operation((epoch) async {
      await _initialize(epoch);
      preview = await _client!.previewInvite(token);
    });
    return ok ? preview : null;
  }

  Future<String?> joinInvite(String token) async {
    String? id;
    final ok = await _operation((epoch) async {
      await _initialize(epoch);
      final result = await _client!.requestJoin(token);
      if (result['status'] == 'rejected') {
        throw StateError('This join request was declined');
      }
      id = result['groupId'] as String;
      await _session!.sync();
    });
    return ok ? id : null;
  }

  Future<bool> decideJoin(String id, String deviceId, bool approve) =>
      _operation((epoch) async {
        await _initialize(epoch);
        await _client!.decideJoin(id, deviceId, approve);
        if (approve) {
          await _processJoinRequests(epoch);
        }
      }, republishProfiles: true);
  Future<String> memberAddress(LoomGroupMember member) async {
    final epoch = _epoch;
    _guard(epoch);
    if (_client == null) throw StateError('Groups are not initialized');
    final profile = await _client!.memberProfile(member.deviceId);
    _guard(epoch);
    if (profile['accountId'] != member.accountId ||
        profile['identityId'] != member.identityId) {
      throw StateError('Group member identity mismatch');
    }
    final address = LoomAddress.parseCanonical(
      '@${profile['username']}:${onboarding.receipt!.homeNode}',
    ).canonical;
    final name = (profile['displayName'] as String?)?.trim();
    _memberAddresses[member.identityId] = address;
    if (name != null && name.isNotEmpty && name.length <= 100) {
      _memberNames[member.identityId] = name;
    } else {
      _memberNames.remove(member.identityId);
    }
    notifyListeners();
    return address;
  }

  Future<Uint8List> exportCallKey(String id, String callId, int epoch) async {
    Uint8List? key;
    final ok = await _operation((generation) async {
      await _initialize(generation);
      key = await _session!.exportCallKey(id, callId, epoch);
    });
    if (!ok || key == null) {
      key?.fillRange(0, key!.length, 0);
      throw StateError('Group call key unavailable');
    }
    return key!;
  }

  /// Polling call policy must not decrypt/reload the chat history every time.
  Future<Map<String, Object?>> callRequest(
    String id,
    String action, [
    Map<String, Object?>? body,
  ]) async {
    final generation = _epoch;
    _guard(generation);
    if (_client == null) {
      await open();
      _guard(generation);
    }
    if (_client == null ||
        !groups.any(
          (g) => g.id == id && g.members.any((m) => m.deviceId == ownDeviceId),
        )) {
      throw StateError('Group call membership unavailable');
    }
    if (![
      '',
      'start',
      'join',
      'heartbeat',
      'leave',
      'control',
    ].contains(action)) {
      throw ArgumentError('Invalid call action');
    }
    final path = '/api/v1/groups/$id/call${action.isEmpty ? '' : '/$action'}';
    final result = await _client!.request(
      action.isEmpty ? 'GET' : 'POST',
      path,
      body,
    );
    _guard(generation);
    return result;
  }

  Future<bool> synchronize() {
    if (busy || LoomAppLock.instance.locked) return Future.value(false);
    return open();
  }

  void setActiveGroup(String? id) {
    activeGroupId = id;
    if (id != null) markGroupRead(id);
  }

  /// Explicit Mark as read must not turn a closed chat into an active watcher.
  void markGroupRead(String id) {
    if (_store == null || LoomAppLock.instance.locked) return;
    final latest = messages[id]?.lastOrNull?.sequence ?? 0;
    _store!.markRead(id, latest);
    unreadCounts[id] = 0;
    onRead?.call(id);
  }

  Future<void> _reload(int epoch) async {
    final identity = onboarding.committedIdentity;
    if (_store == null || identity == null) return;
    final catalogue = _store!.groups,
        next = <String, List<LoomGroupMessage>>{},
        profiles = <String, LoomGroupProfile>{},
        profileEpochs = <String, int>{};
    for (final group in catalogue) {
      final rows = <LoomGroupMessage>[];
      for (final entry in _store!.history(group.id)) {
        final text = await historyCodec.decryptText(
          identityId: identity.identityId,
          conversationId: 'mls-history:${group.id}',
          envelope: entry.payload,
        );
        _guard(epoch);
        final payload = Map<String, Object?>.from(jsonDecode(text) as Map);
        final content = payload['content'] as Map;
        if (payload['profileEvent'] == true) {
          final raw = content['groupProfile'];
          if (raw is Map && payload['profileEpoch'] is int) {
            try {
              profiles[group.id] = LoomGroupProfile.fromJson(
                Map<String, Object?>.from(raw),
              );
              profileEpochs[group.id] = payload['profileEpoch'] as int;
            } on FormatException {
              /* Ignore invalid profile control events. */
            }
          }
          continue;
        }
        rows.add(
          LoomGroupMessage(
            entry.sequence,
            payload['operationId'] as String,
            payload['senderDeviceId'] as String,
            content['text'] as String? ?? 'Unsupported group content',
            location: LoomMessageContent.decode(
              LoomMessageContent(
                location: content['location'] == null
                    ? null
                    : Map<String, Object?>.from(content['location'] as Map),
              ).encode(),
            ).location,
            createdAt: DateTime.tryParse(
              payload['receivedAt'] as String? ?? '',
            ),
            reply: LoomMessageContent.decode(
              LoomMessageContent(
                reply: content['reply'] == null
                    ? null
                    : Map<String, Object?>.from(content['reply'] as Map),
              ).encode(),
            ).reply,
            attachment: content['attachment'] == null
                ? null
                : LoomMessageContent.decode(
                    LoomMessageContent(
                      text: content['text'] as String? ?? '',
                      attachment: Map<String, Object?>.from(
                        content['attachment'] as Map,
                      ),
                    ).encode(),
                  ).attachment,
          ),
        );
      }
      final projected = projectLoomLiveLocations<LoomGroupMessage>(
        rows,
        location: (m) => m.location,
        sender: (m) => m.senderDeviceId,
        compare: (a, b) => a.sequence.compareTo(b.sequence),
        merge: (anchor, latest) => LoomGroupMessage(
          anchor.sequence,
          anchor.operationId,
          anchor.senderDeviceId,
          latest.text,
          createdAt: anchor.createdAt,
          location: latest.location,
          attachment: anchor.attachment,
          reply: anchor.reply,
        ),
      );
      final lastRead = _store!.readSequence(group.id);
      unreadCounts[group.id] = projected
          .where(
            (m) => m.sequence > lastRead && m.senderDeviceId != ownDeviceId,
          )
          .length;
      final newest = projected.lastOrNull?.sequence ?? 0;
      final previous = _lastNotified[group.id] ?? 0;
      if (activeGroupId == group.id) {
        _store!.markRead(group.id, newest);
        unreadCounts[group.id] = 0;
      } else if (projected.any(
        (m) => m.sequence > previous && m.senderDeviceId != ownDeviceId,
      )) {
        onIncoming?.call(group.id, group.title);
      }
      _lastNotified[group.id] = newest;
      next[group.id] = List.unmodifiable(projected);
    }
    _guard(epoch);
    for (final id in {..._profiles.keys, ...profiles.keys}) {
      final current = profiles[id];
      if (_profiles[id]?.png != current?.png) {
        _clearPhoto(id);
        if (current?.png != null) _photos[id] = base64Decode(current!.png!);
      }
    }
    _profiles
      ..clear()
      ..addAll(profiles);
    _profileEpochs
      ..clear()
      ..addAll(profileEpochs);
    groups = List.unmodifiable(catalogue);
    messages = Map.unmodifiable(next);
  }

  Future<String?> create(String title, List<String> addresses) async {
    String? created;
    final ok = await _operation((epoch) async {
      await _initialize(epoch);
      await _session!.drain();
      final owner = await _session!.ownMember();
      final members = <LoomGroupMember>[owner];
      final deviceIds = <String>{};
      for (final address in addresses.toSet()) {
        deviceIds.addAll(await devicesForContact(address.trim()));
      }
      for (final id in deviceIds) {
        if (id == ownDeviceId) continue;
        final member = await _client!.credential(id);
        await verifyLoomGroupMember(member, await trustedDevice(member));
        members.add(
          LoomGroupMember(
            accountId: member.accountId,
            deviceId: member.deviceId,
            identityId: member.identityId,
            role: member.accountId == owner.accountId ? 'owner' : 'member',
            mlsSignatureKey: member.mlsSignatureKey,
            mlsSignature: member.mlsSignature,
          ),
        );
      }
      _guard(epoch);
      created = await _session!.create(title: title, members: members);
    });
    return ok ? created : null;
  }

  Future<bool> _pendingContentMatches(
    String id,
    Map<String, Object?> payload,
    int epoch,
  ) async {
    final pending = _store!.outbox
        .where((o) => o.groupId == id && o.path.endsWith('/messages'))
        .firstOrNull;
    if (pending?.localPayload == null) return false;
    final plain = await historyCodec.decryptText(
      identityId: onboarding.committedIdentity!.identityId,
      conversationId: 'mls-history:$id',
      envelope: pending!.localPayload!,
    );
    _guard(epoch);
    final document = jsonDecode(plain) as Map;
    return jsonEncode(document['content']) == jsonEncode(payload);
  }

  Future<bool> send(String id, String text) =>
      sendContent(id, LoomMessageContent(text: text.trim()));
  Future<bool> sendContent(String id, LoomMessageContent content) =>
      _operation((epoch) async {
        if ((content.text.trim().isEmpty &&
                content.attachment == null &&
                content.location == null) ||
            utf8.encode(content.encode()).length > 32000) {
          throw ArgumentError('Message must be 1..32000 bytes');
        }
        LoomMessageContent.decode(content.encode());
        final payload = <String, Object?>{
          'text': content.text,
          if (content.attachment != null) 'attachment': content.attachment,
          if (content.reply != null) 'reply': content.reply,
          if (content.location != null) 'location': content.location,
        };
        await _initialize(epoch);
        final recoveringSame = await _pendingContentMatches(id, payload, epoch);
        await _session!.sync();
        _guard(epoch);
        if (!recoveringSame) await _session!.send(id, payload);
        if (_drafts[id]?.trim() == content.text.trim()) _drafts.remove(id);
      });
  Future<bool> update(
    String id,
    String title,
    List<LoomGroupMember> members, {
    int? expectedRevision,
  }) => _operation((epoch) async {
    await _initialize(epoch);
    await _session!.sync();
    if (expectedRevision != null &&
        _store!.groups.singleWhere((g) => g.id == id).revision !=
            expectedRevision) {
      throw StateError(
        'Group changed. Review the latest members before editing.',
      );
    }
    await _session!.update(groupId: id, title: title, members: members);
    await _session!.sync();
  }, republishProfiles: true);
  Future<bool> addContact(String id, String address) => _operation((
    epoch,
  ) async {
    await _initialize(epoch);
    await _session!.sync();
    final group = _store!.groups.singleWhere((g) => g.id == id);
    final members = List<LoomGroupMember>.of(group.members);
    for (final deviceId in await devicesForContact(address)) {
      if (members.any((m) => m.deviceId == deviceId)) continue;
      final member = await _client!.credential(deviceId);
      await verifyLoomGroupMember(member, await trustedDevice(member));
      final role =
          members
              .where((m) => m.accountId == member.accountId)
              .firstOrNull
              ?.role ??
          'member';
      members.add(
        LoomGroupMember(
          accountId: member.accountId,
          deviceId: member.deviceId,
          identityId: member.identityId,
          role: role,
          mlsSignatureKey: member.mlsSignatureKey,
          mlsSignature: member.mlsSignature,
        ),
      );
    }
    _guard(epoch);
    await _session!.update(groupId: id, title: group.title, members: members);
    await _session!.sync();
  }, republishProfiles: true);
  Future<LoomGroupMember> credential(String deviceId) async {
    final member = await _client!.credential(deviceId);
    await verifyLoomGroupMember(member, await trustedDevice(member));
    return member;
  }

  void _lockChanged() {
    if (!LoomAppLock.instance.locked) return;
    ++_epoch;
    ready = false;
    busy = false;
    groups = const [];
    messages = const {};
    _drafts.clear();
    _clearProfiles();
    activeGroupId = null;
    unreadCounts.clear();
    joinRequests.clear();
    _memberNames.clear();
    _memberAddresses.clear();
    _profileLoads.clear();
    _lastNotified.clear();
    _session?.close();
    _session = null;
    _client?.close();
    _client = null;
    final store = _store;
    _store = null;
    final key = _key;
    _key = null;
    _tail = _tail.then((_) {
      key?.fillRange(0, key.length, 0);
      store?.close();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _clearProfiles();
    _memberNames.clear();
    _memberAddresses.clear();
    _profileLoads.clear();
    LoomAppLock.instance.removeListener(_lockChanged);
    _session?.close();
    _client?.close();
    final store = _store, key = _key;
    _store = null;
    _key = null;
    _session = null;
    _client = null;
    unawaited(
      _tail.then((_) {
        key?.fillRange(0, key.length, 0);
        store?.close();
      }),
    );
    groups = const [];
    messages = const {};
    _drafts.clear();
    joinRequests.clear();
    super.dispose();
  }
}

class LoomGroupsScope extends InheritedNotifier<LoomGroupsController> {
  const LoomGroupsScope({
    required LoomGroupsController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
  static LoomGroupsController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LoomGroupsScope>()!.notifier!;
  static LoomGroupsController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LoomGroupsScope>()?.notifier;
}
