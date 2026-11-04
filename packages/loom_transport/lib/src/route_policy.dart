import 'dart:io';

import 'connectivity.dart';

class LoomRoutePolicy {
  const LoomRoutePolicy({this.preferVerifiedLan = true});
  final bool preferVerifiedLan;

  /// Legacy Home-Node-only route selection.
  LoomRouteSelection select(
    List<LoomRouteCandidate> candidates, {
    required String homeNodeId,
  }) {
    final eligible = candidates
        .where((candidate) {
          if (!candidate.reachable) return false;
          if (!candidate.identityVerified) return false;
          if (candidate.nodeId != homeNodeId) return false;
          if (!_allowsTransport(candidate.endpoint)) return false;
          return true;
        })
        .toList(growable: false);
    return _orderedSelection(eligible, destinationNodeId: null);
  }

  /// Architecture-v2 delivery route selection.
  ///
  /// A verified route to the recipient's destination node is preferred. If it
  /// is unavailable, the sender's Home Node remains an explicit fallback. This
  /// allows Client1 -> Node2 -> Client2 without making Home Node reachability a
  /// prerequisite for every message.
  LoomRouteSelection selectForDelivery(
    List<LoomRouteCandidate> candidates, {
    required String homeNodeId,
    required String destinationNodeId,
  }) {
    if (destinationNodeId.trim() != destinationNodeId ||
        destinationNodeId.isEmpty) {
      throw const FormatException('Invalid destination node id');
    }
    final eligible = candidates
        .where((candidate) {
          if (!candidate.reachable || !candidate.identityVerified) return false;
          if (!_allowsTransport(candidate.endpoint)) return false;
          return candidate.nodeId == destinationNodeId ||
              candidate.nodeId == homeNodeId;
        })
        .toList(growable: false);
    return _orderedSelection(eligible, destinationNodeId: destinationNodeId);
  }

  LoomRouteSelection _orderedSelection(
    List<LoomRouteCandidate> eligible, {
    required String? destinationNodeId,
  }) {
    if (eligible.isEmpty) {
      return const LoomRouteSelection(
        ordered: [],
        state: LoomConnectivityState.nodeUnreachable,
      );
    }
    final ordered = [...eligible]
      ..sort((a, b) {
        final aDestination =
            destinationNodeId != null && a.nodeId == destinationNodeId;
        final bDestination =
            destinationNodeId != null && b.nodeId == destinationNodeId;
        if (aDestination != bDestination) return aDestination ? -1 : 1;
        if (preferVerifiedLan && a.kind != b.kind) {
          if (a.kind == LoomRouteKind.localNetwork) return -1;
          if (b.kind == LoomRouteKind.localNetwork) return 1;
        }
        final aLatency = a.latency?.inMilliseconds ?? 1 << 30;
        final bLatency = b.latency?.inMilliseconds ?? 1 << 30;
        return aLatency.compareTo(bLatency);
      });
    return LoomRouteSelection(
      ordered: ordered,
      state: ordered.first.kind == LoomRouteKind.localNetwork
          ? LoomConnectivityState.localNetwork
          : LoomConnectivityState.online,
    );
  }

  bool _allowsTransport(Uri endpoint) {
    if (endpoint.scheme == 'https') return true;
    if (endpoint.scheme != 'http') return false;
    final host = endpoint.host.toLowerCase();
    if (host == 'localhost') return true;
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    if (address.isLoopback) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          (bytes[0] == 169 && bytes[1] == 254);
    }
    return (bytes[0] & 0xfe) == 0xfc ||
        (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
  }
}
