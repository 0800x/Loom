import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

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
const MAX_PREKEY_BYTES = 64 * 1024;
const MAX_PACKET_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_MAILBOX_LIFETIME_MS = 14 * 24 * 60 * 60 * 1000;
const MAX_PREKEY_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_PENDING_PACKETS_PER_MAILBOX = 5000;

export interface V2MailboxRecord {
  token: string;
  accountId: string;
  deviceId: string;
  expiresAt: string;
  registeredAt: string;
}

export interface V2PrekeyRecord {
  deviceId: string;
  prekeyId: string;
  bundleBase64: string;
  publishedAt: string;
  expiresAt: string;
}

export interface V2DeliveryPacketRecord {
  packetId: string;
  mailboxToken: string;
  envelopeBase64: string;
  expiresAt: string;
  priority: 'normal' | 'urgent';
  acceptedAt: string;
}

function requireOpaqueId(value: unknown, label: string, max = 256): string {
  if (
    typeof value !== 'string' ||
    value.trim() !== value ||
    value.length < 8 ||
    value.length > max ||
    /[\r\n]/.test(value)
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

function mailboxFromRow(row: Record<string, unknown>): V2MailboxRecord {
  return {
    token: String(row.mailbox_token),
    accountId: String(row.account_id),
    deviceId: String(row.device_id),
    expiresAt: new Date(String(row.expires_at)).toISOString(),
    registeredAt: new Date(String(row.registered_at)).toISOString(),
  };
}

function prekeyFromRow(row: Record<string, unknown>): V2PrekeyRecord {
  return {
    deviceId: String(row.device_id),
    prekeyId: String(row.prekey_id),
    bundleBase64: String(row.bundle_base64),
    publishedAt: new Date(String(row.published_at)).toISOString(),
    expiresAt: new Date(String(row.expires_at)).toISOString(),
  };
}

function packetFromRow(
  row: Record<string, unknown>,
): V2DeliveryPacketRecord {
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
  return (
    String(row.mailbox_token) === mailboxToken &&
    String(row.envelope_base64) === envelopeBase64 &&
    new Date(String(row.expires_at)).toISOString() === expiresAt &&
    String(row.priority) === priority
  );
}

export class V2DeliveryStore {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string): V2DeliveryStore {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec(
      'PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;',
    );
    const store = new V2DeliveryStore(db);
    store.migrateSqlite();
    return store;
  }

  static async postgresStore(databaseUrl: string): Promise<V2DeliveryStore> {
    const module = (await import('pg')) as unknown as {
      Pool: new (options: Record<string, unknown>) => PgPool;
    };
    const pool = new module.Pool({
      connectionString: databaseUrl,
      max: 6,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000,
      ssl: databaseUrl.includes('sslmode=disable') ? false : undefined,
    });
    const store = new V2DeliveryStore(undefined, pool);
    await store.migratePostgres();
    return store;
  }

  private migrateSqlite(): void {
    this.sqlite!.exec(`
      CREATE TABLE IF NOT EXISTS v2_mailboxes (
        mailbox_token TEXT PRIMARY KEY,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        expires_at TEXT NOT NULL,
        registered_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_v2_mailboxes_device
        ON v2_mailboxes(device_id, expires_at);

      CREATE TABLE IF NOT EXISTS v2_prekeys (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        prekey_id TEXT NOT NULL,
        bundle_base64 TEXT NOT NULL,
        published_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        consumed_at TEXT,
        PRIMARY KEY(device_id, prekey_id)
      );
      CREATE INDEX IF NOT EXISTS idx_v2_prekeys_available
        ON v2_prekeys(device_id, consumed_at, expires_at, published_at);

      CREATE TABLE IF NOT EXISTS v2_delivery_packets (
        packet_id TEXT PRIMARY KEY,
        mailbox_token TEXT NOT NULL,
        envelope_base64 TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        priority TEXT NOT NULL CHECK(priority IN ('normal','urgent')),
        accepted_at TEXT NOT NULL,
        sender_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        sender_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        acknowledged_at TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_v2_packets_mailbox
        ON v2_delivery_packets(
          mailbox_token,
          acknowledged_at,
          expires_at,
          accepted_at
        );
    `);
  }

  private async migratePostgres(): Promise<void> {
    await this.pool!.query(`
      CREATE TABLE IF NOT EXISTS v2_mailboxes (
        mailbox_token TEXT PRIMARY KEY,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        expires_at TIMESTAMPTZ NOT NULL,
        registered_at TIMESTAMPTZ NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_v2_mailboxes_device
        ON v2_mailboxes(device_id, expires_at);

      CREATE TABLE IF NOT EXISTS v2_prekeys (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        prekey_id TEXT NOT NULL,
        bundle_base64 TEXT NOT NULL,
        published_at TIMESTAMPTZ NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        consumed_at TIMESTAMPTZ,
        PRIMARY KEY(device_id, prekey_id)
      );
      CREATE INDEX IF NOT EXISTS idx_v2_prekeys_available
        ON v2_prekeys(device_id, consumed_at, expires_at, published_at);

      CREATE TABLE IF NOT EXISTS v2_delivery_packets (
        packet_id TEXT PRIMARY KEY,
        mailbox_token TEXT NOT NULL,
        envelope_base64 TEXT NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        priority TEXT NOT NULL CHECK(priority IN ('normal','urgent')),
        accepted_at TIMESTAMPTZ NOT NULL,
        sender_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        sender_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        acknowledged_at TIMESTAMPTZ
      );
      CREATE INDEX IF NOT EXISTS idx_v2_packets_mailbox
        ON v2_delivery_packets(
          mailbox_token,
          acknowledged_at,
          expires_at,
          accepted_at
        );
    `);
  }

  async close(): Promise<void> {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  async registerMailbox(
    accountId: string,
    deviceId: string,
    tokenInput: unknown,
    expiresAtInput: unknown,
  ): Promise<V2MailboxRecord> {
    const token = requireBase64Url(
      tokenInput,
      'mailbox_token',
      16,
      128,
    );
    const nowMs = Date.now();
    const expiresAt = requireFutureIso(
      expiresAtInput,
      'mailbox_expiry',
      nowMs,
      MAX_MAILBOX_LIFETIME_MS,
    );
    const registeredAt = new Date(nowMs).toISOString();

    if (!(await this.deviceOwner(accountId, deviceId))) {
      throw new Error('device_not_authorized');
    }

    if (this.sqlite) {
      const existing = this.sqlite
        .prepare(
          'SELECT account_id,device_id FROM v2_mailboxes WHERE mailbox_token=?',
        )
        .get(token) as Record<string, unknown> | undefined;
      if (
        existing &&
        (String(existing.account_id) !== accountId ||
          String(existing.device_id) !== deviceId)
      ) {
        throw new Error('mailbox_token_in_use');
      }
      this.sqlite
        .prepare(`
          INSERT INTO v2_mailboxes(
            mailbox_token,account_id,device_id,expires_at,registered_at
          ) VALUES(?,?,?,?,?)
          ON CONFLICT(mailbox_token) DO UPDATE SET
            expires_at=excluded.expires_at,
            registered_at=excluded.registered_at
          WHERE v2_mailboxes.account_id=excluded.account_id
            AND v2_mailboxes.device_id=excluded.device_id
        `)
        .run(token, accountId, deviceId, expiresAt, registeredAt);
      return mailboxFromRow(
        this.sqlite
          .prepare('SELECT * FROM v2_mailboxes WHERE mailbox_token=?')
          .get(token) as Record<string, unknown>,
      );
    }

    const existing = (
      await this.pool!.query(
        'SELECT account_id,device_id FROM v2_mailboxes WHERE mailbox_token=$1',
        [token],
      )
    ).rows[0];
    if (
      existing &&
      (String(existing.account_id) !== accountId ||
        String(existing.device_id) !== deviceId)
    ) {
      throw new Error('mailbox_token_in_use');
    }
    await this.pool!.query(
      `
        INSERT INTO v2_mailboxes(
          mailbox_token,account_id,device_id,expires_at,registered_at
        ) VALUES($1,$2,$3,$4,$5)
        ON CONFLICT(mailbox_token) DO UPDATE SET
          expires_at=EXCLUDED.expires_at,
          registered_at=EXCLUDED.registered_at
        WHERE v2_mailboxes.account_id=EXCLUDED.account_id
          AND v2_mailboxes.device_id=EXCLUDED.device_id
      `,
      [token, accountId, deviceId, expiresAt, registeredAt],
    );
    return mailboxFromRow(
      (
        await this.pool!.query(
          'SELECT * FROM v2_mailboxes WHERE mailbox_token=$1',
          [token],
        )
      ).rows[0],
    );
  }

  async publishPrekeys(
    accountId: string,
    deviceId: string,
    input: unknown,
  ): Promise<{ accepted: number }> {
    if (!(await this.deviceOwner(accountId, deviceId))) {
      throw new Error('device_not_authorized');
    }
    if (!Array.isArray(input) || input.length < 1 || input.length > 100) {
      throw new Error('invalid_prekey_batch');
    }
    const nowMs = Date.now();
    const publishedAt = new Date(nowMs).toISOString();
    const parsed = input.map((item) => {
      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        throw new Error('invalid_prekey');
      }
      const value = item as Record<string, unknown>;
      return {
        prekeyId: requireOpaqueId(value.prekeyId, 'prekey_id', 128),
        bundleBase64: requireBase64Url(
          value.bundleBase64,
          'prekey_bundle',
          16,
          MAX_PREKEY_BYTES,
        ),
        expiresAt: requireFutureIso(
          value.expiresAt,
          'prekey_expiry',
          nowMs,
          MAX_PREKEY_LIFETIME_MS,
        ),
      };
    });
    if (new Set(parsed.map((item) => item.prekeyId)).size !== parsed.length) {
      throw new Error('duplicate_prekey_id');
    }

    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        const statement = this.sqlite.prepare(`
          INSERT INTO v2_prekeys(
            device_id,prekey_id,bundle_base64,published_at,expires_at,consumed_at
          ) VALUES(?,?,?,?,?,NULL)
          ON CONFLICT(device_id,prekey_id) DO NOTHING
        `);
        let accepted = 0;
        for (const item of parsed) {
          accepted += Number(
            statement.run(
              deviceId,
              item.prekeyId,
              item.bundleBase64,
              publishedAt,
              item.expiresAt,
            ).changes,
          );
        }
        this.sqlite.exec('COMMIT');
        return { accepted };
      } catch (error) {
        this.sqlite.exec('ROLLBACK');
        throw error;
      }
    }

    const client = await this.pool!.connect();
    try {
      await client.query('BEGIN');
      let accepted = 0;
      for (const item of parsed) {
        const result = await client.query(
          `
            INSERT INTO v2_prekeys(
              device_id,prekey_id,bundle_base64,
              published_at,expires_at,consumed_at
            ) VALUES($1,$2,$3,$4,$5,NULL)
            ON CONFLICT(device_id,prekey_id) DO NOTHING
          `,
          [
            deviceId,
            item.prekeyId,
            item.bundleBase64,
            publishedAt,
            item.expiresAt,
          ],
        );
        accepted += result.rowCount ?? 0;
      }
      await client.query('COMMIT');
      return { accepted };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async claimPrekey(deviceIdInput: unknown): Promise<V2PrekeyRecord | null> {
    const deviceId = requireOpaqueId(deviceIdInput, 'device_id', 256);
    const now = new Date().toISOString();

    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        const row = this.sqlite
          .prepare(`
            SELECT p.*
            FROM v2_prekeys p
            JOIN devices d ON d.id=p.device_id
            WHERE p.device_id=?
              AND d.revoked_at IS NULL
              AND p.consumed_at IS NULL
              AND p.expires_at>?
            ORDER BY p.published_at,p.prekey_id
            LIMIT 1
          `)
          .get(deviceId, now) as Record<string, unknown> | undefined;
        if (!row) {
          this.sqlite.exec('COMMIT');
          return null;
        }
        const result = this.sqlite
          .prepare(`
            UPDATE v2_prekeys
            SET consumed_at=?
            WHERE device_id=? AND prekey_id=? AND consumed_at IS NULL
          `)
          .run(now, deviceId, String(row.prekey_id));
        if (Number(result.changes) !== 1) {
          throw new Error('prekey_claim_conflict');
        }
        this.sqlite.exec('COMMIT');
        return prekeyFromRow(row);
      } catch (error) {
        this.sqlite.exec('ROLLBACK');
        throw error;
      }
    }

    const client = await this.pool!.connect();
    try {
      await client.query('BEGIN');
      const row = (
        await client.query(
          `
            SELECT p.*
            FROM v2_prekeys p
            JOIN devices d ON d.id=p.device_id
            WHERE p.device_id=$1
              AND d.revoked_at IS NULL
              AND p.consumed_at IS NULL
              AND p.expires_at>now()
            ORDER BY p.published_at,p.prekey_id
            FOR UPDATE OF p SKIP LOCKED
            LIMIT 1
          `,
          [deviceId],
        )
      ).rows[0];
      if (!row) {
        await client.query('COMMIT');
        return null;
      }
      const result = await client.query(
        `
          UPDATE v2_prekeys
          SET consumed_at=now()
          WHERE device_id=$1 AND prekey_id=$2 AND consumed_at IS NULL
        `,
        [deviceId, String(row.prekey_id)],
      );
      if (result.rowCount !== 1) {
        throw new Error('prekey_claim_conflict');
      }
      await client.query('COMMIT');
      return prekeyFromRow(row);
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async enqueuePacket(
    senderAccountId: string,
    senderDeviceId: string,
    input: Record<string, unknown>,
  ): Promise<{ packetId: string; acceptedAt: string; idempotent: boolean }> {
    if (!(await this.deviceOwner(senderAccountId, senderDeviceId))) {
      throw new Error('device_not_authorized');
    }
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

    const mailbox = await this.mailboxOwner(mailboxToken);
    if (!mailbox || Date.parse(mailbox.expiresAt) <= nowMs) {
      throw new Error('mailbox_unavailable');
    }
    if (Date.parse(expiresAt) > Date.parse(mailbox.expiresAt)) {
      throw new Error('invalid_packet_expiry');
    }

    const existing = await this.packetById(packetId);
    if (existing) {
      if (
        !samePacket(
          existing,
          mailboxToken,
          envelopeBase64,
          expiresAt,
          priority,
        )
      ) {
        throw new Error('packet_id_conflict');
      }
      return {
        packetId,
        acceptedAt: new Date(String(existing.accepted_at)).toISOString(),
        idempotent: true,
      };
    }

    if ((await this.pendingPacketCount(mailboxToken)) >= MAX_PENDING_PACKETS_PER_MAILBOX) {
      throw new Error('packet_quota_exceeded');
    }

    if (this.sqlite) {
      const result = this.sqlite
        .prepare(`
          INSERT OR IGNORE INTO v2_delivery_packets(
            packet_id,mailbox_token,envelope_base64,expires_at,priority,
            accepted_at,sender_account_id,sender_device_id,acknowledged_at
          ) VALUES(?,?,?,?,?,?,?,?,NULL)
        `)
        .run(
          packetId,
          mailboxToken,
          envelopeBase64,
          expiresAt,
          priority,
          acceptedAt,
          senderAccountId,
          senderDeviceId,
        );
      if (Number(result.changes) === 1) {
        return { packetId, acceptedAt, idempotent: false };
      }
      const raced = await this.packetById(packetId);
      if (
        !raced ||
        !samePacket(
          raced,
          mailboxToken,
          envelopeBase64,
          expiresAt,
          priority,
        )
      ) {
        throw new Error('packet_id_conflict');
      }
      return {
        packetId,
        acceptedAt: new Date(String(raced.accepted_at)).toISOString(),
        idempotent: true,
      };
    }

    const inserted = await this.pool!.query(
      `
        INSERT INTO v2_delivery_packets(
          packet_id,mailbox_token,envelope_base64,expires_at,priority,
          accepted_at,sender_account_id,sender_device_id,acknowledged_at
        ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,NULL)
        ON CONFLICT(packet_id) DO NOTHING
      `,
      [
        packetId,
        mailboxToken,
        envelopeBase64,
        expiresAt,
        priority,
        acceptedAt,
        senderAccountId,
        senderDeviceId,
      ],
    );
    if (inserted.rowCount === 1) {
      return { packetId, acceptedAt, idempotent: false };
    }
    const raced = await this.packetById(packetId);
    if (
      !raced ||
      !samePacket(
        raced,
        mailboxToken,
        envelopeBase64,
        expiresAt,
        priority,
      )
    ) {
      throw new Error('packet_id_conflict');
    }
    return {
      packetId,
      acceptedAt: new Date(String(raced.accepted_at)).toISOString(),
      idempotent: true,
    };
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
    const limit =
      typeof limitInput === 'number' && Number.isInteger(limitInput)
        ? limitInput
        : 50;
    if (limit < 1 || limit > 100) {
      throw new Error('invalid_packet_limit');
    }
    const mailbox = await this.mailboxOwner(mailboxToken);
    if (
      !mailbox ||
      mailbox.accountId !== accountId ||
      mailbox.deviceId !== deviceId ||
      Date.parse(mailbox.expiresAt) <= Date.now()
    ) {
      throw new Error('mailbox_not_owned');
    }
    const now = new Date().toISOString();
    if (this.sqlite) {
      const rows = this.sqlite
        .prepare(`
          SELECT * FROM v2_delivery_packets
          WHERE mailbox_token=?
            AND acknowledged_at IS NULL
            AND expires_at>?
          ORDER BY
            CASE priority WHEN 'urgent' THEN 0 ELSE 1 END,
            accepted_at,
            packet_id
          LIMIT ?
        `)
        .all(mailboxToken, now, limit) as Array<Record<string, unknown>>;
      return rows.map(packetFromRow);
    }
    const rows = (
      await this.pool!.query(
        `
          SELECT * FROM v2_delivery_packets
          WHERE mailbox_token=$1
            AND acknowledged_at IS NULL
            AND expires_at>now()
          ORDER BY
            CASE priority WHEN 'urgent' THEN 0 ELSE 1 END,
            accepted_at,
            packet_id
          LIMIT $2
        `,
        [mailboxToken, limit],
      )
    ).rows;
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
      const result = this.sqlite
        .prepare(`
          UPDATE v2_delivery_packets
          SET acknowledged_at=?
          WHERE packet_id=?
            AND acknowledged_at IS NULL
            AND mailbox_token IN (
              SELECT mailbox_token FROM v2_mailboxes
              WHERE account_id=? AND device_id=? AND expires_at>?
            )
        `)
        .run(now, packetId, accountId, deviceId, now);
      return Number(result.changes) === 1;
    }
    const result = await this.pool!.query(
      `
        UPDATE v2_delivery_packets
        SET acknowledged_at=now()
        WHERE packet_id=$1
          AND acknowledged_at IS NULL
          AND mailbox_token IN (
            SELECT mailbox_token FROM v2_mailboxes
            WHERE account_id=$2 AND device_id=$3 AND expires_at>now()
          )
      `,
      [packetId, accountId, deviceId],
    );
    return result.rowCount === 1;
  }

  /// Removes expired material while retaining acknowledged PacketIds until
  /// their original expiry. Those rows are dedup tombstones and prevent a late
  /// retry from resurrecting a packet after mailbox transfer acknowledgement.
  async prune(): Promise<void> {
    const now = new Date().toISOString();
    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        this.sqlite
          .prepare('DELETE FROM v2_delivery_packets WHERE expires_at<=?')
          .run(now);
        this.sqlite
          .prepare(
            'DELETE FROM v2_prekeys WHERE expires_at<=? OR consumed_at IS NOT NULL',
          )
          .run(now);
        this.sqlite
          .prepare('DELETE FROM v2_mailboxes WHERE expires_at<=?')
          .run(now);
        this.sqlite.exec('COMMIT');
      } catch (error) {
        this.sqlite.exec('ROLLBACK');
        throw error;
      }
      return;
    }
    await this.pool!.query(
      'DELETE FROM v2_delivery_packets WHERE expires_at<=now()',
    );
    await this.pool!.query(
      'DELETE FROM v2_prekeys WHERE expires_at<=now() OR consumed_at IS NOT NULL',
    );
    await this.pool!.query(
      'DELETE FROM v2_mailboxes WHERE expires_at<=now()',
    );
  }

  private async deviceOwner(
    accountId: string,
    deviceId: string,
  ): Promise<boolean> {
    if (this.sqlite) {
      const row = this.sqlite
        .prepare(
          'SELECT 1 FROM devices WHERE id=? AND account_id=? AND revoked_at IS NULL',
        )
        .get(deviceId, accountId);
      return Boolean(row);
    }
    const result = await this.pool!.query(
      `
        SELECT 1 FROM devices
        WHERE id=$1 AND account_id=$2 AND revoked_at IS NULL
      `,
      [deviceId, accountId],
    );
    return result.rows.length === 1;
  }

  private async mailboxOwner(token: string): Promise<V2MailboxRecord | null> {
    let row: Record<string, unknown> | undefined;
    if (this.sqlite) {
      row = this.sqlite
        .prepare('SELECT * FROM v2_mailboxes WHERE mailbox_token=?')
        .get(token) as Record<string, unknown> | undefined;
    } else {
      row = (
        await this.pool!.query(
          'SELECT * FROM v2_mailboxes WHERE mailbox_token=$1',
          [token],
        )
      ).rows[0];
    }
    return row ? mailboxFromRow(row) : null;
  }

  private async packetById(
    packetId: string,
  ): Promise<Record<string, unknown> | undefined> {
    if (this.sqlite) {
      return this.sqlite
        .prepare('SELECT * FROM v2_delivery_packets WHERE packet_id=?')
        .get(packetId) as Record<string, unknown> | undefined;
    }
    return (
      await this.pool!.query(
        'SELECT * FROM v2_delivery_packets WHERE packet_id=$1',
        [packetId],
      )
    ).rows[0];
  }

  private async pendingPacketCount(mailboxToken: string): Promise<number> {
    if (this.sqlite) {
      const row = this.sqlite
        .prepare(`
          SELECT COUNT(*) count FROM v2_delivery_packets
          WHERE mailbox_token=?
            AND acknowledged_at IS NULL
            AND expires_at>?
        `)
        .get(mailboxToken, new Date().toISOString()) as Record<
        string,
        unknown
      >;
      return Number(row.count);
    }
    const row = (
      await this.pool!.query(
        `
          SELECT COUNT(*) count FROM v2_delivery_packets
          WHERE mailbox_token=$1
            AND acknowledged_at IS NULL
            AND expires_at>now()
        `,
        [mailboxToken],
      )
    ).rows[0];
    return Number(row.count);
  }
}
