import 'dart:io';

import 'package:loom_protocol/loom_protocol.dart';

import 'packet_store.dart';
import 'router.dart';

enum LoomDtnStoragePressure { normal, elevated, critical }

final class LoomDtnStorageMetrics {
  const LoomDtnStorageMetrics({
    required this.databaseBytes,
    required this.walBytes,
    required this.shmBytes,
  });

  final int databaseBytes;
  final int walBytes;
  final int shmBytes;

  int get totalBytes => databaseBytes + walBytes + shmBytes;
}

abstract interface class LoomDtnStorageMetricsSource {
  LoomDtnStorageMetrics readMetrics();
}

/// Real file-backed metrics source for a SQLite DTN database.
///
/// The WAL and shared-memory sidecars are included because a pressure policy
/// based only on the main `.sqlite3` file can underestimate live disk usage.
final class LoomSqliteDtnStorageMetricsSource
    implements LoomDtnStorageMetricsSource {
  const LoomSqliteDtnStorageMetricsSource(this.databasePath);

  final String databasePath;

  @override
  LoomDtnStorageMetrics readMetrics() => LoomDtnStorageMetrics(
        databaseBytes: _length(databasePath),
        walBytes: _length('$databasePath-wal'),
        shmBytes: _length('$databasePath-shm'),
      );

  static int _length(String path) {
    final file = File(path);
    try {
      return file.existsSync() ? file.lengthSync() : 0;
    } on FileSystemException {
      return 0;
    }
  }
}

final class LoomDtnStorageMaintenanceResult {
  const LoomDtnStorageMaintenanceResult({
    required this.pressure,
    required this.metrics,
    required this.expiredPackets,
    required this.prunedTerminalPackets,
  });

  final LoomDtnStoragePressure pressure;
  final LoomDtnStorageMetrics metrics;
  final int expiredPackets;
  final int prunedTerminalPackets;
}

/// Bounded storage-pressure policy for durable DTN custody.
///
/// Maintenance is intentionally conservative:
/// 1. mark packets whose TTL has elapsed;
/// 2. prune only terminal tombstones old enough for retention policy;
/// 3. if pressure remains high, reduce *future forwarding/replication* rather
///    than deleting live packets.
///
/// A live packet is never silently discarded merely because the device is low
/// on the configured DTN storage budget.
final class LoomDtnStoragePressureController {
  LoomDtnStoragePressureController({
    required this.packetStore,
    required this.metricsSource,
    this.maximumBytes = 256 * 1024 * 1024,
    this.elevatedFraction = 0.75,
    this.criticalFraction = 0.90,
    this.tombstoneRetention = const Duration(days: 30),
    LoomMessageRouter? router,
  }) : router = router ?? const LoomMessageRouter() {
    if (maximumBytes < 8 * 1024 * 1024 ||
        maximumBytes > 8 * 1024 * 1024 * 1024 ||
        elevatedFraction <= 0 ||
        elevatedFraction >= criticalFraction ||
        criticalFraction >= 1 ||
        tombstoneRetention < const Duration(days: 7) ||
        tombstoneRetention > const Duration(days: 180)) {
      throw const FormatException('Invalid DTN storage pressure policy');
    }
  }

  final LoomPacketStore packetStore;
  final LoomDtnStorageMetricsSource metricsSource;
  final int maximumBytes;
  final double elevatedFraction;
  final double criticalFraction;
  final Duration tombstoneRetention;
  final LoomMessageRouter router;

  LoomDtnStorageMaintenanceResult maintain(DateTime now) {
    final timestamp = now.toUtc();
    final expired = packetStore.expireDue(timestamp);
    final pruned = packetStore.pruneTerminal(
      timestamp,
      tombstoneRetention: tombstoneRetention,
    );
    final metrics = metricsSource.readMetrics();
    return LoomDtnStorageMaintenanceResult(
      pressure: classify(metrics),
      metrics: metrics,
      expiredPackets: expired,
      prunedTerminalPackets: pruned,
    );
  }

  LoomDtnStoragePressure classify(LoomDtnStorageMetrics metrics) {
    if (metrics.databaseBytes < 0 ||
        metrics.walBytes < 0 ||
        metrics.shmBytes < 0) {
      throw const FormatException('Negative DTN storage metric');
    }
    final ratio = metrics.totalBytes / maximumBytes;
    if (ratio >= criticalFraction) return LoomDtnStoragePressure.critical;
    if (ratio >= elevatedFraction) return LoomDtnStoragePressure.elevated;
    return LoomDtnStoragePressure.normal;
  }

  /// Pressure-aware wrapper around the deterministic router.
  ///
  /// Direct-recipient delivery remains allowed because it does not create a
  /// new relay replica. Under elevated pressure only direct recipients and
  /// recently verified gateways remain candidates. Under critical pressure,
  /// normal-priority packets are limited to a direct recipient; urgent packets
  /// may also hand custody to a recently verified gateway.
  LoomDtnTransferPlan? planNext({
    required LoomStoredDtnPacket packet,
    required Iterable<LoomDtnOpportunity> opportunities,
    required DateTime now,
    required LoomDtnStoragePressure pressure,
  }) {
    final filtered = opportunities.where((opportunity) {
      if (!opportunity.authenticated) return false;
      if (opportunity.directRecipient) return true;
      switch (pressure) {
        case LoomDtnStoragePressure.normal:
          return true;
        case LoomDtnStoragePressure.elevated:
          return opportunity.gatewayClaim ==
              LoomGatewayClaimState.verifiedRecently;
        case LoomDtnStoragePressure.critical:
          return packet.priority == LoomPriorityClassV2.urgent &&
              opportunity.gatewayClaim ==
                  LoomGatewayClaimState.verifiedRecently;
      }
    });
    return router.planNext(packet: packet, opportunities: filtered, now: now);
  }
}
