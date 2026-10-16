import 'prekey_authorization.dart';
import 'session_contracts.dart';

/// Starts an outbound provider session only from a prekey that already crossed
/// Loom's device-authorization verification boundary.
Future<String> establishLoomOutgoingFromVerifiedPrekey({
  required LoomSessionCryptoProvider provider,
  required LoomCryptoTransaction transaction,
  required LoomRemoteDeviceRef remoteDevice,
  required LoomVerifiedPrekeyBundle verifiedPrekey,
}) async {
  remoteDevice.validate();
  if (verifiedPrekey.remoteAccountId != remoteDevice.accountId ||
      verifiedPrekey.remoteDeviceId != remoteDevice.deviceId ||
      verifiedPrekey.remoteDeviceKeyVersion != remoteDevice.deviceKeyVersion) {
    throw const LoomCryptoStateConflict(
      'Verified prekey does not match the requested remote device',
    );
  }
  if (verifiedPrekey.providerProtocolVersion != provider.protocolVersion) {
    throw const LoomCryptoStateConflict(
      'Verified prekey protocol does not match the session provider',
    );
  }
  return provider.establishOutgoing(
    transaction: transaction,
    remoteDevice: remoteDevice,
    verifiedPrekeyBundle: verifiedPrekey.providerBundle,
  );
}
