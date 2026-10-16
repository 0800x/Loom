enum LoomFederationMode {
  disabled,
  trustedNodesOnly,
  open,
  localOnly,
  hybrid,
}

class LoomFederationPeer {
  const LoomFederationPeer({
    required this.nodeId,
    required this.domain,
    required this.publicKey,
    required this.fingerprint,
    required this.endpoint,
    this.isLocal = false,
  });

  final String nodeId;
  final String domain;
  final String publicKey;
  final String fingerprint;
  final Uri endpoint;
  final bool isLocal;
}

class LoomFederationPolicy {
  const LoomFederationPolicy({
    required this.mode,
    this.trustedNodeIds = const <String>{},
    this.blockedNodeIds = const <String>{},
    this.blockedDomains = const <String>{},
  });

  final LoomFederationMode mode;
  final Set<String> trustedNodeIds;
  final Set<String> blockedNodeIds;
  final Set<String> blockedDomains;

  bool allowsPeer(LoomFederationPeer peer) {
    if (blockedNodeIds.contains(peer.nodeId) ||
        blockedDomains.contains(peer.domain.toLowerCase())) {
      return false;
    }
    return switch (mode) {
      LoomFederationMode.disabled => false,
      LoomFederationMode.trustedNodesOnly => trustedNodeIds.contains(
          peer.nodeId,
        ),
      LoomFederationMode.open => true,
      LoomFederationMode.localOnly => peer.isLocal,
      LoomFederationMode.hybrid =>
        peer.isLocal || trustedNodeIds.contains(peer.nodeId),
    };
  }
}
