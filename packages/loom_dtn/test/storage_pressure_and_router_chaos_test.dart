import 'dart:math';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 6, 8);

  test(
    'storage pressure never deletes live packets and restricts replication',
    () {
      final store = _FakePacketStore();
      const metrics = _FakeMetricsSource(
        const LoomDtnStorageMetrics(
          databaseBytes: 95,
          walBytes: 0,
          shmBytes: 0,
        ),
      );
      final controller = LoomDtnStoragePressureController(
        packetStore: store,
        metricsSource: metrics,
        maximumBytes: 8 * 1024 * 1024,
      );

      // Classification thresholds are independently tested with a realistic
      // configured budget rather than making the fake 95 bytes exceed policy.
      expect(
        controller.classify(
          const LoomDtnStorageMetrics(
            databaseBytes: 7 * 1024 * 1024,
            walBytes: 512 * 1024,
            shmBytes: 0,
          ),
        ),
        LoomDtnStoragePressure.critical,
      );

      final packet = _packet(
        now,
        copies: 4,
        priority: LoomPriorityClassV2.normal,
      );
      final direct = _opportunity('direct', direct: true);
      final relay = _opportunity('relay', canStoreCarry: true);
      final verifiedGateway = _opportunity(
        'gateway',
        gateway: LoomGatewayClaimState.verifiedRecently,
      );
      final plan = controller.planNext(
        packet: packet,
        opportunities: <LoomDtnOpportunity>[relay, verifiedGateway, direct],
        now: now,
        pressure: LoomDtnStoragePressure.critical,
      );
      expect(plan?.reason, LoomDtnTransferReason.directRecipient);
      expect(store.cancelCalls, 0);
    },
  );

  test('randomized Spray-and-Wait plans conserve bounded copy authority', () {
    final random = Random(0x43484154);
    const router = LoomMessageRouter();
    for (var iteration = 0; iteration < 1000; iteration++) {
      final copies = 1 + random.nextInt(8);
      final packet = _packet(
        now,
        copies: copies,
        priority: random.nextBool()
            ? LoomPriorityClassV2.normal
            : LoomPriorityClassV2.urgent,
      );
      final candidates = <LoomDtnOpportunity>[
        _opportunity(
          'peer-$iteration',
          canStoreCarry: true,
          quality: random.nextInt(101),
          congestion: random.nextInt(101),
        ),
        _opportunity(
          'gateway-$iteration',
          gateway: LoomGatewayClaimState.verifiedRecently,
          quality: random.nextInt(101),
          congestion: random.nextInt(101),
        ),
      ];
      final plan = router.planNext(
        packet: packet,
        opportunities: candidates,
        now: now,
      );
      if (plan == null) continue;
      expect(plan.copiesBefore, copies);
      if (plan.reason == LoomDtnTransferReason.directRecipient) {
        expect(plan.copiesGranted, 0);
        expect(plan.copiesRetainedAfterSuccess, copies);
      } else {
        expect(plan.copiesGranted, inInclusiveRange(1, copies));
        expect(plan.copiesRetainedAfterSuccess, inInclusiveRange(0, copies));
        expect(
          plan.copiesGranted + plan.copiesRetainedAfterSuccess,
          copies,
          reason: 'replication authority must never inflate',
        );
        if (copies == 1) {
          expect(plan.requiresSingleCopyCustodyHandoff, isTrue);
          expect(plan.copiesRetainedAfterSuccess, 0);
        } else {
          expect(plan.requiresSingleCopyCustodyHandoff, isFalse);
          expect(plan.copiesRetainedAfterSuccess, greaterThan(0));
        }
      }
    }
  });
}

LoomStoredDtnPacket _packet(
  DateTime now, {
  required int copies,
  required LoomPriorityClassV2 priority,
}) => LoomStoredDtnPacket(
  packetId: 'packet-chaos-0001',
  origin: LoomDtnPacketOrigin.localOutbound,
  operationId: 'operation-chaos-0001',
  messageId: 'message-chaos-0001',
  wireBytes: Uint8List.fromList(const <int>[1, 2, 3]),
  routingScope: LoomRoutingScopeV2.globalRelay,
  mailboxToken: Uint8List.fromList(List<int>.filled(16, 7)),
  expiresAt: now.add(const Duration(days: 1)),
  priority: priority,
  initialHopLimit: 6,
  hopsUsed: 0,
  initialCopiesRemaining: copies,
  copiesRemaining: copies,
  storedAt: now,
  state: LoomDtnPacketState.queued,
  attemptCount: 0,
  nextAttemptAt: now,
  lastErrorCode: null,
  gatewayAcceptedAt: null,
  relayAcceptedAt: null,
  recipientConfirmedAt: null,
  terminalAt: null,
);

LoomDtnOpportunity _opportunity(
  String id, {
  bool direct = false,
  bool canStoreCarry = false,
  LoomGatewayClaimState gateway = LoomGatewayClaimState.none,
  int quality = 80,
  int congestion = 10,
}) => LoomDtnOpportunity(
  opportunityId: id,
  authenticated: true,
  directRecipient: direct,
  gatewayClaim: gateway,
  supportedRelayScopes: gateway == LoomGatewayClaimState.none
      ? const <LoomRoutingScopeV2>{}
      : const <LoomRoutingScopeV2>{LoomRoutingScopeV2.globalRelay},
  canStoreCarry: canStoreCarry,
  linkQualityPercent: quality,
  congestionPercent: congestion,
  batteryConstrained: false,
  recentSuccessfulTransfers: 0,
  recentFailedTransfers: 0,
);

final class _FakeMetricsSource implements LoomDtnStorageMetricsSource {
  const _FakeMetricsSource(this.value);
  final LoomDtnStorageMetrics value;
  @override
  LoomDtnStorageMetrics readMetrics() => value;
}

final class _FakePacketStore implements LoomPacketStore {
  int cancelCalls = 0;

  @override
  int expireDue(DateTime now) => 0;
  @override
  int pruneTerminal(
    DateTime now, {
    Duration tombstoneRetention = const Duration(days: 30),
  }) => 0;
  @override
  LoomStoredDtnPacket cancelLocal(String packetId, DateTime cancelledAt) {
    cancelCalls++;
    throw UnimplementedError();
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
