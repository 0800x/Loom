typedef LoomWifiReadinessStep = Future<bool> Function();

/// Shared product startup policy for Android Wi-Fi nearby bearers.
///
/// Runtime Nearby-Wi-Fi permission and the platform Wi-Fi settings/consent flow
/// are independent. Callers continue into the settings flow automatically after
/// permission succeeds, then resume product startup from the returned result.
final class LoomAndroidWifiReadinessPolicy {
  const LoomAndroidWifiReadinessPolicy._();

  static Future<bool> request({
    required LoomWifiReadinessStep requestPermissions,
    required LoomWifiReadinessStep ensureRadioReady,
  }) async {
    if (!await requestPermissions()) return false;
    return ensureRadioReady();
  }
}
