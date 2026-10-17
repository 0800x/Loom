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

const MAX_PREKEY_BYTES = 64 * 1024;
const MAX_PREKEY_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_PREKEY_BATCH = 100;

export type V2PrekeyKind = 'one_time' | 'fallback';

export interface V2PrekeyPoolRecord {
  deviceId: string;
  prekeyId: string;
  keyKind: V2PrekeyKind;
  bundleBase64: string;
  publishedAt: string;
  expiresAt: string;
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

function requirePrekeyKind(value: unknown): V2PrekeyKind {
  // Missing kind is legacy-compatible and means one-shot prekey.
  if (value === undefined || value === 'one_time') return 'one_time';
  if (value === 'fallback') return 'fallback';
  throw new Error('invalid_prekey_kind');
}

function recordFromRow(row: Record<string, unknown>): V2PrekeyPoolRecord {
  const keyKind = String(row.key_kind);
  if (keyKind !== 'one_time' && keyKind !== 'fallback') {
    throw new Error('corrupt_prekey_kind');
  }
  return {
    deviceId: String(row.device_id),
    prekeyId: String(row.prekey_id),
    keyKind,
    bundleBase64: String(row.bundle_base64),
    publishedAt: new Date(String(row.published_at)).toISOString(),
    expiresAt: new Date(String(row.expires_at)).toISOString(),
  };
}

function samePublishedPrekey(
  row: Record<string, unknown>,
  keyKind: V2PrekeyKind,
  bundleBase64: string,
  expiresAt: string,
): boolean {
  return (
    String(row.key_kind) === keyKind &&
    String(row.bundle_base64) === bundleBase64 &&
    new Date(String(row.expires_at)).toISOString() === expiresAt
  );
}

/// Dedicated Architecture-v2 prekey pool.
///
/// One-time keys are consumed exactly once. A fallback key is returned only
/// after the one-time pool is exhausted and remains reusable until it expires
/// or a newer fallback is durably published. Publishing a newer fallback
/// atomically retires the previous server-visible fallback while the endpoint
/// may keep the previous private fallback locally for delayed in-flight prekey
/// messages.
///
/// Consumed/retired rows are retained until their original expiry as PrekeyId
/// tombstones so a retry cannot resurrect or mutate old key material.
export class V2PrekeyPool {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string): V2PrekeyPool {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec(
      'PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;',
    );
    const store = new V2PrekeyPool(db);
    store.migrateSqlite();
    return store;
  }

  static async postgresStore(databaseUrl: string): Promise<V2PrekeyPool> {
    const module = (await import('pg')) as unknown as {
      Pool: new (options: Record<string, unknown>) => PgPool;
    };
    const pool = new module.Pool({
      connectionString: databaseUrl,
      max: 4,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000,
      ssl: databaseUrl.includes('sslmode=disable') ? false : undefined,
    });
    const store = new V2PrekeyPool(undefined, pool);
    await store.migratePostgres();
    return store;
  }

  private migrateSqlite(): void {
    this.sqlite!.exec(`
      CREATE TABLE IF NOT EXISTS v2_prekey_pool_v2 (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        prekey_id TEXT NOT NULL,
        key_kind TEXT NOT NULL CHECK(key_kind IN ('one_time','fallback')),
        bundle_base64 TEXT NOT NULL,
        published_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        consumed_at TEXT,
        retired_at TEXT,
        PRIMARY KEY(device_id, prekey_id)
      );
      CREATE INDEX IF NOT EXISTS idx_v2_prekey_pool_claim
        ON v2_prekey_pool_v2(
          device_id,key_kind,consumed_at,retired_at,expires_at,published_at
        );
    `);
  }

  private async migratePostgres(): Promise<void> {
    await this.pool!.query(`
      CREATE TABLE IF NOT EXISTS v2_prekey_pool_v2 (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        prekey_id TEXT NOT NULL,
        key_kind TEXT NOT NULL CHECK(key_kind IN ('one_time','fallback')),
        bundle_base64 TEXT NOT NULL,
        published_at TIMESTAMPTZ NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        consumed_at TIMESTAMPTZ,
        retired_at TIMESTAMPTZ,
        PRIMARY KEY(device_id, prekey_id)
      );
      CREATE INDEX IF NOT EXISTS idx_v2_prekey_pool_claim
        ON v2_prekey_pool_v2(
          device_id,key_kind,consumed_at,retired_at,expires_at,published_at
        );
    `);
  }

  async close(): Promise<void> {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  async publish(
    accountId: string,
    deviceId: string,
    input: unknown,
  ): Promise<{ accepted: number }> {
    if (!Array.isArray(input) || input.length < 1 || input.length > MAX_PREKEY_BATCH) {
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
        keyKind: requirePrekeyKind(value.keyKind),
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
    if (parsed.filter((item) => item.keyKind === 'fallback').length > 1) {
      throw new Error('invalid_fallback_prekey_batch');
    }

    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        if (!this.sqliteDeviceOwner(accountId, deviceId)) {
          throw new Error('device_not_authorized');
        }
        let accepted = 0;
        for (const item of parsed) {
          const existing = this.sqlite
            .prepare(
              'SELECT * FROM v2_prekey_pool_v2 WHERE device_id=? AND prekey_id=?',
            )
            .get(deviceId, item.prekeyId) as Record<string, unknown> | undefined;
          if (existing) {
            if (!samePublishedPrekey(
              existing,
              item.keyKind,
              item.bundleBase64,
              item.expiresAt,
            )) {
              throw new Error('prekey_id_conflict');
            }
            continue;
          }

          const result = this.sqlite
            .prepare(`
              INSERT INTO v2_prekey_pool_v2(
                device_id,prekey_id,key_kind,bundle_base64,published_at,
                expires_at,consumed_at,retired_at
              ) VALUES(?,?,?,?,?,?,NULL,NULL)
            `)
            .run(
              deviceId,
              item.prekeyId,
              item.keyKind,
              item.bundleBase64,
              publishedAt,
              item.expiresAt,
            );
          accepted += Number(result.changes);

          if (item.keyKind === 'fallback') {
            this.sqlite
              .prepare(`
                UPDATE v2_prekey_pool_v2
                SET retired_at=?
                WHERE device_id=?
                  AND key_kind='fallback'
                  AND prekey_id<>?
                  AND retired_at IS NULL
              `)
              .run(publishedAt, deviceId, item.prekeyId);
          }
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
      const owner = await client.query(
        `
          SELECT 1 FROM devices
          WHERE id=$1 AND account_id=$2 AND revoked_at IS NULL
          FOR UPDATE
        `,
        [deviceId, accountId],
      );
      if (owner.rows.length !== 1) throw new Error('device_not_authorized');

      let accepted = 0;
      for (const item of parsed) {
        const existing = (
          await client.query(
            'SELECT * FROM v2_prekey_pool_v2 WHERE device_id=$1 AND prekey_id=$2',
            [deviceId, item.prekeyId],
          )
        ).rows[0];
        if (existing) {
          if (!samePublishedPrekey(
            existing,
            item.keyKind,
            item.bundleBase64,
            item.expiresAt,
          )) {
            throw new Error('prekey_id_conflict');
          }
          continue;
        }

        const inserted = await client.query(
          `
            INSERT INTO v2_prekey_pool_v2(
              device_id,prekey_id,key_kind,bundle_base64,published_at,
              expires_at,consumed_at,retired_at
            ) VALUES($1,$2,$3,$4,$5,$6,NULL,NULL)
          `,
          [
            deviceId,
            item.prekeyId,
            item.keyKind,
            item.bundleBase64,
            publishedAt,
            item.expiresAt,
          ],
        );
        accepted += inserted.rowCount ?? 0;

        if (item.keyKind === 'fallback') {
          await client.query(
            `
              UPDATE v2_prekey_pool_v2
              SET retired_at=$1
              WHERE device_id=$2
                AND key_kind='fallback'
                AND prekey_id<>$3
                AND retired_at IS NULL
            `,
            [publishedAt, deviceId, item.prekeyId],
          );
        }
      }
      await client.query('COMMIT');
      return { accepted };
    } catch (error) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {
        // Preserve the original error.
      }
      throw error;
    } finally {
      client.release();
    }
  }

  async claim(deviceIdInput: unknown): Promise<V2PrekeyPoolRecord | null> {
    const deviceId = requireOpaqueId(deviceIdInput, 'device_id', 256);
    const now = new Date().toISOString();

    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        const oneTime = this.sqlite
          .prepare(`
            SELECT p.*
            FROM v2_prekey_pool_v2 p
            JOIN devices d ON d.id=p.device_id
            WHERE p.device_id=?
              AND d.revoked_at IS NULL
              AND p.key_kind='one_time'
              AND p.consumed_at IS NULL
              AND p.retired_at IS NULL
              AND p.expires_at>?
            ORDER BY p.published_at,p.prekey_id
            LIMIT 1
          `)
          .get(deviceId, now) as Record<string, unknown> | undefined;
        if (oneTime) {
          const result = this.sqlite
            .prepare(`
              UPDATE v2_prekey_pool_v2
              SET consumed_at=?
              WHERE device_id=? AND prekey_id=? AND consumed_at IS NULL
            `)
            .run(now, deviceId, String(oneTime.prekey_id));
          if (Number(result.changes) !== 1) {
            throw new Error('prekey_claim_conflict');
          }
          this.sqlite.exec('COMMIT');
          return recordFromRow(oneTime);
        }

        const fallback = this.sqlite
          .prepare(`
            SELECT p.*
            FROM v2_prekey_pool_v2 p
            JOIN devices d ON d.id=p.device_id
            WHERE p.device_id=?
              AND d.revoked_at IS NULL
              AND p.key_kind='fallback'
              AND p.retired_at IS NULL
              AND p.expires_at>?
            ORDER BY p.published_at DESC,p.prekey_id DESC
            LIMIT 1
          `)
          .get(deviceId, now) as Record<string, unknown> | undefined;
        this.sqlite.exec('COMMIT');
        return fallback ? recordFromRow(fallback) : null;
      } catch (error) {
        this.sqlite.exec('ROLLBACK');
        throw error;
      }
    }

    const client = await this.pool!.connect();
    try {
      await client.query('BEGIN');
      const oneTime = (
        await client.query(
          `
            SELECT p.*
            FROM v2_prekey_pool_v2 p
            JOIN devices d ON d.id=p.device_id
            WHERE p.device_id=$1
              AND d.revoked_at IS NULL
              AND p.key_kind='one_time'
              AND p.consumed_at IS NULL
              AND p.retired_at IS NULL
              AND p.expires_at>now()
            ORDER BY p.published_at,p.prekey_id
            FOR UPDATE OF p SKIP LOCKED
            LIMIT 1
          `,
          [deviceId],
        )
      ).rows[0];
      if (oneTime) {
        const result = await client.query(
          `
            UPDATE v2_prekey_pool_v2
            SET consumed_at=now()
            WHERE device_id=$1 AND prekey_id=$2 AND consumed_at IS NULL
          `,
          [deviceId, String(oneTime.prekey_id)],
        );
        if (result.rowCount !== 1) {
          throw new Error('prekey_claim_conflict');
        }
        await client.query('COMMIT');
        return recordFromRow(oneTime);
      }

      const fallback = (
        await client.query(
          `
            SELECT p.*
            FROM v2_prekey_pool_v2 p
            JOIN devices d ON d.id=p.device_id
            WHERE p.device_id=$1
              AND d.revoked_at IS NULL
              AND p.key_kind='fallback'
              AND p.retired_at IS NULL
              AND p.expires_at>now()
            ORDER BY p.published_at DESC,p.prekey_id DESC
            LIMIT 1
          `,
          [deviceId],
        )
      ).rows[0];
      await client.query('COMMIT');
      return fallback ? recordFromRow(fallback) : null;
    } catch (error) {
      try {
        await client.query('ROLLBACK');
      } catch (_) {
        // Preserve the original error.
      }
      throw error;
    } finally {
      client.release();
    }
  }

  /// Retains consumed/retired IDs until expiry so retries cannot resurrect them.
  async prune(): Promise<void> {
    if (this.sqlite) {
      this.sqlite
        .prepare('DELETE FROM v2_prekey_pool_v2 WHERE expires_at<=?')
        .run(new Date().toISOString());
      return;
    }
    await this.pool!.query(
      'DELETE FROM v2_prekey_pool_v2 WHERE expires_at<=now()',
    );
  }

  private sqliteDeviceOwner(accountId: string, deviceId: string): boolean {
    const row = this.sqlite!
      .prepare(
        'SELECT 1 FROM devices WHERE id=? AND account_id=? AND revoked_at IS NULL',
      )
      .get(deviceId, accountId);
    return Boolean(row);
  }
}
