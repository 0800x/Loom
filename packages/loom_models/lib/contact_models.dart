enum LoomContactSecurityState { resolved, verified, changed, unavailable }

class LoomContact {
  const LoomContact({
    required this.identityId,
    required this.username,
    required this.displayName,
    required this.canonicalAddress,
    required this.homeNode,
    required this.securityState,
    required this.createdAt,
    required this.updatedAt,
    required this.lastResolvedAt,
    this.accountId,
  });

  final String identityId;
  final String? accountId;
  final String username;
  final String displayName;
  final String canonicalAddress;
  final String homeNode;
  final LoomContactSecurityState securityState;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastResolvedAt;

  LoomContact copyWith({
    String? identityId,
    String? accountId,
    String? username,
    String? displayName,
    String? canonicalAddress,
    String? homeNode,
    LoomContactSecurityState? securityState,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastResolvedAt,
  }) => LoomContact(
    identityId: identityId ?? this.identityId,
    accountId: accountId ?? this.accountId,
    username: username ?? this.username,
    displayName: displayName ?? this.displayName,
    canonicalAddress: canonicalAddress ?? this.canonicalAddress,
    homeNode: homeNode ?? this.homeNode,
    securityState: securityState ?? this.securityState,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastResolvedAt: lastResolvedAt ?? this.lastResolvedAt,
  );
}
