import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

type QueryResult = { rows: Array<Record<string, unknown>>; rowCount: number | null };
type PgPool = { query(sql: string, values?: unknown[]): Promise<QueryResult>; end(): Promise<void> };

export interface FederationPeer {
  nodeId: string;
  domain: string;
  endpoint: string;
  publicKey: string;
  fingerprint: string;
  trusted: boolean;
  createdAt: string;
  lastVerifiedAt: string;
}

function fromRow(row: Record<string, unknown>): FederationPeer {
  return {
    nodeId: String(row.node_id),
    domain: String(row.domain),
    endpoint: String(row.endpoint),
    publicKey: String(row.public_key),
    fingerprint: String(row.fingerprint),
    trusted: Boolean(row.trusted),
    createdAt: new Date(String(row.created_at)).toISOString(),
    lastVerifiedAt: new Date(String(row.last_verified_at)).toISOString(),
  };
}

export class FederationPeerStore {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string): FederationPeerStore {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
    const store = new FederationPeerStore(db);
    store.migrateSqlite();
    return store;
  }

  static async postgresStore(databaseUrl: string): Promise<FederationPeerStore> {
    const module = await import('pg') as unknown as { Pool: new (options: Record<string, unknown>) => PgPool };
    const pool = new module.Pool({ connectionString: databaseUrl, max: 5, idleTimeoutMillis: 30_000, connectionTimeoutMillis: 10_000, ssl: databaseUrl.includes('sslmode=disable') ? false : undefined });
    const store = new FederationPeerStore(undefined, pool);
    await store.migratePostgres();
    return store;
  }

  private migrateSqlite(): void {
    this.sqlite!.exec(`
      CREATE TABLE IF NOT EXISTS federation_peers (
        node_id TEXT PRIMARY KEY,
        domain TEXT NOT NULL UNIQUE COLLATE NOCASE,
        endpoint TEXT NOT NULL,
        public_key TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        trusted INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        last_verified_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS federation_request_nonces (
        node_id TEXT NOT NULL,
        nonce TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY(node_id, nonce)
      );
    `);
  }

  private async migratePostgres(): Promise<void> {
    await this.pool!.query(`
      CREATE TABLE IF NOT EXISTS federation_peers (
        node_id TEXT PRIMARY KEY,
        domain TEXT NOT NULL,
        endpoint TEXT NOT NULL,
        public_key TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        trusted BOOLEAN NOT NULL DEFAULT TRUE,
        created_at TIMESTAMPTZ NOT NULL,
        last_verified_at TIMESTAMPTZ NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_federation_peers_domain_ci ON federation_peers ((lower(domain)));
      CREATE TABLE IF NOT EXISTS federation_request_nonces (
        node_id TEXT NOT NULL,
        nonce TEXT NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY(node_id, nonce)
      );
    `);
  }

  async close(): Promise<void> {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  async list(): Promise<FederationPeer[]> {
    if (this.sqlite) {
      const rows = this.sqlite.prepare(`SELECT * FROM federation_peers ORDER BY lower(domain)`).all() as Array<Record<string, unknown>>;
      return rows.map(fromRow);
    }
    const result = await this.pool!.query(`SELECT * FROM federation_peers ORDER BY lower(domain)`);
    return result.rows.map(fromRow);
  }

  async get(nodeId: string): Promise<FederationPeer | null> {
    if (this.sqlite) {
      const row = this.sqlite.prepare(`SELECT * FROM federation_peers WHERE node_id=?`).get(nodeId) as Record<string, unknown> | undefined;
      return row ? fromRow(row) : null;
    }
    const result = await this.pool!.query(`SELECT * FROM federation_peers WHERE node_id=$1`, [nodeId]);
    return result.rows[0] ? fromRow(result.rows[0]) : null;
  }

  async upsert(peer: Omit<FederationPeer, 'createdAt' | 'lastVerifiedAt'>): Promise<FederationPeer> {
    const now = new Date().toISOString();
    if (this.sqlite) {
      this.sqlite.prepare(`INSERT INTO federation_peers(node_id,domain,endpoint,public_key,fingerprint,trusted,created_at,last_verified_at) VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(node_id) DO UPDATE SET domain=excluded.domain,endpoint=excluded.endpoint,public_key=excluded.public_key,fingerprint=excluded.fingerprint,trusted=excluded.trusted,last_verified_at=excluded.last_verified_at`)
        .run(peer.nodeId, peer.domain, peer.endpoint, peer.publicKey, peer.fingerprint, peer.trusted ? 1 : 0, now, now);
      return (await this.get(peer.nodeId))!;
    }
    await this.pool!.query(`INSERT INTO federation_peers(node_id,domain,endpoint,public_key,fingerprint,trusted,created_at,last_verified_at) VALUES($1,$2,$3,$4,$5,$6,$7,$7)
      ON CONFLICT(node_id) DO UPDATE SET domain=EXCLUDED.domain,endpoint=EXCLUDED.endpoint,public_key=EXCLUDED.public_key,fingerprint=EXCLUDED.fingerprint,trusted=EXCLUDED.trusted,last_verified_at=EXCLUDED.last_verified_at`, [peer.nodeId, peer.domain, peer.endpoint, peer.publicKey, peer.fingerprint, peer.trusted, now]);
    return (await this.get(peer.nodeId))!;
  }

  async remove(nodeId: string): Promise<boolean> {
    if (this.sqlite) {
      const result = this.sqlite.prepare(`DELETE FROM federation_peers WHERE node_id=?`).run(nodeId);
      return Number(result.changes) === 1;
    }
    const result = await this.pool!.query(`DELETE FROM federation_peers WHERE node_id=$1`, [nodeId]);
    return result.rowCount === 1;
  }

  async rememberNonce(nodeId: string, nonce: string, expiresAt: Date): Promise<boolean> {
    await this.cleanupReplay();
    if (this.sqlite) {
      const result = this.sqlite.prepare(`INSERT OR IGNORE INTO federation_request_nonces(node_id,nonce,expires_at) VALUES(?,?,?)`).run(nodeId, nonce, expiresAt.toISOString());
      return Number(result.changes) === 1;
    }
    const result = await this.pool!.query(`INSERT INTO federation_request_nonces(node_id,nonce,expires_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, [nodeId, nonce, expiresAt.toISOString()]);
    return result.rowCount === 1;
  }

  private async cleanupReplay(): Promise<void> {
    const now = new Date().toISOString();
    if (this.sqlite) {
      this.sqlite.prepare(`DELETE FROM federation_request_nonces WHERE expires_at < ?`).run(now);
      return;
    }
    await this.pool!.query(`DELETE FROM federation_request_nonces WHERE expires_at < $1`, [now]);
  }
}
