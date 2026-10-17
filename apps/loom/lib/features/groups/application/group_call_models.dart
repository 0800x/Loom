import 'package:loom_models/loom_models.dart';

class LoomGroupCallParticipant {
  const LoomGroupCallParticipant({
    required this.id,
    required this.accountId,
    required this.deviceId,
    required this.name,
    required this.role,
    required this.state,
    required this.subscribe,
    required this.microphone,
    required this.camera,
    this.handRaisedAt,
  });
  final String id, accountId, deviceId, name, role, state;
  final bool subscribe, microphone, camera;
  final int? handRaisedAt;
}

class LoomGroupCallSnapshot {
  const LoomGroupCallSnapshot({
    required this.id,
    required this.groupId,
    required this.epoch,
    required this.revision,
    required this.phase,
    required this.kind,
    required this.mode,
    required this.joinLocked,
    required this.participants,
  });
  final String id, groupId, phase, kind, mode;
  final int epoch, revision;
  final bool joinLocked;
  final List<LoomGroupCallParticipant> participants;
  factory LoomGroupCallSnapshot.fromJson(
    Map<String, Object?> json,
    LoomGroupState group,
  ) {
    final uuid = RegExp(
      r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    );
    if (json['groupId'] != group.id ||
        json['epoch'] is! int ||
        (json['epoch'] as int) < 0 ||
        json['revision'] is! int ||
        (json['revision'] as int) < 1 ||
        json['id'] is! String ||
        !uuid.hasMatch(json['id'] as String) ||
        !['active', 'ended'].contains(json['phase']) ||
        !['audio', 'video'].contains(json['kind']) ||
        !['open', 'approval'].contains(json['mode']) ||
        json['joinLocked'] is! bool ||
        json['participants'] is! List ||
        (json['participants'] as List).length > 32) {
      throw const FormatException('Invalid group call');
    }
    final people = <LoomGroupCallParticipant>[],
        ids = <String>{},
        accounts = <String>{};
    for (final raw in json['participants'] as List) {
      final p = Map<String, Object?>.from(raw as Map), id = p['id'];
      final member = group.members
          .where(
            (m) => m.accountId == p['accountId'] && m.deviceId == p['deviceId'],
          )
          .firstOrNull;
      if (member == null ||
          member.role != p['role'] ||
          id is! String ||
          !id.startsWith('p_') ||
          !uuid.hasMatch(id.substring(2)) ||
          !ids.add(id) ||
          !accounts.add(member.accountId) ||
          p['name'] is! String ||
          (p['name'] as String).length > 100 ||
          !['joining', 'connected'].contains(p['state']) ||
          p['subscribe'] is! bool ||
          p['microphone'] is! bool ||
          p['camera'] is! bool ||
          (p['handRaisedAt'] != null && p['handRaisedAt'] is! int)) {
        throw const FormatException('Invalid participant');
      }
      people.add(
        LoomGroupCallParticipant(
          id: id,
          accountId: member.accountId,
          deviceId: member.deviceId,
          name: p['name'] as String,
          role: member.role,
          state: p['state'] as String,
          subscribe: p['subscribe'] as bool,
          microphone: p['microphone'] as bool,
          camera: p['camera'] as bool,
          handRaisedAt: p['handRaisedAt'] as int?,
        ),
      );
    }
    return LoomGroupCallSnapshot(
      id: json['id'] as String,
      groupId: group.id,
      epoch: json['epoch'] as int,
      revision: json['revision'] as int,
      phase: json['phase'] as String,
      kind: json['kind'] as String,
      mode: json['mode'] as String,
      joinLocked: json['joinLocked'] as bool,
      participants: List.unmodifiable(people),
    );
  }
}
