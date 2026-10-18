import 'dart:convert';

const loomGroupProtocol = 'Loom-MLS-v1';

class LoomGroupMember {
  const LoomGroupMember({
    required this.accountId,
    required this.deviceId,
    required this.identityId,
    required this.role,
    required this.mlsSignatureKey,
    required this.mlsSignature,
  });
  final String accountId,
      deviceId,
      identityId,
      role,
      mlsSignatureKey,
      mlsSignature;
  factory LoomGroupMember.fromJson(Map<String, Object?> j) => LoomGroupMember(
    accountId: j['accountId'] as String,
    deviceId: j['deviceId'] as String,
    identityId: j['identityId'] as String,
    role: j['role'] as String,
    mlsSignatureKey: j['mlsSignatureKey'] as String,
    mlsSignature: j['mlsSignature'] as String,
  );
  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'deviceId': deviceId,
    'role': role,
    'identityId': identityId,
    'mlsSignatureKey': mlsSignatureKey,
    'mlsSignature': mlsSignature,
  };
  Map<String, Object?> get nativePin => {
    'device_id': utf8.encode(deviceId),
    'signature_key': base64Decode(mlsSignatureKey).toList(),
  };
  List<int> get binding => utf8.encode(
    jsonEncode({
      'protocol': 'Loom-MLSDevice-v1',
      'identityId': identityId,
      'deviceId': deviceId,
      'mlsSignatureKey': mlsSignatureKey,
    }),
  );
}

class LoomGroupState {
  const LoomGroupState({
    required this.id,
    required this.title,
    required this.epoch,
    required this.revision,
    required this.sequence,
    required this.members,
  });
  final String id, title;
  final int epoch, revision, sequence;
  final List<LoomGroupMember> members;
  factory LoomGroupState.fromJson(Map<String, Object?> j) {
    final state = LoomGroupState(
      id: j['id'] as String,
      title: j['title'] as String,
      epoch: j['epoch'] as int,
      revision: j['revision'] as int,
      sequence: j['sequence'] as int,
      members: (j['members'] as List)
          .map(
            (m) =>
                LoomGroupMember.fromJson(Map<String, Object?>.from(m as Map)),
          )
          .toList(growable: false),
    );
    if (state.epoch < 1 ||
        state.revision < 1 ||
        state.sequence < 1 ||
        state.members.isEmpty ||
        state.members.length > 256 ||
        state.members.map((m) => m.deviceId).toSet().length !=
            state.members.length ||
        state.members.any(
          (m) => !['owner', 'admin', 'member'].contains(m.role),
        )) {
      throw const FormatException('Invalid group state');
    }
    final owners = state.members
        .where((m) => m.role == 'owner')
        .map((m) => m.accountId)
        .toSet();
    if (owners.length != 1 ||
        state.members.any(
          (m) => state.members.any(
            (n) => n.accountId == m.accountId && n.role != m.role,
          ),
        )) {
      throw const FormatException('Invalid group ownership');
    }
    return state;
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'epoch': epoch,
    'revision': revision,
    'sequence': sequence,
    'members': members.map((m) => m.toJson()).toList(),
  };
  List<Map<String, Object?>> get nativePins =>
      members.map((m) => m.nativePin).toList();
}

/// The blob is authenticated encrypted native state, never an exportable backup.
class LoomMlsSealedState {
  const LoomMlsSealedState({required this.generation, required this.bytes});
  final int generation;
  final List<int> bytes;
  Map<String, Object?> toJson() => {'generation': generation, 'bytes': bytes};
  factory LoomMlsSealedState.fromJson(Map<String, Object?> j) =>
      LoomMlsSealedState(
        generation: j['generation'] as int,
        bytes: (j['bytes'] as List).cast<int>(),
      );
}
