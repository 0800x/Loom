import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Short human-comparable proof that the participants of a call share the
/// same end-to-end media key material.
///
/// For 1:1 calls the transcript is derived from the two negotiated DTLS-SRTP
/// certificate fingerprints (order-independent, so both sides compute the
/// identical code). For MLS group calls the transcript is derived from the
/// exported group call key, which every legitimate member derives at the same
/// epoch. A man in the middle must present its own certificate or key, so the
/// two sides see different codes and the mismatch is detectable.
class LoomCallVerification {
  const LoomCallVerification._(this.digits, this.emoji);

  /// Four decimal digits, e.g. `4712`.
  final String digits;

  /// Three emoji from a fixed, visually distinct table.
  final List<String> emoji;

  /// Fixed 32-entry table of single-codepoint, emoji-default glyphs so both
  /// Persian and English users can compare them verbally without ambiguity.
  static const List<String> _emojiTable = [
    '🐢', '🦊', '🐙', '🦉', '🐝', '🦋', '🐳', '🐋',
    '🦈', '🐬', '🦩', '🦔', '🌵', '🌲', '🍁', '🌻',
    '🍀', '🍄', '⚡', '🔥', '🌙', '💫', '🎈', '🎲',
    '🎧', '🎸', '🥁', '🎺', '⛵', '🚀', '🧭', '💎',
  ];

  static final Sha256 _sha256 = Sha256();

  /// Derives the display code from an opaque transcript. The transcript must
  /// already be order-independent when both sides contribute key material.
  static Future<LoomCallVerification> derive(List<int> transcript) async {
    final digest = await _sha256.hash(transcript);
    final bytes = digest.bytes;
    final value =
        (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
    return LoomCallVerification._(
      (value % 10000).toString().padLeft(4, '0'),
      List<String>.unmodifiable([
        _emojiTable[bytes[3] & 31],
        _emojiTable[bytes[4] & 31],
        _emojiTable[bytes[5] & 31],
      ]),
    );
  }

  /// Derives the code for a 1:1 call from the negotiated session
  /// descriptions. Both fingerprints are sorted together with the protocol
  /// label, so caller and callee obtain the same code. Returns null when a
  /// fingerprint is not (yet) available, e.g. before the DTLS handshake.
  static Future<LoomCallVerification?> fromDtlsFingerprints({
    required String? localSdp,
    required String? remoteSdp,
  }) async {
    final local = _dtlsFingerprint(localSdp);
    final remote = _dtlsFingerprint(remoteSdp);
    if (local == null || remote == null) return null;
    final lines = ['Loom-CallVerify-v1', local, remote]..sort();
    return derive(utf8.encode(lines.join('\n')));
  }

  /// Derives the code for an MLS group call from the exported call key.
  /// Bound to the call id so two calls in the same epoch never share a code.
  static Future<LoomCallVerification> fromGroupCallKey(
    String callId,
    List<int> key,
  ) =>
      derive(
        utf8.encode('Loom-GroupCallVerify-v1:$callId\n').followedBy(key).toList(),
      );

  static String? _dtlsFingerprint(String? sdp) {
    if (sdp == null) return null;
    final match = RegExp(
      r'a=fingerprint:(?:sha-256|sha-384|sha-512)\s+([0-9A-Fa-f:]+)',
    ).firstMatch(sdp);
    final fingerprint = match?.group(1);
    if (fingerprint == null) return null;
    return fingerprint.toUpperCase().replaceAll(':', '');
  }
}
