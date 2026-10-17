import 'app_lock.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class LoomCredentialVault {
  Future<void> writeRefreshToken({
    required String homeNode,
    required String deviceId,
    required String refreshToken,
  });
  Future<String?> readRefreshToken({
    required String homeNode,
    required String deviceId,
  });
  Future<void> deleteRefreshToken({
    required String homeNode,
    required String deviceId,
  });
}

class LoomSecureCredentialVault implements LoomCredentialVault {
  LoomSecureCredentialVault({FlutterSecureStorage? storage})
    : _storage = LoomSecretStorage(storage);

  final LoomSecretStorage _storage;

  String _key(String homeNode, String deviceId) {
    final normalizedNode = homeNode.trim().toLowerCase();
    if (normalizedNode.isEmpty || deviceId.trim().isEmpty) {
      throw ArgumentError('homeNode and deviceId are required');
    }
    return 'loom.session.refresh.v1.$normalizedNode.${deviceId.trim()}';
  }

  @override
  Future<void> writeRefreshToken({
    required String homeNode,
    required String deviceId,
    required String refreshToken,
  }) async {
    if (refreshToken.isEmpty) {
      throw ArgumentError.value(
        refreshToken,
        'refreshToken',
        'must not be empty',
      );
    }
    await _storage.write(key: _key(homeNode, deviceId), value: refreshToken);
  }

  @override
  Future<String?> readRefreshToken({
    required String homeNode,
    required String deviceId,
  }) => _storage.read(key: _key(homeNode, deviceId));

  @override
  Future<void> deleteRefreshToken({
    required String homeNode,
    required String deviceId,
  }) => _storage.delete(key: _key(homeNode, deviceId));
}
