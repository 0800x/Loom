import { createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { decodeCanonicalBase64, verifyRawEd25519 } from '../identity/public_material.ts';
import type { SessionInfo } from '../storage/sqlite_store.ts';

type QueryResult = { rows: Array<Record<string, unknown>>; rowCount: number | null };
type PgClient = { query(sql: string, values?: unknown[]): Promise<QueryResult>; release(): void };
type PgPool = { query(sql: string, values?: unknown[]): Promise<QueryResult>; connect(): Promise<PgClient>; end(): Promise<void> };

export interface DeviceKeyBundleRecord {
  bundleVersion: 1;
  identityId: string;
  deviceId: string;
  deviceName: string;
  signingPublicKey: string;
  agreementPublicKey: string;
  createdAt: string;
  capabilities: string[];
  fingerprint: string;
  deviceSignature: string;
  identitySignature: string;
}

function groupedSha256(value: Buffer): string {
  const hex = createHash('sha256').update(value).digest('hex').toUpperCase();
  return hex.match(/.{1,4}/g)?.join(' ') ?? hex;
}

function tokenHash(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}

function canonicalBytes(bundle: DeviceKeyBundleRecord): Buffer {
  const capabilities = [...bundle.capabilities].sort();
  return Buffer.from(JSON.stringify({
    bundleVersion: bundle.bundleVersion,
    identityId: bundle.identityId,
    deviceId: bundle.deviceId,
    deviceName: bundle.deviceName,
    signingPublicKey: bundle.signingPublicKey,
    agreementPublicKey: bundle.agreementPublicKey,
    createdAt: bundle.createdAt,
    capabilities,
  }), 'utf8');
}

function requireString(object: Record<string, unknown>, key: string, max = 512): string {
  const value = object[key];
  if (typeof value !== 'string') throw new Error('invalid_device_bundle');
  const cleaned = value.trim();
  if (!cleaned || cleaned.length > max || /[\r\n]/.test(cleaned)) throw new Error('invalid_device_bundle');
  return cleaned;
}

function parseBundle(value: unknown): DeviceKeyBundleRecord {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_device_bundle');
  const object = value as Record<string, unknown>;
  if (object.bundleVersion !== 1) throw new Error('unsupported_device_bundle_version');
  const identityId = requireString(object, 'identityId');
  const deviceId = requireString(object, 'deviceId', 256);
  const deviceName = requireString(object, 'deviceName', 100);
  const signingPublicKey = requireString(object, 'signingPublicKey', 128);
  const agreementPublicKey = requireString(object, 'agreementPublicKey', 128);
  const createdAt = requireString(object, 'createdAt', 64);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3}|\.\d{6})?Z$/.test(createdAt) || !Number.isFinite(Date.parse(createdAt))) {
    throw new Error('invalid_device_bundle');
  }
  const capabilitiesRaw = object.capabilities;
  if (!Array.isArray(capabilitiesRaw) || capabilitiesRaw.length < 1 || capabilitiesRaw.length > 16) throw new Error('invalid_device_bundle');
  const capabilities = capabilitiesRaw.map((item) => {
    if (typeof item !== 'string' || !/^[a-z0-9][a-z0-9_.-]{0,63}$/i.test(item)) throw new Error('invalid_device_bundle');
    return item;
  });
  if (new Set(capabilities).size !== capabilities.length) throw new Error('invalid_device_bundle');
  if (!capabilities.includes('signing-ed25519') || !capabilities.includes('agreement-x25519')) throw new Error('invalid_device_bundle');
  decodeCanonicalBase64(signingPublicKey, 32, 'invalid_device_bundle');
  decodeCanonicalBase64(agreementPublicKey, 32, 'invalid_device_bundle');
  const fingerprint = requireString(object, 'fingerprint', 128).toUpperCase();
  const deviceSignature = requireString(object, 'deviceSignature', 128);
  const identitySignature = requireString(object, 'identitySignature', 128);
  decodeCanonicalBase64(deviceSignature, 64, 'invalid_device_bundle');
  decodeCanonicalBase64(identitySignature, 64, 'invalid_device_bundle');
  return { bundleVersion: 1, identityId, deviceId, deviceName, signingPublicKey, agreementPublicKey, createdAt, capabilities, fingerprint, deviceSignature, identitySignature };
}

export function verifyDeviceKeyBundleRecord(
  value: unknown,
  expectedIdentityId: string,
  identityPublicKey: string,
): DeviceKeyBundleRecord {
  const bundle = parseBundle(value);
  if (bundle.identityId !== expectedIdentityId) throw new Error('device_bundle_identity_mismatch');
  const canonical = canonicalBytes(bundle);
  if (groupedSha256(canonical) !== bundle.fingerprint) throw new Error('invalid_device_bundle_fingerprint');
  if (!verifyRawEd25519(canonical, bundle.deviceSignature, bundle.signingPublicKey)) throw new Error('invalid_device_bundle_signature');
  if (!verifyRawEd25519(canonical, bundle.identitySignature, identityPublicKey)) throw new Error('invalid_device_identity_signature');
  return bundle;
}

function fromRow(row: Record<string, unknown>): DeviceKeyBundleRecord {
  const raw = typeof row.bundle_json === 'string' ? JSON.parse(String(row.bundle_json)) : row.bundle_json;
  return parseBundle(raw);
}

export class DeviceBundleStore {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string): DeviceBundleStore {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
    const store = new DeviceBundleStore(db);
    store.migrateSqlite();
    return store;
  }

  static async postgresStore(databaseUrl: string): Promise<DeviceBundleStore> {
    const module = await import('pg') as unknown as { Pool: new (options: Record<string, unknown>) => PgPool };
    const pool = new module.Pool({ connectionString: databaseUrl, max: 6, idleTimeoutMillis: 30_000, connectionTimeoutMillis: 10_000, ssl: databaseUrl.includes('sslmode=disable') ? false : undefined });
    const store = new DeviceBundleStore(undefined, pool);
    await store.migratePostgres();
    return store;
  }

  private migrateSqlite(): void {
    this.sqlite!.exec(`
      CREATE TABLE IF NOT EXISTS device_key_bundles (
        device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        identity_id TEXT NOT NULL,
        signing_public_key TEXT NOT NULL,
        agreement_public_key TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        bundle_json TEXT NOT NULL,
        published_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_device_key_bundles_identity ON device_key_bundles(identity_id);
      CREATE TABLE IF NOT EXISTS device_request_nonces (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        nonce TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY(device_id, nonce)
      );
      CREATE INDEX IF NOT EXISTS idx_device_request_nonces_expiry ON device_request_nonces(expires_at);
    `);
  }

  private async migratePostgres(): Promise<void> {
    await this.pool!.query(`
      CREATE TABLE IF NOT EXISTS device_key_bundles (
        device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        identity_id TEXT NOT NULL,
        signing_public_key TEXT NOT NULL,
        agreement_public_key TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        bundle_json JSONB NOT NULL,
        published_at TIMESTAMPTZ NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_device_key_bundles_identity ON device_key_bundles(identity_id);
      CREATE TABLE IF NOT EXISTS device_request_nonces (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        nonce TEXT NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY(device_id, nonce)
      );
      CREATE INDEX IF NOT EXISTS idx_device_request_nonces_expiry ON device_request_nonces(expires_at);
    `);
  }

  async close(): Promise<void> {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  async publish(accountId: string, sessionIdentityId: string, sessionDeviceId: string, input: unknown): Promise<DeviceKeyBundleRecord> {
    const unverified = parseBundle(input);
    if (unverified.identityId !== sessionIdentityId || unverified.deviceId !== sessionDeviceId) throw new Error('device_bundle_session_mismatch');
    let account: Record<string, unknown> | undefined;
    if (this.sqlite) {
      account = this.sqlite.prepare(`SELECT a.identity_id,a.identity_public_key,d.revoked_at FROM accounts a JOIN devices d ON d.account_id=a.id WHERE a.id=? AND d.id=?`).get(accountId, sessionDeviceId) as Record<string, unknown> | undefined;
    } else {
      account = (await this.pool!.query(`SELECT a.identity_id,a.identity_public_key,d.revoked_at FROM accounts a JOIN devices d ON d.account_id=a.id WHERE a.id=$1 AND d.id=$2`, [accountId, sessionDeviceId])).rows[0];
    }
    if (!account || account.revoked_at != null || String(account.identity_id) !== sessionIdentityId) throw new Error('device_not_authorized');
    const bundle = verifyDeviceKeyBundleRecord(unverified, sessionIdentityId, String(account.identity_public_key));

    let existing: Record<string, unknown> | undefined;
    if (this.sqlite) existing = this.sqlite.prepare(`SELECT fingerprint FROM device_key_bundles WHERE device_id=?`).get(bundle.deviceId) as Record<string, unknown> | undefined;
    else existing = (await this.pool!.query(`SELECT fingerprint FROM device_key_bundles WHERE device_id=$1`, [bundle.deviceId])).rows[0];
    if (existing && String(existing.fingerprint) !== bundle.fingerprint) throw new Error('device_key_change_requires_rotation');

    const now = new Date().toISOString();
    const json = JSON.stringify(bundle);
    if (this.sqlite) {
      this.sqlite.prepare(`INSERT INTO device_key_bundles(device_id,account_id,identity_id,signing_public_key,agreement_public_key,fingerprint,bundle_json,published_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET bundle_json=excluded.bundle_json,published_at=excluded.published_at WHERE device_key_bundles.fingerprint=excluded.fingerprint`)
        .run(bundle.deviceId, accountId, bundle.identityId, bundle.signingPublicKey, bundle.agreementPublicKey, bundle.fingerprint, json, now);
    } else {
      await this.pool!.query(`INSERT INTO device_key_bundles(device_id,account_id,identity_id,signing_public_key,agreement_public_key,fingerprint,bundle_json,published_at) VALUES($1,$2,$3,$4,$5,$6,$7::jsonb,$8) ON CONFLICT(device_id) DO UPDATE SET bundle_json=EXCLUDED.bundle_json,published_at=EXCLUDED.published_at WHERE device_key_bundles.fingerprint=EXCLUDED.fingerprint`, [bundle.deviceId, accountId, bundle.identityId, bundle.signingPublicKey, bundle.agreementPublicKey, bundle.fingerprint, json, now]);
    }
    return bundle;
  }

  async listForIdentity(identityId: string): Promise<DeviceKeyBundleRecord[]> {
    if (!identityId.startsWith('chn:') || identityId.length > 128) throw new Error('invalid_identity');
    if (this.sqlite) {
      const rows = this.sqlite.prepare(`SELECT b.bundle_json FROM device_key_bundles b JOIN devices d ON d.id=b.device_id WHERE b.identity_id=? AND d.revoked_at IS NULL ORDER BY d.created_at`).all(identityId) as Array<Record<string, unknown>>;
      return rows.map(fromRow);
    }
    const result = await this.pool!.query(`SELECT b.bundle_json FROM device_key_bundles b JOIN devices d ON d.id=b.device_id WHERE b.identity_id=$1 AND d.revoked_at IS NULL ORDER BY d.created_at`, [identityId]);
    return result.rows.map(fromRow);
  }

  async signingKeyForSession(accountId: string, identityId: string, deviceId: string): Promise<string | null> {
    let row: Record<string, unknown> | undefined;
    if (this.sqlite) {
      row = this.sqlite.prepare(`SELECT b.signing_public_key,d.revoked_at FROM device_key_bundles b JOIN devices d ON d.id=b.device_id WHERE b.account_id=? AND b.identity_id=? AND b.device_id=?`).get(accountId, identityId, deviceId) as Record<string, unknown> | undefined;
    } else {
      row = (await this.pool!.query(`SELECT b.signing_public_key,d.revoked_at FROM device_key_bundles b JOIN devices d ON d.id=b.device_id WHERE b.account_id=$1 AND b.identity_id=$2 AND b.device_id=$3`, [accountId, identityId, deviceId])).rows[0];
    }
    if (!row || row.revoked_at != null) return null;
    return String(row.signing_public_key);
  }

  async sessionForRefreshToken(refreshToken: string): Promise<SessionInfo | null> {
    if (!refreshToken || refreshToken.length > 1024 || /[\r\n]/.test(refreshToken)) return null;
    let row: Record<string, unknown> | undefined;
    if (this.sqlite) {
      row = this.sqlite.prepare(`SELECT s.account_id,s.device_id,s.refresh_expires_at,a.username,a.identity_id,d.revoked_at FROM sessions s JOIN accounts a ON a.id=s.account_id JOIN devices d ON d.id=s.device_id WHERE s.refresh_hash=?`).get(tokenHash(refreshToken)) as Record<string, unknown> | undefined;
    } else {
      row = (await this.pool!.query(`SELECT s.account_id,s.device_id,s.refresh_expires_at,a.username,a.identity_id,d.revoked_at FROM sessions s JOIN accounts a ON a.id=s.account_id JOIN devices d ON d.id=s.device_id WHERE s.refresh_hash=$1`, [tokenHash(refreshToken)])).rows[0];
    }
    if (!row || row.revoked_at != null || Date.parse(String(row.refresh_expires_at)) <= Date.now()) return null;
    return { accountId: String(row.account_id), deviceId: String(row.device_id), username: String(row.username), identityId: String(row.identity_id) };
  }

  async rememberRequestNonce(deviceId: string, nonce: string, expiresAt: Date): Promise<boolean> {
    const now = new Date().toISOString();
    if (this.sqlite) {
      this.sqlite.prepare(`DELETE FROM device_request_nonces WHERE expires_at<?`).run(now);
      const result = this.sqlite.prepare(`INSERT OR IGNORE INTO device_request_nonces(device_id,nonce,expires_at) VALUES(?,?,?)`).run(deviceId, nonce, expiresAt.toISOString());
      return Number(result.changes) === 1;
    }
    await this.pool!.query(`DELETE FROM device_request_nonces WHERE expires_at<now()`);
    const result = await this.pool!.query(`INSERT INTO device_request_nonces(device_id,nonce,expires_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, [deviceId, nonce, expiresAt.toISOString()]);
    return result.rowCount === 1;
  }

  async revokeDevice(accountId: string, deviceId: string): Promise<boolean> {
    const now = new Date().toISOString();
    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        const result = this.sqlite.prepare(`UPDATE devices SET revoked_at=? WHERE id=? AND account_id=? AND revoked_at IS NULL`).run(now, deviceId, accountId);
        if (Number(result.changes) === 1) this.sqlite.prepare(`DELETE FROM sessions WHERE device_id=? AND account_id=?`).run(deviceId, accountId);
        this.sqlite.exec('COMMIT');
        return Number(result.changes) === 1;
      } catch (error) {
        this.sqlite.exec('ROLLBACK');
        throw error;
      }
    }
    const client = await this.pool!.connect();
    try {
      await client.query('BEGIN');
      const result = await client.query(`UPDATE devices SET revoked_at=$1 WHERE id=$2 AND account_id=$3 AND revoked_at IS NULL`, [now, deviceId, accountId]);
      if (result.rowCount === 1) await client.query(`DELETE FROM sessions WHERE device_id=$1 AND account_id=$2`, [deviceId, accountId]);
      await client.query('COMMIT');
      return result.rowCount === 1;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }
}
