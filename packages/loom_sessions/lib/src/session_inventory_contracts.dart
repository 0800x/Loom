import 'session_contracts.dart';

/// Additive crypto-transaction capability for device-scoped session lifecycle
/// changes such as revocation/supersession.
///
/// Implementations must read from the same transaction snapshot used by
/// [LoomCryptoTransaction.writeSession].
abstract interface class LoomSessionInventoryTransaction {
  Future<List<LoomSessionRecord>> listSessionsForRemoteDevice(
    LoomRemoteDeviceRef remoteDevice,
  );
}

LoomSessionInventoryTransaction requireLoomSessionInventoryTransaction(
  LoomCryptoTransaction transaction,
) {
  if (transaction is! LoomSessionInventoryTransaction) {
    throw StateError(
      'Crypto transaction cannot enumerate remote-device sessions atomically',
    );
  }
  // Keep the cast explicit: this capability is intentionally additive and
  // unrelated to LoomCryptoTransaction in the nominal type hierarchy, so
  // relying on promotion here is fragile across analyzer versions.
  return transaction as LoomSessionInventoryTransaction;
}
