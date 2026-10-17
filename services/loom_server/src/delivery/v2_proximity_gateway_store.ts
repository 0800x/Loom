import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import type { V2DeliveryPacketRecord } from './v2_delivery_store.ts';
import type { V2ProximityGatewayLease } from './v2_proximity_gateway_auth.ts';

type QueryResult = {
  rows: Array<Record<string, unknown>>;
  rowCount: number | null;
};
type PgPool = {
  query(sql: string, values?: unknown[]): Promise<QueryResult>;
  end(): Promise<void>;
};

function packetFromRow(row: Record<string, unknown>): V2DeliveryPacketRecord {
  const priority = String(row.priority);
  if (priority !== 'normal' && priority !== 'urgent') {
    throw new Error('corrupt_packet_priority');
  }
  return {
    packetId: String(row.packet_id),
    mailboxToken: String(row.mailbox_token),
    envelopeBase64: String(row.envelope_base64),
    expiresAt: new Date(String(row.expires_at)).toISOString(),
    priority,
    acceptedAt: new Date(String(row.accepted_at)).toISOString(),
  };
}

function requireLeaseId(value: unknown): string {
  if (
    typeof value !== 'string' ||
    value.trim() !== value ||
    value.length < 8 ||
    value.length > 128 ||
    /[\r\n\0]/.test(value)
  ) {
    throw new Error('invalid_gateway_lease_id');
  }
  return value;
}

function requireDeviceId(value: unknown): string {
  if (
    typeof value !== 'string' ||
    value.trim() !== value ||
    value.length < 8 ||
    value.length > 256 ||
    /[\r\n\0]/.test(value)
  ) {
    throw new Error('invalid_gateway_recipient_device_id');
  }
  return value;
}

function requireLimit(value: unknown): number {
  const limit = value == null ? 20 : Number(value);
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) {
    throw new Error('invalid_gateway_packet_limit');
  }
  return limit;
}

export class V2ProximityGatewayStore {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string): V2ProximityGatewayStore {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec(
      'PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;',
    );
    const store = new V2ProximityGatewayStore(db);
    store.migrateSqlite();
    return store;
  }

  static async postgresStore(databaseUrl: string): Promise<V2ProximityGatewayStore> {
    const module = (await import('pg')) as unknown as {
      Pool: new (options: Record<string, unknown>) => PgPool;
    };
    const pool = new module.Pool({
      connectionString: databaseUrl,
      max: 3,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000,
      ssl: databaseUrl.includes('sslmode=disable') ? false : undefined,
    });
    const store = new V2ProximityGatewayStore(undefined, pool);
    await store.migratePostgres();
    return store;
  }

  async close(): Promise<void> {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  private migrateSqlite(): void {
    this.sqlite!.exec(`
      CREATE TABLE IF NOT EXISTS v2_proximity_gateway_leases (
        lease_id TEXT PRIMARY KEY,
        recipient_identity_id TEXT NOT NULL,
        recipient_device_id TEXT NOT NULL,
        gateway_fingerprint TEXT NOT NULL,
        gateway_public_key TEXT NOT NULL,
        bearer TEXT NOT NULL,
        issued_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        max_packets INTEGER NOT NULL,
        max_bytes INTEGER NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_v2_gateway_leases_recipient
        ON v2_proximity_gateway_leases(recipient_device_id, expires_at);
      CREATE INDEX IF NOT EXISTS idx_v2_gateway_leases_gateway
        ON v2_proximity_gateway_leases(gateway_fingerprint, expires_at);

      CREATE TABLE IF NOT EXISTS v2_proximity_gateway_custody (
        lease_id TEXT NOT NULL REFERENCES v2_proximity_gateway_leases(lease_id) ON DELETE CASCADE,
        packet_id TEXT NOT NULL,
        gateway_fingerprint TEXT NOT NULL,
        accepted_at TEXT NOT NULL,
        PRIMARY KEY(lease_id, packet_id)
      );

      CREATE TABLE IF NOT EXISTS v2_proximity_gateway_nonces (
        gateway_fingerprint TEXT NOT NULL,
        nonce TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY(gateway_fingerprint, nonce)
      );
      CREATE INDEX IF NOT EXISTS idx_v2_gateway_nonces_expiry
        ON v2_proximity_gateway_nonces(expires_at);
    `);
  }

  private async migratePostgres(): Promise<void> {
    await this.pool!.query(`
      CREATE TABLE IF NOT EXISTS v2_proximity_gateway_leases (
        lease_id TEXT PRIMARY KEY,
        recipient_identity_id TEXT NOT NULL,
        recipient_device_id TEXT NOT NULL,
        gateway_fingerprint TEXT NOT NULL,
        gateway_public_key TEXT NOT NULL,
        bearer TEXT NOT NULL,
        issued_at TIMESTAMPTZ NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        max_packets INTEGER NOT NULL,
        max_bytes INTEGER NOT NULL,
        created_at TIMESTAMPTZ NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_v2_gateway_leases_recipient
        ON v2_proximity_gateway_leases(recipient_device_id, expires_at);
      CREATE INDEX IF NOT EXISTS idx_v2_gateway_leases_gateway
        ON v2_proximity_gateway_leases(gateway_fingerprint, expires_at);

      CREATE TABLE IF NOT EXISTS v2_proximity_gateway_custody (
        lease_id TEXT NOT NULL REFERENCES v2_proximity_gateway_leases(lease_id) ON DELETE CASCADE,
        packet_id TEXT NOT NULL,
        gateway_fingerprint TEXT NOT NULL,
        accepted_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY(lease_id, packet_id)
      );

      CREATE TABLE IF NOT EXISTS v2_proximity_gateway_nonces (
        gateway_fingerprint TEXT NOT NULL,
        nonce TEXT NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY(gateway_fingerprint, nonce)
      );
      CREATE INDEX IF NOT EXISTS idx_v2_gateway_nonces_expiry
        ON v2_proximity_gateway_nonces(expires_at);
    `);
  }

  async registerLease(lease: V2ProximityGatewayLease): Promise<void> {
    const createdAt = new Date().toISOString();
    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        this.cleanupSqlite(createdAt);
        const existing = this.sqlite.prepare(`
          SELECT * FROM v2_proximity_gateway_leases WHERE lease_id=?
        `).get(lease.leaseId) as Record<string, unknown> | undefined;
        if (existing) {
          const same =
            String(existing.recipient_identity_id) === lease.recipientIdentityId &&
            String(existing.recipient_device_id) === lease.recipientDeviceId &&
            String(existing.gateway_fingerprint) === lease.gatewayFingerprint &&
            String(existing.gateway_public_key) === lease.gatewayDevicePublicKey &&
            String(existing.expires_at) === lease.expiresAt;
          if (!same) throw new Error('gateway_lease_id_conflict');
          this.sqlite.exec('COMMIT');
          return;
        }
        this.sqlite.prepare(`
          INSERT INTO v2_proximity_gateway_leases(
            lease_id,recipient_identity_id,recipient_device_id,
            gateway_fingerprint,gateway_public_key,bearer,issued_at,expires_at,
            max_packets,max_bytes,created_at
          ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
        `).run(
          lease.leaseId,
          lease.recipientIdentityId,
          lease.recipientDeviceId,
          lease.gatewayFingerprint,
          lease.gatewayDevicePublicKey,
          lease.bearer,
          lease.issuedAt,
          lease.expiresAt,
          lease.maxPackets,
          lease.maxBytes,
          createdAt,
        );
        this.sqlite.exec('COMMIT');
      } catch (error) {
        this.sqlite.exec('ROLLBACK');
        throw error;
      }
      return;
    }

    await this.cleanupPostgres();
    const existing = (await this.pool!.query(
      'SELECT * FROM v2_proximity_gateway_leases WHERE lease_id=$1',
      [lease.leaseId],
    )).rows[0];
    if (existing) {
      const same =
        String(existing.recipient_identity_id) === lease.recipientIdentityId &&
        String(existing.recipient_device_id) === lease.recipientDeviceId &&
        String(existing.gateway_fingerprint) === lease.gatewayFingerprint &&
        String(existing.gateway_public_key) === lease.gatewayDevicePublicKey &&
        new Date(String(existing.expires_at)).toISOString() === lease.expiresAt;
      if (!same) throw new Error('gateway_lease_id_conflict');
      return;
    }
    await this.pool!.query(`
      INSERT INTO v2_proximity_gateway_leases(
        lease_id,recipient_identity_id,recipient_device_id,
        gateway_fingerprint,gateway_public_key,bearer,issued_at,expires_at,
        max_packets,max_bytes,created_at
      ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
    `, [
      lease.leaseId,
      lease.recipientIdentityId,
      lease.recipientDeviceId,
      lease.gatewayFingerprint,
      lease.gatewayDevicePublicKey,
      lease.bearer,
      lease.issuedAt,
      lease.expiresAt,
      lease.maxPackets,
      lease.maxBytes,
      createdAt,
    ]);
  }

  async activeLease(
    leaseIdInput: unknown,
    recipientDeviceIdInput: unknown,
    gatewayFingerprint: string,
  ): Promise<Record<string, unknown>> {
    const leaseId = requireLeaseId(leaseIdInput);
    const recipientDeviceId = requireDeviceId(recipientDeviceIdInput);
    const now = new Date().toISOString();
    let row: Record<string, unknown> | undefined;
    if (this.sqlite) {
      this.cleanupSqlite(now);
      row = this.sqlite.prepare(`
        SELECT * FROM v2_proximity_gateway_leases
        WHERE lease_id=? AND recipient_device_id=?
          AND gateway_fingerprint=? AND expires_at>?
      `).get(leaseId, recipientDeviceId, gatewayFingerprint, now) as
        Record<string, unknown> | undefined;
    } else {
      await this.cleanupPostgres();
      row = (await this.pool!.query(`
        SELECT * FROM v2_proximity_gateway_leases
        WHERE lease_id=$1 AND recipient_device_id=$2
          AND gateway_fingerprint=$3 AND expires_at>now()
      `, [leaseId, recipientDeviceId, gatewayFingerprint])).rows[0];
    }
    if (!row) throw new Error('gateway_lease_unavailable');
    return row;
  }

  async rememberNonce(
    gatewayFingerprint: string,
    nonce: string,
    expiresAt: Date,
  ): Promise<boolean> {
    const now = new Date().toISOString();
    if (this.sqlite) {
      this.sqlite.prepare(
        'DELETE FROM v2_proximity_gateway_nonces WHERE expires_at<=?',
      ).run(now);
      const result = this.sqlite.prepare(`
        INSERT OR IGNORE INTO v2_proximity_gateway_nonces(
          gateway_fingerprint,nonce,expires_at
        ) VALUES(?,?,?)
      `).run(gatewayFingerprint, nonce, expiresAt.toISOString());
      return Number(result.changes) === 1;
    }
    await this.pool!.query(
      'DELETE FROM v2_proximity_gateway_nonces WHERE expires_at<=now()',
    );
    const result = await this.pool!.query(`
      INSERT INTO v2_proximity_gateway_nonces(
        gateway_fingerprint,nonce,expires_at
      ) VALUES($1,$2,$3) ON CONFLICT DO NOTHING
    `, [gatewayFingerprint, nonce, expiresAt.toISOString()]);
    return result.rowCount === 1;
  }

  async claimPackets(
    leaseIdInput: unknown,
    recipientDeviceIdInput: unknown,
    gatewayFingerprint: string,
    limitInput: unknown,
  ): Promise<V2DeliveryPacketRecord[]> {
    const limit = requireLimit(limitInput);
    const lease = await this.activeLease(
      leaseIdInput,
      recipientDeviceIdInput,
      gatewayFingerprint,
    );
    const effectiveLimit = Math.min(limit, Number(lease.max_packets));
    const maxBytes = Number(lease.max_bytes);
    const leaseId = String(lease.lease_id);
    const recipientDeviceId = String(lease.recipient_device_id);
    const now = new Date().toISOString();

    let rows: Array<Record<string, unknown>>;
    if (this.sqlite) {
      rows = this.sqlite.prepare(`
        SELECT packet_id,mailbox_token,envelope_base64,expires_at,priority,accepted_at
        FROM (
          SELECT p.packet_id,p.mailbox_token,p.envelope_base64,p.expires_at,
                 p.priority,p.accepted_at
          FROM v2_delivery_packets p
          JOIN v2_mailboxes m ON m.mailbox_token=p.mailbox_token
          WHERE m.device_id=? AND m.expires_at>?
            AND p.acknowledged_at IS NULL AND p.expires_at>?
          UNION ALL
          SELECT p.packet_id,p.mailbox_token,p.envelope_base64,p.expires_at,
                 p.priority,p.accepted_at
          FROM v2_direct_delivery_packets p
          JOIN v2_mailboxes m ON m.mailbox_token=p.mailbox_token
          WHERE m.device_id=? AND m.expires_at>?
            AND p.acknowledged_at IS NULL AND p.expires_at>?
        ) packets
        WHERE NOT EXISTS (
          SELECT 1 FROM v2_proximity_gateway_custody c
          WHERE c.lease_id=? AND c.packet_id=packets.packet_id
        )
        ORDER BY CASE priority WHEN 'urgent' THEN 0 ELSE 1 END,
          accepted_at,packet_id
        LIMIT ?
      `).all(
        recipientDeviceId, now, now,
        recipientDeviceId, now, now,
        leaseId,
        effectiveLimit,
      ) as Array<Record<string, unknown>>;
    } else {
      rows = (await this.pool!.query(`
        SELECT packet_id,mailbox_token,envelope_base64,expires_at,priority,accepted_at
        FROM (
          SELECT p.packet_id,p.mailbox_token,p.envelope_base64,p.expires_at,
                 p.priority,p.accepted_at
          FROM v2_delivery_packets p
          JOIN v2_mailboxes m ON m.mailbox_token=p.mailbox_token
          WHERE m.device_id=$1 AND m.expires_at>now()
            AND p.acknowledged_at IS NULL AND p.expires_at>now()
          UNION ALL
          SELECT p.packet_id,p.mailbox_token,p.envelope_base64,p.expires_at,
                 p.priority,p.accepted_at
          FROM v2_direct_delivery_packets p
          JOIN v2_mailboxes m ON m.mailbox_token=p.mailbox_token
          WHERE m.device_id=$1 AND m.expires_at>now()
            AND p.acknowledged_at IS NULL AND p.expires_at>now()
        ) packets
        WHERE NOT EXISTS (
          SELECT 1 FROM v2_proximity_gateway_custody c
          WHERE c.lease_id=$2 AND c.packet_id=packets.packet_id
        )
        ORDER BY CASE priority WHEN 'urgent' THEN 0 ELSE 1 END,
          accepted_at,packet_id
        LIMIT $3
      `, [recipientDeviceId, leaseId, effectiveLimit])).rows;
    }

    const packets: V2DeliveryPacketRecord[] = [];
    let totalBytes = 0;
    for (const row of rows) {
      const packet = packetFromRow(row);
      const size = Buffer.from(packet.envelopeBase64, 'base64url').length;
      if (size > maxBytes) continue;
      if (totalBytes + size > maxBytes) break;
      totalBytes += size;
      packets.push(packet);
    }
    return packets;
  }

  async acknowledgeCustody(
    leaseIdInput: unknown,
    recipientDeviceIdInput: unknown,
    gatewayFingerprint: string,
    packetIdsInput: unknown,
  ): Promise<number> {
    const lease = await this.activeLease(
      leaseIdInput,
      recipientDeviceIdInput,
      gatewayFingerprint,
    );
    if (!Array.isArray(packetIdsInput) || packetIdsInput.length < 1 || packetIdsInput.length > 50) {
      throw new Error('invalid_gateway_packet_ids');
    }
    const packetIds = packetIdsInput.map((value) => {
      if (
        typeof value !== 'string' || value.trim() !== value ||
        value.length < 8 || value.length > 128 || /[\r\n\0]/.test(value)
      ) {
        throw new Error('invalid_gateway_packet_id');
      }
      return value;
    });
    if (new Set(packetIds).size !== packetIds.length) {
      throw new Error('duplicate_gateway_packet_id');
    }
    const acceptedAt = new Date().toISOString();
    let accepted = 0;
    for (const packetId of packetIds) {
      if (this.sqlite) {
        const result = this.sqlite.prepare(`
          INSERT OR IGNORE INTO v2_proximity_gateway_custody(
            lease_id,packet_id,gateway_fingerprint,accepted_at
          ) VALUES(?,?,?,?)
        `).run(String(lease.lease_id), packetId, gatewayFingerprint, acceptedAt);
        accepted += Number(result.changes);
      } else {
        const result = await this.pool!.query(`
          INSERT INTO v2_proximity_gateway_custody(
            lease_id,packet_id,gateway_fingerprint,accepted_at
          ) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING
        `, [String(lease.lease_id), packetId, gatewayFingerprint, acceptedAt]);
        accepted += result.rowCount ?? 0;
      }
    }
    return accepted;
  }

  private cleanupSqlite(now: string): void {
    this.sqlite!.prepare(
      'DELETE FROM v2_proximity_gateway_leases WHERE expires_at<=?',
    ).run(now);
    this.sqlite!.prepare(
      'DELETE FROM v2_proximity_gateway_nonces WHERE expires_at<=?',
    ).run(now);
  }

  private async cleanupPostgres(): Promise<void> {
    await this.pool!.query(
      'DELETE FROM v2_proximity_gateway_leases WHERE expires_at<=now()',
    );
    await this.pool!.query(
      'DELETE FROM v2_proximity_gateway_nonces WHERE expires_at<=now()',
    );
  }
}
