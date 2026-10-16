import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('schema v1 packet custody migrates without rewriting source bytes', () {
    final directory = Directory.systemTemp.createTempSync('loom-dtn-v1-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final now = DateTime.utc(2026, 9, 5, 12);
    final expires = DateTime.utc(2026, 9, 6, 12);
    final outer = LoomOuterEnvelopeV2(
      packetId: 'packet-migration-0001',
      routingHint: LoomRoutingHintV2(
        scope: LoomRoutingScopeV2.domesticRelay,
        mailboxToken: Uint8List.fromList(List<int>.filled(32, 23)),
      ),
      expiresAtBucket: expires,
      priority: LoomPriorityClassV2.normal,
      initialHopLimit: 4,
      forwardingState: const LoomForwardingStateV2(
        hopsUsed: 0,
        copiesRemaining: 4,
      ),
      encryptedPayload: Uint8List.fromList(<int>[41, 42, 43]),
    );
    final sourceBytes = LoomEnvelopeV2Codec.encodeOuter(outer);

    final legacy = sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE dtn_packets (
        packet_id TEXT PRIMARY KEY,
        origin TEXT NOT NULL,
        operation_id TEXT UNIQUE,
        message_id TEXT,
        wire_bytes BLOB NOT NULL,
        routing_scope TEXT NOT NULL,
        mailbox_token BLOB NOT NULL,
        expires_at TEXT NOT NULL,
        priority TEXT NOT NULL,
        initial_hop_limit INTEGER NOT NULL,
        hops_used INTEGER NOT NULL,
        copies_remaining INTEGER NOT NULL,
        stored_at TEXT NOT NULL,
        state TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT NOT NULL,
        last_error_code TEXT,
        gateway_accepted_at TEXT,
        relay_accepted_at TEXT,
        recipient_confirmed_at TEXT,
        terminal_at TEXT
      )
    ''');
    legacy.execute(
      '''
      INSERT INTO dtn_packets (
        packet_id, origin, operation_id, message_id, wire_bytes,
        routing_scope, mailbox_token, expires_at, priority,
        initial_hop_limit, hops_used, copies_remaining, stored_at, state,
        attempt_count, next_attempt_at, last_error_code,
        gateway_accepted_at, relay_accepted_at, recipient_confirmed_at,
        terminal_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL,
                NULL, NULL, NULL, NULL)
      ''',
      <Object?>[
        outer.packetId,
        LoomDtnPacketOrigin.localOutbound.name,
        'operation-migration-0001',
        'message-migration-0001',
        sourceBytes,
        outer.routingHint.scope.name,
        outer.routingHint.mailboxToken,
        expires.toIso8601String(),
        outer.priority.name,
        outer.initialHopLimit,
        outer.forwardingState.hopsUsed,
        outer.forwardingState.copiesRemaining,
        now.toIso8601String(),
        LoomDtnPacketState.queued.name,
        now.toIso8601String(),
      ],
    );
    legacy.execute('PRAGMA user_version = 1');
    legacy.dispose();

    final migrated = LoomSqlitePacketStore.openFile(path);
    addTearDown(migrated.close);
    final packet = migrated.read(outer.packetId);

    expect(packet, isNotNull);
    expect(packet!.wireBytes, sourceBytes);
    expect(packet.initialCopiesRemaining, 4);
    expect(packet.copiesRemaining, 4);
    expect(migrated.listPreparedTransfers(), isEmpty);

    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        LoomDtnOpportunity(
          opportunityId: 'migration-peer',
          authenticated: true,
          directRecipient: false,
          gatewayClaim: LoomGatewayClaimState.none,
          supportedRelayScopes: const <LoomRoutingScopeV2>{},
          canStoreCarry: true,
          linkQualityPercent: 70,
          congestionPercent: 10,
          batteryConstrained: false,
          recentSuccessfulTransfers: 0,
          recentFailedTransfers: 0,
        ),
      ],
    );
    expect(plan, isNotNull);
    final transfer = migrated.prepareTransfer(
      transmissionId: 'transmission-migration-0001',
      plan: plan!,
      now: now,
    );
    expect(transfer.state, LoomDtnTransferState.prepared);
  });
}
