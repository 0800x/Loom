import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// End-recipient proof, carried inside a recipient-sealed DTN packet.
/// Never trust a key supplied by the receipt: verification uses the pinned
/// device directory and binds the proof to the exact outgoing ciphertext.
class LoomNearbyMessageReceipt {
  static const protocol = 'loom-nearby-message-receipt-v1';
  const LoomNearbyMessageReceipt({
    required this.clientId,
    required this.sender,
    required this.recipient,
    required this.deviceId,
    required this.digest,
    required this.signature,
  });
  final String clientId, sender, recipient, deviceId, digest, signature;

  List<int> canonicalBytes() => utf8.encode(
    jsonEncode([
      protocol,
      clientId,
      sender.toLowerCase(),
      recipient.toLowerCase(),
      deviceId,
      digest,
    ]),
  );
  String encode() => jsonEncode({
    'version': 1,
    'clientId': clientId,
    'sender': sender,
    'recipient': recipient,
    'deviceId': deviceId,
    'digest': digest,
    'signature': signature,
  });

  static Future<String> ciphertextDigest(String ciphertext) async =>
      base64UrlEncode((await Sha256().hash(utf8.encode(ciphertext))).bytes);

  static Future<LoomNearbyMessageReceipt> create({
    required String clientId,
    required String sender,
    required String recipient,
    required String deviceId,
    required String ciphertext,
    required Future<List<int>> Function(List<int>) sign,
  }) async {
    final unsigned = LoomNearbyMessageReceipt(
      clientId: clientId,
      sender: sender,
      recipient: recipient,
      deviceId: deviceId,
      digest: await ciphertextDigest(ciphertext),
      signature: '',
    );
    final signature = await sign(unsigned.canonicalBytes());
    if (signature.length != 64)
      throw const FormatException('Invalid receipt signature');
    return LoomNearbyMessageReceipt(
      clientId: clientId,
      sender: sender,
      recipient: recipient,
      deviceId: deviceId,
      digest: unsigned.digest,
      signature: base64Encode(signature),
    );
  }

  factory LoomNearbyMessageReceipt.decode(String encoded) {
    if (encoded.length > 4096) throw const FormatException('Receipt too large');
    final raw = jsonDecode(encoded);
    if (raw is! Map || raw['version'] != 1)
      throw const FormatException('Invalid receipt');
    String field(String name, int max) {
      final value = raw[name];
      if (value is! String ||
          value.isEmpty ||
          value.length > max ||
          value.contains(RegExp(r'[\x00\r\n]'))) {
        throw FormatException('Invalid receipt $name');
      }
      return value;
    }

    return LoomNearbyMessageReceipt(
      clientId: field('clientId', 256),
      sender: field('sender', 512),
      recipient: field('recipient', 512),
      deviceId: field('deviceId', 256),
      digest: field('digest', 64),
      signature: field('signature', 128),
    );
  }

  Future<bool> verify({
    required String expectedClientId,
    required String expectedSender,
    required String expectedRecipient,
    required String expectedDeviceId,
    required String ciphertext,
    required String trustedSigningPublicKey,
  }) async {
    if (clientId != expectedClientId ||
        deviceId != expectedDeviceId ||
        sender.toLowerCase() != expectedSender.toLowerCase() ||
        recipient.toLowerCase() != expectedRecipient.toLowerCase() ||
        digest != await ciphertextDigest(ciphertext))
      return false;
    try {
      final key = base64Decode(trustedSigningPublicKey),
          sig = base64Decode(signature);
      if (key.length != 32 || sig.length != 64) return false;
      return await Ed25519().verify(
        canonicalBytes(),
        signature: Signature(
          sig,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
