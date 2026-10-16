import 'package:loom_models/loom_models.dart';

/// Original stateful MLS facade, retained as a planning/compatibility contract.
/// The implemented stateless byte ABI is `LoomNativeMlsCore` in
/// native_mls_core.dart; the application has not wired this facade.
///
/// No Dart implementation is supplied intentionally: production MLS state and
/// primitive-level cryptography belong in the auditable native core.
abstract interface class LoomMlsEngine {
  Future<LoomMlsKeyPackage> createKeyPackage({
    required LoomDeviceKeyBundle device,
  });

  Future<LoomMlsGroupState> createGroup({
    required String conversationId,
    required List<LoomMlsKeyPackage> members,
  });

  Future<LoomMlsGroupState> joinGroup({
    required String conversationId,
    required List<int> welcome,
  });

  Future<LoomMlsCiphertext> encryptApplicationMessage({
    required String conversationId,
    required List<int> plaintext,
  });

  Future<List<int>> decryptApplicationMessage({
    required String conversationId,
    required List<int> mlsMessage,
  });

  Future<LoomMlsCommitResult> addMembers({
    required String conversationId,
    required List<LoomMlsKeyPackage> members,
  });

  Future<LoomMlsCommitResult> removeMembers({
    required String conversationId,
    required List<String> deviceIds,
  });
}
