import 'v2_messaging_runtime.dart';

/// Product migration policy. The default preserves the existing v1 product,
/// while an explicitly v2-required surface is forbidden from silently falling
/// back to the legacy direct-message protocol when v2 is unavailable.
enum LoomProductMessagingMode { legacyOnly, v2Required }

final class LoomProductMessagingPolicy {
  const LoomProductMessagingPolicy({
    this.mode = LoomProductMessagingMode.legacyOnly,
  });

  final LoomProductMessagingMode mode;

  bool get allowsLegacy => mode == LoomProductMessagingMode.legacyOnly;
  bool get requiresV2 => mode == LoomProductMessagingMode.v2Required;

  Future<void> requireUsablePath(LoomV2MessagingRuntime? runtime) async {
    if (!requiresV2) return;
    if (runtime == null ||
        !runtime.productionSendEnabled ||
        !await runtime.stateProtectionAvailable()) {
      throw StateError(
        'This messaging surface requires Architecture v2; legacy downgrade is forbidden',
      );
    }
  }
}

/// Small product dispatcher used at a UI/application boundary.
///
/// In `v2Required` mode the legacy callback is never invoked, even when the v2
/// callback fails. This prevents accidental unauthenticated/protocol downgrade
/// hidden behind generic retry code.
final class LoomProductMessagingDispatcher {
  const LoomProductMessagingDispatcher({required this.policy, this.v2Runtime});

  final LoomProductMessagingPolicy policy;
  final LoomV2MessagingRuntime? v2Runtime;

  Future<T> dispatch<T>({
    required Future<T> Function() legacy,
    required Future<T> Function(LoomV2MessagingRuntime runtime) v2,
  }) async {
    if (policy.requiresV2) {
      final runtime = v2Runtime;
      await policy.requireUsablePath(runtime);
      return v2(runtime!);
    }
    return legacy();
  }
}
