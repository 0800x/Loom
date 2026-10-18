import { passwordHasher } from '../security/password_hash.ts';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type { RegistrationInput } from '../storage/sqlite_store.ts';
import { validateIdentityPublicMaterial } from '../identity/public_material.ts';

type QueryResult = { rows: Array<Record<string, unknown>>; rowCount: number | null };
type PgClient = { query(sql: string, values?: unknown[]): Promise<QueryResult>; release(): void };
type PgPool = { query(sql: string, values?: unknown[]): Promise<QueryResult>; connect(): Promise<PgClient>; end(): Promise<void> };

export interface RegistrationRequestView {
  requestId: string;
  username: string;
  displayName: string;
  deviceName: string;
  identityId: string;
  identityFingerprint: string;
  status: 'pending' | 'approved' | 'rejected';
  createdAt: string;
  reviewedAt?: string | null;
  reason?: string | null;
  accountId?: string | null;
}

export interface RegistrationRequestReceipt {
  requestId: string;
  username: string;
  status: 'pending';
  createdAt: string;
}

type NormalizedRegistration = {
  username: string;
  displayName: string;
  deviceName: string;
  identity: ReturnType<typeof validateIdentityPublicMaterial>;
};

function validateInput(input: RegistrationInput): NormalizedRegistration {
  if (input.protocolVersion !== 'Loom-Identity-v1') throw new Error('unsupported_identity_protocol');
  const username = input.username.trim().toLowerCase();
  const displayName = input.displayName.trim();
  const deviceName = input.deviceName.trim().slice(0, 100) || 'Loom device';
  if (!/^[a-z0-9_][a-z0-9_.-]{2,31}$/.test(username)) throw new Error('invalid_username');
  if (displayName.length < 1 || displayName.length > 80) throw new Error('invalid_display_name');
  if (input.password.length < 10 || input.password.length > 512) throw new Error('invalid_password');
  const identity = validateIdentityPublicMaterial(input.identity);
  return { username, displayName, deviceName, identity };
}

function validateStoredIdentity(row: Record<string, unknown>) {
  return validateIdentityPublicMaterial({
    identityId: String(row.identity_id ?? ''),
    publicKey: String(row.identity_public_key ?? ''),
    fingerprint: String(row.identity_fingerprint ?? ''),
  });
}

function view(row: Record<string, unknown>): RegistrationRequestView {
  return {
    requestId: String(row.id),
    username: String(row.username),
    displayName: String(row.display_name),
    deviceName: String(row.device_name),
    identityId: String(row.identity_id),
    identityFingerprint: String(row.identity_fingerprint),
    status: String(row.status) as RegistrationRequestView['status'],
    createdAt: new Date(String(row.created_at)).toISOString(),
    reviewedAt: row.reviewed_at == null ? null : new Date(String(row.reviewed_at)).toISOString(),
    reason: row.review_reason == null ? null : String(row.review_reason),
    accountId: row.account_id == null ? null : String(row.account_id),
  };
}

export class RegistrationApprovalStore {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string): RegistrationApprovalStore {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
    const store = new RegistrationApprovalStore(db);
    store.migrateSqlite();
    return store;
  }

  static async postgresStore(databaseUrl: string): Promise<RegistrationApprovalStore> {
    const module = await import('pg') as unknown as { Pool: new (options: Record<string, unknown>) => PgPool };
    const pool = new module.Pool({ connectionString: databaseUrl, max: 5, idleTimeoutMillis: 30_000, connectionTimeoutMillis: 10_000, ssl: databaseUrl.includes('sslmode=disable') ? false : undefined });
    const store = new RegistrationApprovalStore(undefined, pool);
    await store.migratePostgres();
    return store;
  }

  private migrateSqlite(): void {
    this.sqlite!.exec(`
      CREATE TABLE IF NOT EXISTS registration_requests (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL COLLATE NOCASE,
        display_name TEXT NOT NULL,
        identity_id TEXT NOT NULL,
        identity_public_key TEXT NOT NULL,
        identity_fingerprint TEXT NOT NULL,
        password_salt TEXT,
        password_hash TEXT,
        device_name TEXT NOT NULL,
        protocol_version TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('pending','approved','rejected')),
        account_id TEXT,
        created_at TEXT NOT NULL,
        reviewed_at TEXT,
        review_reason TEXT
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_registration_pending_username
        ON registration_requests(username) WHERE status='pending';
      CREATE UNIQUE INDEX IF NOT EXISTS idx_registration_pending_identity
        ON registration_requests(identity_id) WHERE status='pending';
      CREATE INDEX IF NOT EXISTS idx_registration_status_created
        ON registration_requests(status, created_at);
    `);
  }

  private async migratePostgres(): Promise<void> {
    await this.pool!.query(`
      CREATE TABLE IF NOT EXISTS registration_requests (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL,
        display_name TEXT NOT NULL,
        identity_id TEXT NOT NULL,
        identity_public_key TEXT NOT NULL,
        identity_fingerprint TEXT NOT NULL,
        password_salt TEXT,
        password_hash TEXT,
        device_name TEXT NOT NULL,
        protocol_version TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('pending','approved','rejected')),
        account_id TEXT,
        created_at TIMESTAMPTZ NOT NULL,
        reviewed_at TIMESTAMPTZ,
        review_reason TEXT
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_registration_pending_username
        ON registration_requests ((lower(username))) WHERE status='pending';
      CREATE UNIQUE INDEX IF NOT EXISTS idx_registration_pending_identity
        ON registration_requests (identity_id) WHERE status='pending';
      CREATE INDEX IF NOT EXISTS idx_registration_status_created
        ON registration_requests(status, created_at);
    `);
  }

  async close(): Promise<void> {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  async request(input: RegistrationInput): Promise<RegistrationRequestReceipt> {
    const normalized = validateInput(input);
    const salt = randomBytes(16);
    const passwordHash = await passwordHasher.hash(input.password, salt);
    const id = `reg_${randomUUID()}`;
    const now = new Date().toISOString();

    if (this.sqlite) {
      if (this.sqlite.prepare(`SELECT 1 FROM accounts WHERE username=?`).get(normalized.username)) throw new Error('username_taken');
      if (this.sqlite.prepare(`SELECT 1 FROM accounts WHERE identity_id=?`).get(normalized.identity.identityId)) throw new Error('identity_already_registered');
      if (this.sqlite.prepare(`SELECT 1 FROM registration_requests WHERE status='pending' AND (username=? OR identity_id=?)`).get(normalized.username, normalized.identity.identityId)) throw new Error('registration_request_exists');
      this.sqlite.prepare(`INSERT INTO registration_requests(id,username,display_name,identity_id,identity_public_key,identity_fingerprint,password_salt,password_hash,device_name,protocol_version,status,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`)
        .run(id, normalized.username, normalized.displayName, normalized.identity.identityId, normalized.identity.publicKey, normalized.identity.fingerprint, salt.toString('base64'), passwordHash, normalized.deviceName, input.protocolVersion, 'pending', now);
      return { requestId: id, username: normalized.username, status: 'pending', createdAt: now };
    }

    const existingUser = await this.pool!.query(`SELECT 1 FROM accounts WHERE lower(username)=lower($1) LIMIT 1`, [normalized.username]);
    if (existingUser.rowCount) throw new Error('username_taken');
    const existingIdentity = await this.pool!.query(`SELECT 1 FROM accounts WHERE identity_id=$1 LIMIT 1`, [normalized.identity.identityId]);
    if (existingIdentity.rowCount) throw new Error('identity_already_registered');
    const pending = await this.pool!.query(`SELECT 1 FROM registration_requests WHERE status='pending' AND (lower(username)=lower($1) OR identity_id=$2) LIMIT 1`, [normalized.username, normalized.identity.identityId]);
    if (pending.rowCount) throw new Error('registration_request_exists');
    await this.pool!.query(`INSERT INTO registration_requests(id,username,display_name,identity_id,identity_public_key,identity_fingerprint,password_salt,password_hash,device_name,protocol_version,status,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'pending',$11)`, [id, normalized.username, normalized.displayName, normalized.identity.identityId, normalized.identity.publicKey, normalized.identity.fingerprint, salt.toString('base64'), passwordHash, normalized.deviceName, input.protocolVersion, now]);
    return { requestId: id, username: normalized.username, status: 'pending', createdAt: now };
  }

  async get(requestId: string): Promise<RegistrationRequestView | null> {
    if (!/^reg_[0-9a-f-]{36}$/i.test(requestId)) return null;
    if (this.sqlite) {
      const row = this.sqlite.prepare(`SELECT id,username,display_name,device_name,identity_id,identity_fingerprint,status,account_id,created_at,reviewed_at,review_reason FROM registration_requests WHERE id=?`).get(requestId) as Record<string, unknown> | undefined;
      return row ? view(row) : null;
    }
    const result = await this.pool!.query(`SELECT id,username,display_name,device_name,identity_id,identity_fingerprint,status,account_id,created_at,reviewed_at,review_reason FROM registration_requests WHERE id=$1`, [requestId]);
    return result.rows[0] ? view(result.rows[0]) : null;
  }

  async list(status: 'pending' | 'approved' | 'rejected' = 'pending', limit = 100): Promise<RegistrationRequestView[]> {
    const bounded = Math.max(1, Math.min(limit, 200));
    if (this.sqlite) {
      const rows = this.sqlite.prepare(`SELECT id,username,display_name,device_name,identity_id,identity_fingerprint,status,account_id,created_at,reviewed_at,review_reason FROM registration_requests WHERE status=? ORDER BY created_at ASC LIMIT ?`).all(status, bounded) as Array<Record<string, unknown>>;
      return rows.map(view);
    }
    const result = await this.pool!.query(`SELECT id,username,display_name,device_name,identity_id,identity_fingerprint,status,account_id,created_at,reviewed_at,review_reason FROM registration_requests WHERE status=$1 ORDER BY created_at ASC LIMIT $2`, [status, bounded]);
    return result.rows.map(view);
  }

  async pendingCount(): Promise<number> {
    if (this.sqlite) {
      const row = this.sqlite.prepare(`SELECT COUNT(*) value FROM registration_requests WHERE status='pending'`).get() as Record<string, unknown>;
      return Number(row.value);
    }
    const result = await this.pool!.query(`SELECT COUNT(*)::bigint value FROM registration_requests WHERE status='pending'`);
    return Number(result.rows[0].value);
  }

  async approve(requestId: string, domain: string): Promise<{ requestId: string; status: 'approved'; accountId: string; address: string }> {
    if (this.sqlite) return this.approveSqlite(requestId, domain);
    return await this.approvePostgres(requestId, domain);
  }

  private approveSqlite(requestId: string, domain: string): { requestId: string; status: 'approved'; accountId: string; address: string } {
    const db = this.sqlite!;
    db.exec('BEGIN IMMEDIATE');
    try {
      const row = db.prepare(`SELECT * FROM registration_requests WHERE id=?`).get(requestId) as Record<string, unknown> | undefined;
      if (!row) throw new Error('registration_request_not_found');
      if (row.status !== 'pending') throw new Error('registration_request_not_pending');
      if (!row.password_salt || !row.password_hash) throw new Error('registration_request_secret_missing');
      const identity = validateStoredIdentity(row);
      const username = String(row.username);
      if (db.prepare(`SELECT 1 FROM accounts WHERE username=?`).get(username)) throw new Error('username_taken');
      if (db.prepare(`SELECT 1 FROM accounts WHERE identity_id=?`).get(identity.identityId)) throw new Error('identity_already_registered');
      const accountId = `acc_${randomUUID()}`;
      const deviceId = `dev_${randomUUID()}`;
      const conversationId = `conv_${randomUUID()}`;
      const now = new Date().toISOString();
      const address = `@${username}:${domain}`;
      db.prepare(`INSERT INTO accounts(id,username,display_name,identity_id,identity_public_key,identity_fingerprint,password_salt,password_hash,created_at) VALUES(?,?,?,?,?,?,?,?,?)`)
        .run(accountId, username, String(row.display_name), identity.identityId, identity.publicKey, identity.fingerprint, String(row.password_salt), String(row.password_hash), now);
      db.prepare(`INSERT INTO devices(id,account_id,name,created_at) VALUES(?,?,?,?)`).run(deviceId, accountId, String(row.device_name), now);
      db.prepare(`INSERT INTO conversations(id,kind,title,peer_address,created_at) VALUES(?,?,?,?,?)`).run(conversationId, 'self', null, address, now);
      db.prepare(`INSERT INTO conversation_members(conversation_id,account_id) VALUES(?,?)`).run(conversationId, accountId);
      db.prepare(`UPDATE registration_requests SET status='approved',account_id=?,reviewed_at=?,password_salt=NULL,password_hash=NULL WHERE id=?`).run(accountId, now, requestId);
      db.exec('COMMIT');
      return { requestId, status: 'approved', accountId, address };
    } catch (error) {
      try { db.exec('ROLLBACK'); } catch { /* best effort */ }
      throw error;
    }
  }

  private async approvePostgres(requestId: string, domain: string): Promise<{ requestId: string; status: 'approved'; accountId: string; address: string }> {
    const client = await this.pool!.connect();
    try {
      await client.query('BEGIN');
      const row = (await client.query(`SELECT * FROM registration_requests WHERE id=$1 FOR UPDATE`, [requestId])).rows[0];
      if (!row) throw new Error('registration_request_not_found');
      if (row.status !== 'pending') throw new Error('registration_request_not_pending');
      if (!row.password_salt || !row.password_hash) throw new Error('registration_request_secret_missing');
      const identity = validateStoredIdentity(row);
      const username = String(row.username);
      if ((await client.query(`SELECT 1 FROM accounts WHERE lower(username)=lower($1) LIMIT 1`, [username])).rowCount) throw new Error('username_taken');
      if ((await client.query(`SELECT 1 FROM accounts WHERE identity_id=$1 LIMIT 1`, [identity.identityId])).rowCount) throw new Error('identity_already_registered');
      const accountId = `acc_${randomUUID()}`;
      const deviceId = `dev_${randomUUID()}`;
      const conversationId = `conv_${randomUUID()}`;
      const now = new Date().toISOString();
      const address = `@${username}:${domain}`;
      await client.query(`INSERT INTO accounts(id,username,display_name,identity_id,identity_public_key,identity_fingerprint,password_salt,password_hash,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`, [accountId, username, row.display_name, identity.identityId, identity.publicKey, identity.fingerprint, row.password_salt, row.password_hash, now]);
      await client.query(`INSERT INTO devices(id,account_id,name,created_at) VALUES($1,$2,$3,$4)`, [deviceId, accountId, row.device_name, now]);
      await client.query(`INSERT INTO conversations(id,kind,title,peer_address,created_at) VALUES($1,'self',NULL,$2,$3)`, [conversationId, address, now]);
      await client.query(`INSERT INTO conversation_members(conversation_id,account_id) VALUES($1,$2)`, [conversationId, accountId]);
      await client.query(`UPDATE registration_requests SET status='approved',account_id=$1,reviewed_at=$2,password_salt=NULL,password_hash=NULL WHERE id=$3`, [accountId, now, requestId]);
      await client.query('COMMIT');
      return { requestId, status: 'approved', accountId, address };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async reject(requestId: string, reason?: string): Promise<{ requestId: string; status: 'rejected' }> {
    const reviewedAt = new Date().toISOString();
    const cleanedReason = reason?.trim().slice(0, 500) || null;
    if (this.sqlite) {
      const result = this.sqlite.prepare(`UPDATE registration_requests SET status='rejected',reviewed_at=?,review_reason=?,password_salt=NULL,password_hash=NULL WHERE id=? AND status='pending'`).run(reviewedAt, cleanedReason, requestId);
      if (Number(result.changes) !== 1) {
        const existing = await this.get(requestId);
        if (!existing) throw new Error('registration_request_not_found');
        throw new Error('registration_request_not_pending');
      }
      return { requestId, status: 'rejected' };
    }
    const result = await this.pool!.query(`UPDATE registration_requests SET status='rejected',reviewed_at=$1,review_reason=$2,password_salt=NULL,password_hash=NULL WHERE id=$3 AND status='pending'`, [reviewedAt, cleanedReason, requestId]);
    if (result.rowCount !== 1) {
      const existing = await this.get(requestId);
      if (!existing) throw new Error('registration_request_not_found');
      throw new Error('registration_request_not_pending');
    }
    return { requestId, status: 'rejected' };
  }
}
