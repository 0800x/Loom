import 'package:loom_models/loom_models.dart';

/// ICE gathering usually finishes while the user is still deciding to answer.
/// Hold only candidates belonging to a recent offer for this identity. Limits
/// and expiry keep unsolicited signaling from becoming an unbounded queue.
class LoomIncomingIceBuffer {
  LoomIncomingIceBuffer(this.localIdentityId, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final String localIdentityId;
  final DateTime Function() _now;
  final _offers = <String, _OfferedIce>{};

  void observe(LoomCallSignal signal) {
    final now = _now().toUtc();
    _offers.removeWhere((_, value) => !value.expiresAt.isAfter(now));
    if (signal.targetIdentityId != localIdentityId) return;
    if (signal.kind == 'call.offer' &&
        signal.sdp != null &&
        signal.mediaKind != null) {
      final expires = signal.createdAt.add(const Duration(seconds: 45));
      if (!expires.isAfter(now)) return;
      _offers.putIfAbsent(
        signal.callId,
        () => _OfferedIce(signal.senderIdentityId, expires),
      );
      while (_offers.length > 4) {
        _offers.remove(_offers.keys.first);
      }
    }
    final offer = _offers[signal.callId];
    if (offer == null || offer.peerIdentityId != signal.senderIdentityId) {
      return;
    }
    if (signal.kind == 'call.end' || signal.kind == 'call.reject') {
      _offers.remove(signal.callId);
    } else if (signal.kind == 'call.ice' &&
        signal.candidate != null &&
        offer.candidates.length < 256) {
      offer.candidates.putIfAbsent(signal.sequence, () => signal);
    }
  }

  List<LoomCallSignal> take(String callId, String peerIdentityId) {
    final offer = _offers.remove(callId);
    if (offer == null ||
        offer.peerIdentityId != peerIdentityId ||
        !offer.expiresAt.isAfter(_now().toUtc())) {
      return const [];
    }
    return offer.candidates.values.toList(growable: false);
  }

  void clear() => _offers.clear();
}

class _OfferedIce {
  _OfferedIce(this.peerIdentityId, this.expiresAt);
  final String peerIdentityId;
  final DateTime expiresAt;
  final candidates = <int, LoomCallSignal>{};
}
