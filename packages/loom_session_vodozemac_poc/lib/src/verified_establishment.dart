import 'package:loom_sessions/loom_sessions.dart';

import 'provider.dart';

/// Establishes a PoC outbound session only from a prekey bundle that already
/// passed Loom's device-authorization/trust verification boundary.
///
/// This helper intentionally rechecks the remote tuple and provider protocol so
/// verified material cannot accidentally be rebound to another device between
/// directory verification and provider session creation.
Future<String> establishLoomVodozemacPocOutgoingVerified({
  required LoomVodozemacPocSessionProvider provider,
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
