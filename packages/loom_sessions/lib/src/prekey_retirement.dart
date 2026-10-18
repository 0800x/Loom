enum LoomPrekeyLeaseKind { oneTime, fallback }

final class LoomPrekeyRetirementPolicy {
  const LoomPrekeyRetirementPolicy({
    this.maximumClaimToFirstPacketDelay = const Duration(days: 1),
    this.maximumPacketLifetime = const Duration(days: 7),
    this.safetyMargin = const Duration(days: 2),
  });

  final Duration maximumClaimToFirstPacketDelay;
  final Duration maximumPacketLifetime;
  final Duration safetyMargin;

  void _validate() {
    if (maximumClaimToFirstPacketDelay.isNegative ||
        maximumClaimToFirstPacketDelay > const Duration(days: 7) ||
        maximumPacketLifetime <= Duration.zero ||
        maximumPacketLifetime > const Duration(days: 30) ||
        safetyMargin.isNegative ||
        safetyMargin > const Duration(days: 7)) {
      throw const FormatException('Invalid prekey retirement policy');
    }
  }

  /// Earliest instant at which private material may be forgotten even if a
  /// sender claimed the corresponding server key immediately before expiry.
  ///
  /// The claim-to-first-packet allowance prevents a sender that established a
  /// session shortly before expiry from losing its first delayed DTN packet.
  DateTime earliestSafeRetirement(DateTime serverExpiresAt) {
    _validate();
    return serverExpiresAt
        .toUtc()
        .add(maximumClaimToFirstPacketDelay)
        .add(maximumPacketLifetime)
        .add(safetyMargin);
  }

  /// Named form used by durable lifecycle coordinators.
  DateTime safeRetirementAfter({required DateTime serverExpiresAt}) =>
      earliestSafeRetirement(serverExpiresAt);

  bool mayForgetPrivateMaterial({
    required DateTime serverExpiresAt,
    required DateTime now,
  }) =>
      !now.toUtc().isBefore(earliestSafeRetirement(serverExpiresAt));
}

/// Provider capability for exact private-prekey retirement.
///
/// Providers which cannot delete one exact private OTK MUST NOT emulate this by
/// resetting the account or deleting unrelated keys. They should leave the key
/// unpublished and return false until the provider itself safely evicts it.
abstract interface class LoomPrivatePrekeyRetirer {
  Future<bool> forgetPrivatePrekey(String prekeyId);
}
