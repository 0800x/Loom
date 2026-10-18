import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_protocol/loom_protocol.dart';

const String loomLanMulticastAddress = '239.255.67.78';
const int loomLanMulticastPort = 37483;
const String loomLanDiscoveryQuery = 'LOOM_DISCOVER_V1';

class LoomLanDiscoveryResult {
  const LoomLanDiscoveryResult({
    required this.announcement,
    required this.sourceAddress,
  });
  final LoomLanAnnouncement announcement;
  final InternetAddress sourceAddress;
}

class LoomLanDiscoveryClient {
  LoomLanDiscoveryClient({LoomLanAnnouncementVerifier? verifier})
      : verifier = verifier ?? LoomLanAnnouncementVerifier();

  final LoomLanAnnouncementVerifier verifier;

  Future<List<LoomLanDiscoveryResult>> discover({
    required String expectedNodeId,
    required String expectedPublicKey,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    final results = <String, LoomLanDiscoveryResult>{};
    try {
      socket.broadcastEnabled = true;
      socket.send(
        utf8.encode(loomLanDiscoveryQuery),
        InternetAddress(loomLanMulticastAddress),
        loomLanMulticastPort,
      );
      final completer = Completer<void>();
      late final StreamSubscription<RawSocketEvent> subscription;
      subscription = socket.listen((event) async {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          final packet = datagram!;
          if (packet.data.length > 8192) continue;
          try {
            final decoded = jsonDecode(utf8.decode(packet.data));
            if (decoded is! Map<String, Object?>) continue;
            final announcement = LoomLanAnnouncement.fromJson(decoded);
            await verifier.verify(
              announcement,
              expectedNodeId: expectedNodeId,
              expectedPublicKey: expectedPublicKey,
            );
            results['${announcement.nodeId}|${announcement.endpoint}'] =
                LoomLanDiscoveryResult(
              announcement: announcement,
              sourceAddress: packet.address,
            );
          } catch (_) {
            // Discovery traffic is untrusted. Invalid packets are ignored.
          }
        }
      });
      Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;
      await subscription.cancel();
      return results.values.toList(growable: false);
    } finally {
      socket.close();
    }
  }
}
