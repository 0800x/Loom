import 'dart:convert';

import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:cryptography/cryptography.dart';

import 'recovery_backup.dart';

/// Reads existing protected recovery material without creating, replacing or
/// committing any identity. Call only after the user accepts private export.
Future<LoomRecoveryBackup> readCommittedLoomRecoveryBackup({
  required LoomIdentityCore identityCore,
  required String expectedIdentityId,
}) async {
  final before = await identityCore.readIdentity();
  if (before == null || before.identityId != expectedIdentityId) {
    throw StateError('The active identity changed');
  }
  final entropy = await identityCore.exportRecoveryEntropy();
  try {
    if (entropy.length != 32) {
      throw const FormatException('Invalid recovery material');
    }
    final keyPair = await Ed25519().newKeyPairFromSeed(entropy);
    try {
      final publicKey = await keyPair.extractPublicKey();
      if (base64Encode(publicKey.bytes) != before.publicKey) {
        throw const FormatException(
          'Recovery material does not match the identity',
        );
      }
    } finally {
      keyPair.destroy();
    }
    final after = await identityCore.readIdentity();
    if (after == null ||
        after.identityId != before.identityId ||
        after.publicKey != before.publicKey) {
      throw StateError('The active identity changed');
    }
    return LoomRecoveryBackup(
      words: Mnemonic(entropy, Language.english).words,
    );
  } finally {
    entropy.fillRange(0, entropy.length, 0);
  }
}
