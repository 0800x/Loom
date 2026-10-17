import 'dart:math';
import 'dart:typed_data';

import 'nearby_transport.dart';

/// Recipient-only intake, never a relay-custody grant. The application opens
/// the sealed packet for its own device and commits the normal inbox or rejects.
typedef LoomNearbyRecipientProbeAcceptor = Future<bool> Function(
  Uint8List bytes,
);

/// Small binary control frames inside the authenticated, encrypted peer link.
/// No address/key/mailbox inventory is advertised. A positive response is NOT
/// recipient proof: the caller retains its packet, copy budget and delivery state.
abstract final class LoomNearbyRecipientProbe {
  static const _request = <int>[0x43, 0x4e, 0x52, 0x50, 1];
  static const _response = <int>[0x43, 0x4e, 0x52, 0x41, 1];
  static const _headerBytes =
      21; // Magic/version + a fresh 128-bit correlation.

  static bool isRequest(List<int> bytes) => _matches(bytes, _request);

  static Future<bool> send(
    LoomNearbySecureConnection connection,
    Uint8List packet,
  ) async {
    if (packet.isEmpty ||
        packet.length + _headerBytes > connection.maxPlaintextBytes) {
      return false;
    }
    final random = Random.secure();
    final nonce = List<int>.generate(16, (_) => random.nextInt(256));
    await connection.send([..._request, ...nonce, ...packet]);
    final reply = await connection.receive(
      timeout: const Duration(seconds: 20),
    );
    if (reply.length != _headerBytes + 1 || !_matches(reply, _response)) {
      throw const FormatException('Invalid recipient probe response');
    }
    var difference = 0;
    for (var i = 0; i < nonce.length; i++) {
      difference |= nonce[i] ^ reply[5 + i];
    }
    if (difference != 0 || reply.last > 1) {
      throw const FormatException('Recipient probe correlation mismatch');
    }
    return reply.last == 1;
  }

  static Future<bool> accept(
    LoomNearbySecureConnection connection,
    List<int> bytes,
    LoomNearbyRecipientProbeAcceptor? acceptor,
  ) async {
    if (!isRequest(bytes) ||
        bytes.length <= _headerBytes ||
        bytes.length > connection.maxPlaintextBytes) {
      throw const FormatException('Invalid recipient probe request');
    }
    var accepted = false;
    if (acceptor != null) {
      try {
        accepted = await acceptor(
          Uint8List.fromList(bytes.sublist(_headerBytes)),
        );
      } catch (_) {
        /* No durable recipient intake means no positive response. */
      }
    }
    await connection.send([
      ..._response,
      ...bytes.sublist(5, _headerBytes),
      accepted ? 1 : 0,
    ]);
    return accepted;
  }

  static bool _matches(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }
}
