import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';

import 'onboarding_controller.dart';
import '../../media/application/playback_controller.dart';

/// Clears automatic sign-in material for this device without deleting the
/// user's long-term Loom identity or recovery material.
class LoomLogoutService {
  const LoomLogoutService();

  Future<void> signOut(LoomOnboardingController onboarding) async {
    await LoomPlaybackController.instance.clearLibrary();
    final receipt = onboarding.receipt;
    // Invalidate in-flight refreshes before awaiting secure-storage cleanup.
    onboarding.resetPending();
    if (receipt != null) {
      try {
        await LoomSecureCredentialVault().deleteRefreshToken(
          homeNode: receipt.homeNode,
          deviceId: receipt.deviceId,
        );
      } catch (_) {
        // Continue with local sign-out even if secure storage is temporarily
        // unavailable. The in-memory session is still invalidated below.
      }
    }

    try {
      await LoomSecureSessionVault().clear();
    } catch (_) {
      // Never leave the UI authenticated just because secure-storage cleanup
      // failed. The next successful logout/startup can retry the cleanup.
    }
  }
}
