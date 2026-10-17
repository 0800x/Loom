import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';

/// Trust decision supplied by the authenticated peer-session layer.
///
/// Individual transport adapters do not get to self-assert a boolean
/// `peerAuthenticated=true`. The application composition root must inject the
/// component that owns authenticated peer-session lifecycle (later backed by the
/// reviewed peer AKE) and this service asks it about an opaque session id.
abstract interface class LoomPeerSessionTrustGate {
  bool isAuthenticatedPeerSession(String peerSessionId);
}

/// Receive-side orchestration boundary for peer-delivered v2 DTN replicas.
///
/// The service performs its own peer-session trust lookup before touching
/// durable custody. Invalid, conflicting or unauthenticated packets produce no
/// ACK. A returned [LoomDtnHopAck] is therefore safe for the hop-local
/// transport to serialize/send after this method returns.
final class LoomV2InboundReplicaService {
  const LoomV2InboundReplicaService({
    required this.intakeStore,
    required this.peerTrust,
  });

  final LoomSqliteReplicaIntakeStore intakeStore;
  final LoomPeerSessionTrustGate peerTrust;

  LoomDtnHopAck acceptFromPeer({
    required String peerSessionId,
    required String transmissionId,
    required Uint8List exactOuterEnvelopeBytes,
    required DateTime now,
  }) {
    _validateOpaqueId(peerSessionId, 'peer session id');
    _validateOpaqueId(transmissionId, 'hop-local transmission id');
    if (!peerTrust.isAuthenticatedPeerSession(peerSessionId)) {
      throw StateError('Unauthenticated peer session cannot enter DTN custody');
    }

    final result = intakeStore.acceptReplica(
      exactOuterEnvelopeBytes: exactOuterEnvelopeBytes,
      now: now,
    );

    // acceptReplica returns only after COMMIT. Constructing the ACK after that
    // call encodes the invariant that transports cannot acknowledge volatile
    // or merely parsed data.
    return LoomDtnHopAck(
      transmissionId: transmissionId,
      packetId: result.packetId,
      acceptedAt: now.toUtc(),
      duplicate: result.disposition == LoomReplicaIntakeDisposition.duplicate,
    );
  }

  static void _validateOpaqueId(String value, String label) {
    if (value.trim() != value || value.length < 8 || value.length > 256) {
      throw FormatException('Invalid $label');
    }
  }
}
