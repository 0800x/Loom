import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

import type { V2DeliveryPacketRecord } from './v2_delivery_store.ts';

type QueryResult = {
  rows: Array<Record<string, unknown>>;
  rowCount: number | null;
};
type PgClient = {
  query(sql: string, values?: unknown[]): Promise<QueryResult>;
  release(): void;
};
type PgPool = {
  query(sql: string, values?: unknown[]): Promise<QueryResult>;
  connect(): Promise<PgClient>;
  end(): Promise<void>;
};

const MAX_PACKET_BYTES = 1024 * 1024 + 4096;
const MAX_PACKET_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_PENDING_PACKETS_PER_MAILBOX = 5000;

function requireOpaqueId(value: unknown, label: string, max = 256): string {
  if (
    typeof value !== 'string' ||
    value.trim() !== value ||
    value.length < 8 ||
    value.length > max ||
    /[\r\n\0]/.test(value)
  ) {
    throw new Error(`invalid_${label}`);
  }
  return value;
}

function requireBase64Url(
  value: unknown,
  label: string,
  minBytes: number,
  maxBytes: number,
): string {
  if (
    typeof value !== 'string' ||
    value.length > Math.ceil((maxBytes * 4) / 3) + 8 ||
    !/^[A-Za-z0-9_-]+$/.test(value)
  ) {
    throw new Error(`invalid_${label}`);
  }
  const bytes = Buffer.from(value, 'base64url');
  if (
    bytes.length < minBytes ||
    bytes.length > maxBytes ||
    bytes.toString('base64url') !== value
  ) {
    throw new Error(`invalid_${label}`);
  }
  return value;
}

function requireFutureIso(
  value: unknown,
  label: string,
  now: number,
  maxLifetimeMs: number,
): string {
  if (typeof value !== 'string' || value.length > 64) {
    throw new Error(`invalid_${label}`);
  }
  const parsed = Date.parse(value);
  if (
    !Number.isFinite(parsed) ||
    parsed <= now ||
    parsed > now + maxLifetimeMs
  ) {
    throw new Error(`invalid_${label}`);
  }
  return new Date(parsed).toISOString();
}

function requirePriority(value: unknown): 'normal' | 'urgent' {
  if (value !== 'normal' && value !== 'urgent') {
    throw new Error('invalid_packet_priority');
  }
  return value;
}

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

function samePacket(
  row: Record<string, unknown>,
  mailboxToken: string,
  envelopeBase64: string,
  expiresAt: string,
  priority: 'normal' | 'urgent',
): boolean {
  return String(row.mailbox_token) === mailboxToken &&
    String(row.envelope_base64) === envelopeBase64 &&
    new Date(String(row.expires_at)).toISOString() === expiresAt &&
    String(row.priority) === priority;
}

export class V2DirectDeliveryStore {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string): V2DirectDeliveryStore {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec(
      'PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;',
    );
    const store = new V2DirectDeliveryStore(db);
    store.migrateSqlite();
    return store;
  }

  static async postgresStore(databaseUrl: string): Promise<V2DirectDeliveryStore> {
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
    const store = new V2DirectDeliveryStore(undefined, pool);
    await store.migratePostgres();
    return store;
  }

  async close(): Promise<void> {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  private migrateSqlite(): void {
    this.sqlite!.exec(`
      CREATE TABLE IF NOT EXISTS v2_direct_delivery_packets (
        packet_id TEXT PRIMARY KEY,
        mailbox_token TEXT NOT NULL,
        envelope_base64 TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        priority TEXT NOT NULL CHECK(priority IN ('normal','urgent')),
        accepted_at TEXT NOT NULL,
        sender_transport_fingerprint TEXT NOT NULL,
        acknowledged_at TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_v2_direct_packets_mailbox
        ON v2_direct_delivery_packets(
          mailbox_token,
          acknowledged_at,
          expires_at,
          accepted_at
        );
      CREATE INDEX IF NOT EXISTS idx_v2_direct_packets_sender
        ON v2_direct_delivery_packets(
          sender_transport_fingerprint,
          accepted_at
        );
    `);
  }

  private async migratePostgres(): Promise<void> {
    await this.pool!.query(`
      CREATE TABLE IF NOT EXISTS v2_direct_delivery_packets (
        packet_id TEXT PRIMARY KEY,
        mailbox_token TEXT NOT NULL,
        envelope_base64 TEXT NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        priority TEXT NOT NULL CHECK(priority IN ('normal','urgent')),
        accepted_at TIMESTAMPTZ NOT NULL,
        sender_transport_fingerprint TEXT NOT NULL,
        acknowledged_at TIMESTAMPTZ
      );
      CREATE INDEX IF NOT EXISTS idx_v2_direct_packets_mailbox
        ON v2_direct_delivery_packets(
          mailbox_token,
          acknowledged_at,
          expires_at,
          accepted_at
        );
      CREATE INDEX IF NOT EXISTS idx_v2_direct_packets_sender
        ON v2_direct_delivery_packets(
          sender_transport_fingerprint,
          accepted_at
        );
    `);
  }

  async enqueuePacket(
    senderTransportFingerprint: string,
    input: Record<string, unknown>,
  ): Promise<{ packetId: string; acceptedAt: string; idempotent: boolean }> {
    const sender = requireOpaqueId(
      senderTransportFingerprint,
      'sender_transport_fingerprint',
      128,
    );
    const packetId = requireOpaqueId(input.packetId, 'packet_id', 128);
    const mailboxToken = requireBase64Url(
      input.mailboxToken,
      'mailbox_token',
      16,
      128,
    );
    const envelopeBase64 = requireBase64Url(
      input.envelopeBase64,
      'packet_envelope',
      1,
      MAX_PACKET_BYTES,
    );
    const priority = requirePriority(input.priority);
    const nowMs = Date.now();
    const expiresAt = requireFutureIso(
      input.expiresAt,
      'packet_expiry',
      nowMs,
      MAX_PACKET_LIFETIME_MS,
    );
    const acceptedAt = new Date(nowMs).toISOString();

    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        const mailbox = this.sqlite.prepare(`
          SELECT expires_at FROM v2_mailboxes
          WHERE mailbox_token=? AND expires_at>?
        `).get(mailboxToken, acceptedAt) as Record<string, unknown> | undefined;
        if (!mailbox) throw new Error('mailbox_unavailable');
        if (Date.parse(expiresAt) > Date.parse(String(mailbox.expires_at))) {
          throw new Error('invalid_packet_expiry');
        }

        const existing = this.sqlite.prepare(`
          SELECT packet_id,mailbox_token,envelope_base64,expires_at,priority,accepted_at
          FROM v2_direct_delivery_packets WHERE packet_id=?
          UNION ALL
          SELECT packet_id,mailbox_token,envelope_base64,expires_at,priority,accepted_at
          FROM v2_delivery_packets WHERE packet_id=?
          LIMIT 1
        `).get(packetId, packetId) as Record<string, unknown> | undefined;
        if (existing) {
          if (!samePacket(existing, mailboxToken, envelopeBase64, expiresAt, priority)) {
            throw new Error('packet_id_conflict');
          }
          this.sqlite.exec('COMMIT');
          return {
            packetId,
            acceptedAt: new Date(String(existing.accepted_at)).toISOString(),
            idempotent: true,
          };
        }

        const count = this.sqlite.prepare(`
          SELECT
            (SELECT COUNT(*) FROM v2_delivery_packets
              WHERE mailbox_token=? AND acknowledged_at IS NULL AND expires_at>?) +
            (SELECT COUNT(*) FROM v2_direct_delivery_packets
              WHERE mailbox_token=? AND acknowledged_at IS NULL AND expires_at>?) AS count
        `).get(mailboxToken, acceptedAt, mailboxToken, acceptedAt) as Record<string, unknown>;
        if (Number(count.count) >= MAX_PENDING_PACKETS_PER_MAILBOX) {
          throw new Error('packet_quota_exceeded');
        }

        this.sqlite.prepare(`
          INSERT INTO v2_direct_delivery_packets(
            packet_id,mailbox_token,envelope_base64,expires_at,priority,
            accepted_at,sender_transport_fingerprint,acknowledged_at
          ) VALUES(?,?,?,?,?,?,?,NULL)
        `).run(
          packetId,
          mailboxToken,
          envelopeBase64,
          expiresAt,
          priority,
          acceptedAt,
          sender,
        );
        this.sqlite.exec('COMMIT');
        return { packetId, acceptedAt, idempotent: false };
      } catch (error) {
        this.sqlite.exec('ROLLBACK');
        throw error;
      }
    }

    const client = await this.pool!.connect();
    try {
      await client.query('BEGIN');
      await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [packetId]);
      const mailbox = (await client.query(`
        SELECT expires_at FROM v2_mailboxes
        WHERE mailbox_token=$1 AND expires_at>now()
      `, [mailboxToken])).rows[0];
      if (!mailbox) throw new Error('mailbox_unavailable');
      if (Date.parse(expiresAt) > Date.parse(String(mailbox.expires_at))) {
        throw new Error('invalid_packet_expiry');
      }

      const existing = (await client.query(`
        SELECT packet_id,mailbox_token,envelope_base64,expires_at,priority,accepted_at
        FROM v2_direct_delivery_packets WHERE packet_id=$1
        UNION ALL
        SELECT packet_id,mailbox_token,envelope_base64,expires_at,priority,accepted_at
        FROM v2_delivery_packets WHERE packet_id=$1
        LIMIT 1
      `, [packetId])).rows[0];
      if (existing) {
        if (!samePacket(existing, mailboxToken, envelopeBase64, expiresAt, priority)) {
          throw new Error('packet_id_conflict');
        }
        await client.query('COMMIT');
        return {
          packetId,
          acceptedAt: new Date(String(existing.accepted_at)).toISOString(),
          idempotent: true,
        };
      }

      const count = (await client.query(`
        SELECT
          (SELECT COUNT(*) FROM v2_delivery_packets
            WHERE mailbox_token=$1 AND acknowledged_at IS NULL AND expires_at>now()) +
          (SELECT COUNT(*) FROM v2_direct_delivery_packets
            WHERE mailbox_token=$1 AND acknowledged_at IS NULL AND expires_at>now()) AS count
      `, [mailboxToken])).rows[0];
      if (Number(count.count) >= MAX_PENDING_PACKETS_PER_MAILBOX) {
        throw new Error('packet_quota_exceeded');
      }

      await client.query(`
        INSERT INTO v2_direct_delivery_packets(
          packet_id,mailbox_token,envelope_base64,expires_at,priority,
          accepted_at,sender_transport_fingerprint,acknowledged_at
        ) VALUES($1,$2,$3,$4,$5,$6,$7,NULL)
      `, [
        packetId,
        mailboxToken,
        envelopeBase64,
        expiresAt,
        priority,
        acceptedAt,
        sender,
      ]);
      await client.query('COMMIT');
      return { packetId, acceptedAt, idempotent: false };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async pullPackets(
    accountId: string,
    deviceId: string,
    mailboxTokenInput: unknown,
    limitInput: unknown,
  ): Promise<V2DeliveryPacketRecord[]> {
    const mailboxToken = requireBase64Url(
      mailboxTokenInput,
      'mailbox_token',
      16,
      128,
    );
    const limit = typeof limitInput === 'number' && Number.isInteger(limitInput)
      ? limitInput
      : 50;
    if (limit < 1 || limit > 100) throw new Error('invalid_packet_limit');
    const now = new Date().toISOString();

    if (this.sqlite) {
      const owner = this.sqlite.prepare(`
        SELECT 1 FROM v2_mailboxes
        WHERE mailbox_token=? AND account_id=? AND device_id=? AND expires_at>?
      `).get(mailboxToken, accountId, deviceId, now);
      if (!owner) throw new Error('mailbox_not_owned');
      const rows = this.sqlite.prepare(`
        SELECT * FROM v2_direct_delivery_packets
        WHERE mailbox_token=? AND acknowledged_at IS NULL AND expires_at>?
        ORDER BY CASE priority WHEN 'urgent' THEN 0 ELSE 1 END,
          accepted_at,packet_id
        LIMIT ?
      `).all(mailboxToken, now, limit) as Array<Record<string, unknown>>;
      return rows.map(packetFromRow);
    }

    const owner = (await this.pool!.query(`
      SELECT 1 FROM v2_mailboxes
      WHERE mailbox_token=$1 AND account_id=$2 AND device_id=$3 AND expires_at>now()
    `, [mailboxToken, accountId, deviceId])).rows[0];
    if (!owner) throw new Error('mailbox_not_owned');
    const rows = (await this.pool!.query(`
      SELECT * FROM v2_direct_delivery_packets
      WHERE mailbox_token=$1 AND acknowledged_at IS NULL AND expires_at>now()
      ORDER BY CASE priority WHEN 'urgent' THEN 0 ELSE 1 END,
        accepted_at,packet_id
      LIMIT $2
    `, [mailboxToken, limit])).rows;
    return rows.map(packetFromRow);
  }

  async acknowledgePacket(
    accountId: string,
    deviceId: string,
    packetIdInput: unknown,
  ): Promise<boolean> {
    const packetId = requireOpaqueId(packetIdInput, 'packet_id', 128);
    const now = new Date().toISOString();
    if (this.sqlite) {
      const result = this.sqlite.prepare(`
        UPDATE v2_direct_delivery_packets
        SET acknowledged_at=?
        WHERE packet_id=? AND acknowledged_at IS NULL
          AND mailbox_token IN (
            SELECT mailbox_token FROM v2_mailboxes
            WHERE account_id=? AND device_id=? AND expires_at>?
          )
      `).run(now, packetId, accountId, deviceId, now);
      return Number(result.changes) === 1;
    }
    const result = await this.pool!.query(`
      UPDATE v2_direct_delivery_packets
      SET acknowledged_at=now()
      WHERE packet_id=$1 AND acknowledged_at IS NULL
        AND mailbox_token IN (
          SELECT mailbox_token FROM v2_mailboxes
          WHERE account_id=$2 AND device_id=$3 AND expires_at>now()
        )
    `, [packetId, accountId, deviceId]);
    return result.rowCount === 1;
  }

  async prune(): Promise<void> {
    if (this.sqlite) {
      this.sqlite.prepare('DELETE FROM v2_direct_delivery_packets WHERE expires_at<=?')
        .run(new Date().toISOString());
      return;
    }
    await this.pool!.query(
      'DELETE FROM v2_direct_delivery_packets WHERE expires_at<=now()',
    );
  }
}
