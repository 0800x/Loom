import type { PublicAvatar } from '../profile/profile.ts';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { parseLoomAddress } from './address.ts';
import type { FederationEnvelope } from './event.ts';

type QueryResult = { rows: Array<Record<string, unknown>>; rowCount: number | null };
type PgClient = { query(sql: string, values?: unknown[]): Promise<QueryResult>; release(): void };
type PgPool = { query(sql: string, values?: unknown[]): Promise<QueryResult>; connect(): Promise<PgClient>; end(): Promise<void> };

export type DeliveryStatus = 'pending' | 'retrying' | 'delivered' | 'failed';
export interface RemoteUserProfile {
  address: string;
  displayName: string;
  avatar?: PublicAvatar;
  identity: { identityId: string; publicKey: string; fingerprint: string };
  homeNode: { nodeId: string; domain: string };
  version: string;
  updatedAt: string;
}
export interface OutboxDelivery {
  deliveryId: string;
  eventId: string;
  destinationNodeId: string;
  destinationDomain: string;
  destinationEndpoint: string;
  payload: string;
  attempts: number;
  status: DeliveryStatus;
  nextAttemptAt: string;
  createdAt: string;
  deliveredAt: string | null;
  lastError: string | null;
}

function iso(v: unknown): string { return new Date(String(v)).toISOString(); }
function profileFromRow(r: Record<string, unknown>): RemoteUserProfile {
  return {
    address: String(r.address),
    displayName: String(r.display_name),
    ...(r.avatar_json ? { avatar: JSON.parse(String(r.avatar_json)) } : {}),
    identity: {
      identityId: String(r.identity_id),
      publicKey: String(r.identity_public_key),
      fingerprint: String(r.identity_fingerprint),
    },
    homeNode: { nodeId: String(r.home_node_id), domain: String(r.domain) },
    version: String(r.version),
    updatedAt: iso(r.updated_at),
  };
}
function deliveryFromRow(r: Record<string, unknown>): OutboxDelivery {
  return {
    deliveryId: String(r.delivery_id),
    eventId: String(r.event_id),
    destinationNodeId: String(r.destination_node_id),
    destinationDomain: String(r.destination_domain),
    destinationEndpoint: String(r.destination_endpoint),
    payload: typeof r.payload_json === 'string' ? String(r.payload_json) : JSON.stringify(r.payload_json),
    attempts: Number(r.attempts),
    status: String(r.status) as DeliveryStatus,
    nextAttemptAt: iso(r.next_attempt_at),
    createdAt: iso(r.created_at),
    deliveredAt: r.delivered_at == null ? null : iso(r.delivered_at),
    lastError: r.last_error == null ? null : String(r.last_error),
  };
}

export class FederationRoutingStore {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string) {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
    const s = new FederationRoutingStore(db);
    s.migrateSqlite();
    return s;
  }

  static async postgresStore(databaseUrl: string) {
    const m = await import('pg') as unknown as { Pool: new (o: Record<string, unknown>) => PgPool };
    const pool = new m.Pool({
      connectionString: databaseUrl,
      max: 8,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000,
      ssl: databaseUrl.includes('sslmode=disable') ? false : undefined,
    });
    const s = new FederationRoutingStore(undefined, pool);
    await s.migratePostgres();
    return s;
  }

  private migrateSqlite() {
    this.sqlite!.exec(`CREATE TABLE IF NOT EXISTS federation_profile_avatars(address TEXT PRIMARY KEY,avatar_json TEXT NOT NULL);CREATE TABLE IF NOT EXISTS federation_remote_users(address TEXT PRIMARY KEY COLLATE NOCASE,username TEXT NOT NULL,domain TEXT NOT NULL,home_node_id TEXT NOT NULL,display_name TEXT NOT NULL,identity_id TEXT NOT NULL,identity_public_key TEXT NOT NULL,identity_fingerprint TEXT NOT NULL,version TEXT NOT NULL,updated_at TEXT NOT NULL,expires_at TEXT NOT NULL);CREATE INDEX IF NOT EXISTS idx_federation_remote_users_domain ON federation_remote_users(domain);CREATE TABLE IF NOT EXISTS conversation_remote_members(conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,remote_address TEXT NOT NULL COLLATE NOCASE,remote_node_id TEXT NOT NULL,PRIMARY KEY(conversation_id,remote_address));CREATE INDEX IF NOT EXISTS idx_conversation_remote_address ON conversation_remote_members(remote_address);CREATE TABLE IF NOT EXISTS federation_remote_messages(id TEXT PRIMARY KEY,event_id TEXT NOT NULL UNIQUE,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,sender_address TEXT NOT NULL,client_id TEXT NOT NULL,type TEXT NOT NULL,ciphertext TEXT NOT NULL,protocol_version TEXT NOT NULL,reply_to_message_id TEXT,metadata_json TEXT NOT NULL DEFAULT '{}',server_order INTEGER NOT NULL UNIQUE,created_at TEXT NOT NULL);CREATE INDEX IF NOT EXISTS idx_federation_remote_messages_conversation_order ON federation_remote_messages(conversation_id,server_order);CREATE TABLE IF NOT EXISTS federation_inbox(event_id TEXT PRIMARY KEY,origin_node_id TEXT NOT NULL,payload_hash TEXT NOT NULL,received_at TEXT NOT NULL);CREATE INDEX IF NOT EXISTS idx_federation_inbox_origin ON federation_inbox(origin_node_id,received_at);CREATE TABLE IF NOT EXISTS federation_outbox(delivery_id TEXT PRIMARY KEY,event_id TEXT NOT NULL,destination_node_id TEXT NOT NULL,destination_domain TEXT NOT NULL,destination_endpoint TEXT NOT NULL,payload_json TEXT NOT NULL,source_message_id TEXT,status TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next_attempt_at TEXT NOT NULL,created_at TEXT NOT NULL,delivered_at TEXT,last_error TEXT,UNIQUE(event_id,destination_node_id));CREATE INDEX IF NOT EXISTS idx_federation_outbox_due ON federation_outbox(status,next_attempt_at);CREATE INDEX IF NOT EXISTS idx_federation_outbox_destination ON federation_outbox(destination_node_id,status);CREATE TABLE IF NOT EXISTS federation_metrics(key TEXT PRIMARY KEY,value INTEGER NOT NULL DEFAULT 0,updated_at TEXT NOT NULL);`);
  }

  private async migratePostgres() {
    await this.pool!.query(`CREATE TABLE IF NOT EXISTS federation_profile_avatars(address TEXT PRIMARY KEY,avatar_json TEXT NOT NULL);CREATE TABLE IF NOT EXISTS federation_remote_users(address TEXT PRIMARY KEY,username TEXT NOT NULL,domain TEXT NOT NULL,home_node_id TEXT NOT NULL,display_name TEXT NOT NULL,identity_id TEXT NOT NULL,identity_public_key TEXT NOT NULL,identity_fingerprint TEXT NOT NULL,version TEXT NOT NULL,updated_at TIMESTAMPTZ NOT NULL,expires_at TIMESTAMPTZ NOT NULL);CREATE INDEX IF NOT EXISTS idx_federation_remote_users_domain ON federation_remote_users(domain);CREATE TABLE IF NOT EXISTS conversation_remote_members(conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,remote_address TEXT NOT NULL,remote_node_id TEXT NOT NULL,PRIMARY KEY(conversation_id,remote_address));CREATE INDEX IF NOT EXISTS idx_conversation_remote_address ON conversation_remote_members((lower(remote_address)));CREATE TABLE IF NOT EXISTS federation_remote_messages(id TEXT PRIMARY KEY,event_id TEXT NOT NULL UNIQUE,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,sender_address TEXT NOT NULL,client_id TEXT NOT NULL,type TEXT NOT NULL,ciphertext TEXT NOT NULL,protocol_version TEXT NOT NULL,reply_to_message_id TEXT,metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,server_order BIGINT NOT NULL UNIQUE DEFAULT nextval('message_server_order_seq'),created_at TIMESTAMPTZ NOT NULL);CREATE INDEX IF NOT EXISTS idx_federation_remote_messages_conversation_order ON federation_remote_messages(conversation_id,server_order);CREATE TABLE IF NOT EXISTS federation_inbox(event_id TEXT PRIMARY KEY,origin_node_id TEXT NOT NULL,payload_hash TEXT NOT NULL,received_at TIMESTAMPTZ NOT NULL);CREATE INDEX IF NOT EXISTS idx_federation_inbox_origin ON federation_inbox(origin_node_id,received_at);CREATE TABLE IF NOT EXISTS federation_outbox(delivery_id TEXT PRIMARY KEY,event_id TEXT NOT NULL,destination_node_id TEXT NOT NULL,destination_domain TEXT NOT NULL,destination_endpoint TEXT NOT NULL,payload_json JSONB NOT NULL,source_message_id TEXT,status TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next_attempt_at TIMESTAMPTZ NOT NULL,created_at TIMESTAMPTZ NOT NULL,delivered_at TIMESTAMPTZ,last_error TEXT,UNIQUE(event_id,destination_node_id));CREATE INDEX IF NOT EXISTS idx_federation_outbox_due ON federation_outbox(status,next_attempt_at);CREATE INDEX IF NOT EXISTS idx_federation_outbox_destination ON federation_outbox(destination_node_id,status);CREATE TABLE IF NOT EXISTS federation_metrics(key TEXT PRIMARY KEY,value BIGINT NOT NULL DEFAULT 0,updated_at TIMESTAMPTZ NOT NULL);`);
  }

  async close() {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  async resolveLocalUser(username: string, domain: string): Promise<RemoteUserProfile | null> {
    let r: Record<string, unknown> | undefined;
    if (this.sqlite) {
      r = this.sqlite.prepare(`SELECT a.username,a.display_name,a.identity_id,a.identity_public_key,a.identity_fingerprint,a.created_at,p.avatar_json,p.revision,p.updated_at FROM accounts a LEFT JOIN account_profiles p ON p.account_id=a.id WHERE lower(a.username)=lower(?)`).get(username) as Record<string, unknown> | undefined;
    } else {
      r = (await this.pool!.query(`SELECT a.username,a.display_name,a.identity_id,a.identity_public_key,a.identity_fingerprint,a.created_at,p.avatar_json,p.revision,p.updated_at FROM accounts a LEFT JOIN account_profiles p ON p.account_id=a.id WHERE lower(a.username)=lower($1)`, [username])).rows[0];
    }
    if (!r) return null;
    return {
      address: `@${String(r.username).toLowerCase()}:${domain}`,
      displayName: String(r.display_name),
      identity: { identityId: String(r.identity_id), publicKey: String(r.identity_public_key), fingerprint: String(r.identity_fingerprint) },
      homeNode: { nodeId: '', domain },
      ...(r.avatar_json ? { avatar: JSON.parse(String(r.avatar_json)) } : {}),
      version: r.revision ? String(r.revision) : iso(r.created_at),
      updatedAt: iso(r.updated_at ?? r.created_at),
    };
  }

  async cacheRemoteUser(profile: RemoteUserProfile, ttlMs = 15 * 60_000) {
    const a = parseLoomAddress(profile.address);
    const expires = new Date(Date.now() + ttlMs).toISOString();
    const avatar = profile.avatar ? JSON.stringify(profile.avatar) : null;
    const values = [a.canonical, a.username, a.domain, profile.homeNode.nodeId, profile.displayName, profile.identity.identityId, profile.identity.publicKey, profile.identity.fingerprint, profile.version, profile.updatedAt, expires];
    // Cache the signed profile and avatar in one transaction. Concurrent lookups
    // must not combine the identity/revision from one response with another photo.
    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        this.sqlite.prepare(`INSERT INTO federation_remote_users(address,username,domain,home_node_id,display_name,identity_id,identity_public_key,identity_fingerprint,version,updated_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(address) DO UPDATE SET username=excluded.username,domain=excluded.domain,home_node_id=excluded.home_node_id,display_name=excluded.display_name,identity_id=excluded.identity_id,identity_public_key=excluded.identity_public_key,identity_fingerprint=excluded.identity_fingerprint,version=excluded.version,updated_at=excluded.updated_at,expires_at=excluded.expires_at`).run(...values);
        if (avatar) this.sqlite.prepare(`INSERT INTO federation_profile_avatars(address,avatar_json) VALUES(?,?) ON CONFLICT(address) DO UPDATE SET avatar_json=excluded.avatar_json`).run(a.canonical, avatar);
        else this.sqlite.prepare(`DELETE FROM federation_profile_avatars WHERE address=?`).run(a.canonical);
        this.sqlite.exec('COMMIT');
      } catch (error) { this.sqlite.exec('ROLLBACK'); throw error; }
    } else {
      const client = await this.pool!.connect();
      try {
        await client.query('BEGIN');
        await client.query(`INSERT INTO federation_remote_users(address,username,domain,home_node_id,display_name,identity_id,identity_public_key,identity_fingerprint,version,updated_at,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT(address) DO UPDATE SET username=EXCLUDED.username,domain=EXCLUDED.domain,home_node_id=EXCLUDED.home_node_id,display_name=EXCLUDED.display_name,identity_id=EXCLUDED.identity_id,identity_public_key=EXCLUDED.identity_public_key,identity_fingerprint=EXCLUDED.identity_fingerprint,version=EXCLUDED.version,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at`, values);
        if (avatar) await client.query(`INSERT INTO federation_profile_avatars(address,avatar_json) VALUES($1,$2) ON CONFLICT(address) DO UPDATE SET avatar_json=excluded.avatar_json`, [a.canonical, avatar]);
        else await client.query(`DELETE FROM federation_profile_avatars WHERE address=$1`, [a.canonical]);
        await client.query('COMMIT');
      } catch (error) { await client.query('ROLLBACK'); throw error; }
      finally { client.release(); }
    }
  }

  async getCachedRemoteUser(address: string): Promise<RemoteUserProfile | null> {
    const a = parseLoomAddress(address);
    let r: Record<string, unknown> | undefined;
    if (this.sqlite) {
      r = this.sqlite.prepare(`SELECT u.*,p.avatar_json FROM federation_remote_users u LEFT JOIN federation_profile_avatars p ON p.address=u.address WHERE lower(u.address)=lower(?) AND u.expires_at>?`).get(a.canonical, new Date().toISOString()) as Record<string, unknown> | undefined;
    } else {
      r = (await this.pool!.query(`SELECT u.*,p.avatar_json FROM federation_remote_users u LEFT JOIN federation_profile_avatars p ON p.address=u.address WHERE lower(u.address)=lower($1) AND u.expires_at>now()`, [a.canonical])).rows[0];
    }
    return r ? profileFromRow(r) : null;
  }

  async ensureRemoteConversation(accountId: string, remoteAddress: string, remoteNodeId: string): Promise<string> {
    const a = parseLoomAddress(remoteAddress);
    if (this.sqlite) {
      const e = this.sqlite.prepare(`SELECT c.id FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id JOIN conversation_remote_members rm ON rm.conversation_id=c.id WHERE cm.account_id=? AND lower(rm.remote_address)=lower(?) LIMIT 1`).get(accountId, a.canonical) as Record<string, unknown> | undefined;
      if (e) return String(e.id);
      const id = `conv_${randomUUID()}`;
      const now = new Date().toISOString();
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        this.sqlite.prepare(`INSERT INTO conversations(id,kind,title,peer_address,created_at) VALUES(?,'direct',NULL,?,?)`).run(id, a.canonical, now);
        this.sqlite.prepare(`INSERT INTO conversation_members(conversation_id,account_id) VALUES(?,?)`).run(id, accountId);
        this.sqlite.prepare(`INSERT INTO conversation_remote_members(conversation_id,remote_address,remote_node_id) VALUES(?,?,?)`).run(id, a.canonical, remoteNodeId);
        this.sqlite.exec('COMMIT');
        return id;
      } catch (e) {
        this.sqlite.exec('ROLLBACK');
        throw e;
      }
    }
    const e = (await this.pool!.query(`SELECT c.id FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id JOIN conversation_remote_members rm ON rm.conversation_id=c.id WHERE cm.account_id=$1 AND lower(rm.remote_address)=lower($2) LIMIT 1`, [accountId, a.canonical])).rows[0];
    if (e) return String(e.id);
    const id = `conv_${randomUUID()}`;
    const client = await this.pool!.connect();
    try {
      await client.query('BEGIN');
      await client.query(`INSERT INTO conversations(id,kind,title,peer_address,created_at) VALUES($1,'direct',NULL,$2,$3)`, [id, a.canonical, new Date().toISOString()]);
      await client.query(`INSERT INTO conversation_members(conversation_id,account_id) VALUES($1,$2)`, [id, accountId]);
      await client.query(`INSERT INTO conversation_remote_members(conversation_id,remote_address,remote_node_id) VALUES($1,$2,$3)`, [id, a.canonical, remoteNodeId]);
      await client.query('COMMIT');
      return id;
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
  }

  async remoteMembers(conversationId: string): Promise<Array<{ address: string; nodeId: string }>> {
    if (this.sqlite) {
      return (this.sqlite.prepare(`SELECT remote_address,remote_node_id FROM conversation_remote_members WHERE conversation_id=?`).all(conversationId) as Array<Record<string, unknown>>).map(r => ({ address: String(r.remote_address), nodeId: String(r.remote_node_id) }));
    }
    return (await this.pool!.query(`SELECT remote_address,remote_node_id FROM conversation_remote_members WHERE conversation_id=$1`, [conversationId])).rows.map(r => ({ address: String(r.remote_address), nodeId: String(r.remote_node_id) }));
  }

  async enqueue(envelope: FederationEnvelope, destinationEndpoint: string, sourceMessageId?: string): Promise<OutboxDelivery> {
    const now = new Date().toISOString();
    const deliveryId = `fdlv_${randomUUID()}`;
    const payload = JSON.stringify(envelope);
    if (this.sqlite) {
      this.sqlite.prepare(`INSERT OR IGNORE INTO federation_outbox(delivery_id,event_id,destination_node_id,destination_domain,destination_endpoint,payload_json,source_message_id,status,attempts,next_attempt_at,created_at) VALUES(?,?,?,?,?,?,?,'pending',0,?,?)`).run(deliveryId, envelope.eventId, envelope.destinationNodeId, envelope.destinationDomain, destinationEndpoint, payload, sourceMessageId ?? null, now, now);
    } else {
      await this.pool!.query(`INSERT INTO federation_outbox(delivery_id,event_id,destination_node_id,destination_domain,destination_endpoint,payload_json,source_message_id,status,attempts,next_attempt_at,created_at) VALUES($1,$2,$3,$4,$5,$6::jsonb,$7,'pending',0,$8,$8) ON CONFLICT(event_id,destination_node_id) DO NOTHING`, [deliveryId, envelope.eventId, envelope.destinationNodeId, envelope.destinationDomain, destinationEndpoint, payload, sourceMessageId ?? null, now]);
    }
    const d = await this.getDeliveryByEvent(envelope.eventId, envelope.destinationNodeId);
    if (!d) throw new Error('federation_enqueue_failed');
    return d;
  }

  private async getDeliveryByEvent(eventId: string, nodeId: string): Promise<OutboxDelivery | null> {
    let r: Record<string, unknown> | undefined;
    if (this.sqlite) {
      r = this.sqlite.prepare(`SELECT * FROM federation_outbox WHERE event_id=? AND destination_node_id=?`).get(eventId, nodeId) as Record<string, unknown> | undefined;
    } else {
      r = (await this.pool!.query(`SELECT * FROM federation_outbox WHERE event_id=$1 AND destination_node_id=$2`, [eventId, nodeId])).rows[0];
    }
    return r ? deliveryFromRow(r) : null;
  }

  async dueDeliveries(limit = 20, busyNodeIds: string[] = []): Promise<OutboxDelivery[]> {
    const n = Math.max(1, Math.min(100, limit));
    // Select before LIMIT so a backlog for an offline Node cannot hide the
    // oldest ready message for a healthy Node. Keep each Node's due order.
    if (this.sqlite) {
      const excluded = busyNodeIds.length ? `AND destination_node_id NOT IN (${busyNodeIds.map(() => '?').join(',')})` : '';
      return (this.sqlite.prepare(`SELECT * FROM (
        SELECT *,ROW_NUMBER() OVER (PARTITION BY destination_node_id ORDER BY next_attempt_at,created_at,delivery_id) AS destination_rank
        FROM federation_outbox WHERE status IN ('pending','retrying') AND next_attempt_at<=? ${excluded}
      ) AS due WHERE destination_rank=1 ORDER BY next_attempt_at,created_at,delivery_id LIMIT ?`)
        .all(new Date().toISOString(), ...busyNodeIds, n) as Array<Record<string, unknown>>).map(deliveryFromRow);
    }
    return (await this.pool!.query(`SELECT * FROM (
      SELECT *,ROW_NUMBER() OVER (PARTITION BY destination_node_id ORDER BY next_attempt_at,created_at,delivery_id) AS destination_rank
      FROM federation_outbox WHERE status IN ('pending','retrying') AND next_attempt_at<=now() AND NOT (destination_node_id=ANY($2::text[]))
    ) AS due WHERE destination_rank=1 ORDER BY next_attempt_at,created_at,delivery_id LIMIT $1`, [n, busyNodeIds])).rows.map(deliveryFromRow);
  }

  private sourceDeliveryPayload(message: Record<string, unknown>, sourceMessageId: string, destinationDomain: string, status: 'nodeAccepted' | 'failed', timestamp: string, deliveryId?: string, error?: string) {
    return {
      messageId: sourceMessageId,
      clientId: String(message.client_id),
      conversationId: String(message.conversation_id),
      destinationDomain,
      status,
      ...(deliveryId ? { deliveryId } : {}),
      ...(status === 'nodeAccepted' ? { nodeAcceptedAt: timestamp } : { failedAt: timestamp, error: (error ?? 'federation_delivery_failed').slice(0, 1000) }),
    };
  }

  private emitSourceDeliverySqlite(sourceMessageId: string, destinationDomain: string, kind: 'message.nodeAccepted' | 'message.failed', timestamp: string, deliveryId?: string, error?: string, eventId?: string): boolean {
    const db = this.sqlite!;
    const message = db.prepare(`SELECT sender_account_id,client_id,conversation_id FROM messages WHERE id=?`).get(sourceMessageId) as Record<string, unknown> | undefined;
    if (!message) return false;
    const id = eventId ?? `evt_${randomUUID()}`;
    if (db.prepare(`SELECT 1 FROM events WHERE event_id=?`).get(id)) return false;
    const accountId = String(message.sender_account_id);
    const eventOrder = Number((db.prepare(`SELECT COALESCE(MAX(event_order),0)+1 next_order FROM events WHERE account_id=?`).get(accountId) as Record<string, unknown>).next_order);
    const status = kind === 'message.nodeAccepted' ? 'nodeAccepted' : 'failed';
    const payload = this.sourceDeliveryPayload(message, sourceMessageId, destinationDomain, status, timestamp, deliveryId, error);
    db.prepare(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES(?,?,?,?,?,?)`).run(id, accountId, kind, eventOrder, JSON.stringify(payload), timestamp);
    return true;
  }

  private async emitSourceDeliveryPostgres(client: PgClient, sourceMessageId: string, destinationDomain: string, kind: 'message.nodeAccepted' | 'message.failed', timestamp: string, deliveryId?: string, error?: string, eventId?: string): Promise<boolean> {
    const message = (await client.query(`SELECT sender_account_id,client_id,conversation_id FROM messages WHERE id=$1`, [sourceMessageId])).rows[0];
    if (!message) return false;
    const id = eventId ?? `evt_${randomUUID()}`;
    const existing = (await client.query(`SELECT 1 FROM events WHERE event_id=$1`, [id])).rows[0];
    if (existing) return false;
    const accountId = String(message.sender_account_id);
    await client.query(`INSERT INTO account_event_sequences(account_id,next_order) VALUES($1,2) ON CONFLICT(account_id) DO UPDATE SET next_order=account_event_sequences.next_order+1`, [accountId]);
    const seq = (await client.query(`SELECT next_order-1 event_order FROM account_event_sequences WHERE account_id=$1`, [accountId])).rows[0];
    const status = kind === 'message.nodeAccepted' ? 'nodeAccepted' : 'failed';
    const payload = this.sourceDeliveryPayload(message, sourceMessageId, destinationDomain, status, timestamp, deliveryId, error);
    await client.query(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES($1,$2,$3,$4,$5::jsonb,$6)`, [id, accountId, kind, seq.event_order, JSON.stringify(payload), timestamp]);
    return true;
  }

  async markLocalDelivered(sourceMessageId: string, destinationDomain: string): Promise<void> {
    if (!sourceMessageId) return;
    const timestamp = new Date().toISOString();
    const stableEventId = `evt_local_delivery_${sourceMessageId.replace(/^msg_/, '')}`;
    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        this.emitSourceDeliverySqlite(sourceMessageId, destinationDomain, 'message.nodeAccepted', timestamp, undefined, undefined, stableEventId);
        this.sqlite.exec('COMMIT');
      } catch (error) {
        try { this.sqlite.exec('ROLLBACK'); } catch { }
        throw error;
      }
      return;
    }
    const client = await this.pool!.connect();
    try {
      await client.query('BEGIN');
      await this.emitSourceDeliveryPostgres(client, sourceMessageId, destinationDomain, 'message.nodeAccepted', timestamp, undefined, undefined, stableEventId);
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  async markDelivered(id: string) {
    const now = new Date().toISOString();
    let transitioned = false;
    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        const row = this.sqlite.prepare(`SELECT source_message_id,status,destination_domain FROM federation_outbox WHERE delivery_id=?`).get(id) as Record<string, unknown> | undefined;
        if (row && String(row.status) !== 'delivered') {
          this.sqlite.prepare(`UPDATE federation_outbox SET status='delivered',delivered_at=?,last_error=NULL WHERE delivery_id=?`).run(now, id);
          if (row.source_message_id) this.emitSourceDeliverySqlite(String(row.source_message_id), String(row.destination_domain), 'message.nodeAccepted', now, id);
          transitioned = true;
        }
        this.sqlite.exec('COMMIT');
      } catch (error) {
        try { this.sqlite.exec('ROLLBACK'); } catch { }
        throw error;
      }
    } else {
      const client = await this.pool!.connect();
      try {
        await client.query('BEGIN');
        const row = (await client.query(`SELECT source_message_id,status,destination_domain FROM federation_outbox WHERE delivery_id=$1 FOR UPDATE`, [id])).rows[0];
        if (row && String(row.status) !== 'delivered') {
          await client.query(`UPDATE federation_outbox SET status='delivered',delivered_at=$1,last_error=NULL WHERE delivery_id=$2`, [now, id]);
          if (row.source_message_id) await this.emitSourceDeliveryPostgres(client, String(row.source_message_id), String(row.destination_domain), 'message.nodeAccepted', now, id);
          transitioned = true;
        }
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      } finally {
        client.release();
      }
    }
    if (transitioned) await this.increment('delivered_events_total');
  }

  async markRetry(id: string, attempts: number, nextAttemptAt: Date, error: string) {
    if (this.sqlite) {
      this.sqlite.prepare(`UPDATE federation_outbox SET status='retrying',attempts=?,next_attempt_at=?,last_error=? WHERE delivery_id=?`).run(attempts, nextAttemptAt.toISOString(), error.slice(0, 1000), id);
    } else {
      await this.pool!.query(`UPDATE federation_outbox SET status='retrying',attempts=$1,next_attempt_at=$2,last_error=$3 WHERE delivery_id=$4`, [attempts, nextAttemptAt.toISOString(), error.slice(0, 1000), id]);
    }
  }

  async markFailed(id: string, attempts: number, error: string) {
    const now = new Date().toISOString();
    const safeError = error.slice(0, 1000);
    let transitioned = false;
    if (this.sqlite) {
      this.sqlite.exec('BEGIN IMMEDIATE');
      try {
        const row = this.sqlite.prepare(`SELECT source_message_id,status,destination_domain FROM federation_outbox WHERE delivery_id=?`).get(id) as Record<string, unknown> | undefined;
        if (row && String(row.status) !== 'failed' && String(row.status) !== 'delivered') {
          this.sqlite.prepare(`UPDATE federation_outbox SET status='failed',attempts=?,last_error=? WHERE delivery_id=?`).run(attempts, safeError, id);
          if (row.source_message_id) this.emitSourceDeliverySqlite(String(row.source_message_id), String(row.destination_domain), 'message.failed', now, id, safeError);
          transitioned = true;
        }
        this.sqlite.exec('COMMIT');
      } catch (failure) {
        try { this.sqlite.exec('ROLLBACK'); } catch { }
        throw failure;
      }
    } else {
      const client = await this.pool!.connect();
      try {
        await client.query('BEGIN');
        const row = (await client.query(`SELECT source_message_id,status,destination_domain FROM federation_outbox WHERE delivery_id=$1 FOR UPDATE`, [id])).rows[0];
        if (row && String(row.status) !== 'failed' && String(row.status) !== 'delivered') {
          await client.query(`UPDATE federation_outbox SET status='failed',attempts=$1,last_error=$2 WHERE delivery_id=$3`, [attempts, safeError, id]);
          if (row.source_message_id) await this.emitSourceDeliveryPostgres(client, String(row.source_message_id), String(row.destination_domain), 'message.failed', now, id, safeError);
          transitioned = true;
        }
        await client.query('COMMIT');
      } catch (failure) {
        await client.query('ROLLBACK');
        throw failure;
      } finally {
        client.release();
      }
    }
    if (transitioned) await this.increment('failed_events_total');
  }

  async retryFailed(id?: string): Promise<number> {
    const now = new Date().toISOString();
    if (this.sqlite) {
      const r = id
        ? this.sqlite.prepare(`UPDATE federation_outbox SET status='pending',next_attempt_at=?,last_error=NULL WHERE delivery_id=? AND status='failed'`).run(now, id)
        : this.sqlite.prepare(`UPDATE federation_outbox SET status='pending',next_attempt_at=?,last_error=NULL WHERE status='failed'`).run(now);
      return Number(r.changes);
    }
    const r = id
      ? await this.pool!.query(`UPDATE federation_outbox SET status='pending',next_attempt_at=$1,last_error=NULL WHERE delivery_id=$2 AND status='failed'`, [now, id])
      : await this.pool!.query(`UPDATE federation_outbox SET status='pending',next_attempt_at=$1,last_error=NULL WHERE status='failed'`, [now]);
    return r.rowCount ?? 0;
  }

  async purgeFailed(): Promise<number> {
    if (this.sqlite) return Number(this.sqlite.prepare(`DELETE FROM federation_outbox WHERE status='failed'`).run().changes);
    return (await this.pool!.query(`DELETE FROM federation_outbox WHERE status='failed'`)).rowCount ?? 0;
  }

  async listQueue(limit = 100): Promise<OutboxDelivery[]> {
    const n = Math.max(1, Math.min(500, limit));
    if (this.sqlite) return (this.sqlite.prepare(`SELECT * FROM federation_outbox ORDER BY created_at DESC LIMIT ?`).all(n) as Array<Record<string, unknown>>).map(deliveryFromRow);
    return (await this.pool!.query(`SELECT * FROM federation_outbox ORDER BY created_at DESC LIMIT $1`, [n])).rows.map(deliveryFromRow);
  }

  /** Only incoming messages belonging to the authenticated recipient qualify. */
  async incomingReceiptTargets(accountId: string, ownAddress: string, clientIds: string[]) {
    const results: Array<{ eventId: string; clientId: string; senderAddress: string; nodeId: string; conversationId: string }> = [];
    for (const clientId of new Set(clientIds)) {
      const sql = `SELECT m.event_id,m.client_id,m.sender_address,m.conversation_id,rm.remote_node_id FROM federation_remote_messages m JOIN conversation_members cm ON cm.conversation_id=m.conversation_id JOIN conversation_remote_members rm ON rm.conversation_id=m.conversation_id AND lower(rm.remote_address)=lower(m.sender_address) WHERE cm.account_id=? AND m.client_id=? AND lower(m.sender_address)!=lower(?)`;
      const rows = this.sqlite ? this.sqlite.prepare(sql).all(accountId,clientId,ownAddress)
        : (await this.pool!.query(sql.replace('?', '$1').replace('?', '$2').replace('?', '$3'), [accountId,clientId,ownAddress])).rows;
      for (const row of rows) results.push({ eventId:String(row.event_id), clientId:String(row.client_id), senderAddress:String(row.sender_address), nodeId:String(row.remote_node_id), conversationId:String(row.conversation_id) });
    }
    return results;
  }

  /** The signed origin must be the exact destination of the original outbox row.
   * A random node, another account, or a relay cannot assert recipient delivery. */
  private async applyRecipientReceipt(envelope: FederationEnvelope): Promise<{duplicate: boolean}> {
    const query = `SELECT o.payload_json,o.source_message_id,m.sender_account_id,a.username FROM federation_outbox o JOIN messages m ON m.id=o.source_message_id JOIN accounts a ON a.id=m.sender_account_id WHERE o.event_id=? AND o.destination_node_id=?`;
    const values = [envelope.payload.messageId,envelope.originNodeId];
    const sqlite = this.sqlite;
    const client = sqlite ? null : await this.pool!.connect();
    try {
      if(sqlite) sqlite.exec('BEGIN IMMEDIATE'); else await client!.query('BEGIN');
      const row = sqlite ? sqlite.prepare(query).get(...values) : (await client!.query(query.replace('?', '$1').replace('?', '$2'),values)).rows[0];
      if(!row) throw new Error('federation_receipt_unknown_message');
      const original = (typeof row.payload_json === 'string' ? JSON.parse(row.payload_json) : row.payload_json) as FederationEnvelope;
      const recipient = parseLoomAddress(envelope.recipientAddresses[0]);
      if(original.eventType!=='message.created' || original.payload.clientId!==envelope.payload.clientId || original.recipientAddresses[0].toLowerCase()!==envelope.senderAddress.toLowerCase() || String(row.username).toLowerCase()!==recipient.username.toLowerCase()) throw new Error('federation_receipt_recipient_mismatch');
      const id = `recipient-delivered:${row.source_message_id}`;
      const accountId = String(row.sender_account_id);
      const payload = JSON.stringify({clientId:original.payload.clientId,messageId:row.source_message_id,deliveryEvidence:'recipient-device',recipientAddress:envelope.senderAddress});
      let inserted: boolean;
      if(sqlite) {
        const order = Number((sqlite.prepare('SELECT COALESCE(MAX(event_order),0)+1 value FROM events WHERE account_id=?').get(accountId) as Record<string,unknown>).value);
        inserted = Number(sqlite.prepare(`INSERT OR IGNORE INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES(?,?,'message.delivered',?,?,?)`).run(id,accountId,order,payload,new Date().toISOString()).changes)>0;
        sqlite.exec('COMMIT');
      } else {
        await client!.query(`INSERT INTO account_event_sequences(account_id,next_order) VALUES($1,2) ON CONFLICT(account_id) DO UPDATE SET next_order=account_event_sequences.next_order+1`,[accountId]);
        const seq = (await client!.query('SELECT next_order-1 event_order FROM account_event_sequences WHERE account_id=$1',[accountId])).rows[0];
        inserted = (await client!.query(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES($1,$2,'message.delivered',$3,$4::jsonb,$5) ON CONFLICT DO NOTHING`,[id,accountId,seq.event_order,payload,new Date().toISOString()])).rowCount!==0;
        await client!.query('COMMIT');
      }
      return {duplicate:!inserted};
    } catch(error) {
      if(sqlite) { try {sqlite.exec('ROLLBACK');} catch {} } else await client!.query('ROLLBACK');
      throw error;
    } finally { client?.release(); }
  }

  async applyInbound(envelope: FederationEnvelope): Promise<{ duplicate: boolean; conversationId?: string; messageId?: string }> {
    if (envelope.eventType === 'message.received') return this.applyRecipientReceipt(envelope);
    const hash = createHash('sha256').update(JSON.stringify(envelope)).digest('hex');
    return this.sqlite ? this.applyInboundSqlite(envelope, hash) : this.applyInboundPostgres(envelope, hash);
  }

  private applyInboundSqlite(envelope: FederationEnvelope, hash: string) {
    const db = this.sqlite!;
    const now = new Date().toISOString();
    db.exec('BEGIN IMMEDIATE');
    try {
      const ins = db.prepare(`INSERT OR IGNORE INTO federation_inbox(event_id,origin_node_id,payload_hash,received_at) VALUES(?,?,?,?)`).run(envelope.eventId, envelope.originNodeId, hash, now);
      if (Number(ins.changes) === 0) {
        db.exec('COMMIT');
        void this.increment('duplicate_events_rejected');
        return { duplicate: true };
      }
      const recipient = parseLoomAddress(envelope.recipientAddresses[0]);
      const account = db.prepare(`SELECT id FROM accounts WHERE lower(username)=lower(?)`).get(recipient.username) as Record<string, unknown> | undefined;
      if (!account) throw new Error('federation_recipient_not_found');
      const accountId = String(account.id);
      const existing = db.prepare(`SELECT c.id FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id JOIN conversation_remote_members rm ON rm.conversation_id=c.id WHERE cm.account_id=? AND lower(rm.remote_address)=lower(?) LIMIT 1`).get(accountId, envelope.senderAddress) as Record<string, unknown> | undefined;
      const conversationId = existing ? String(existing.id) : `conv_${randomUUID()}`;
      if (!existing) {
        db.prepare(`INSERT INTO conversations(id,kind,title,peer_address,created_at) VALUES(?,'direct',NULL,?,?)`).run(conversationId, envelope.senderAddress, now);
        db.prepare(`INSERT INTO conversation_members(conversation_id,account_id) VALUES(?,?)`).run(conversationId, accountId);
        db.prepare(`INSERT INTO conversation_remote_members(conversation_id,remote_address,remote_node_id) VALUES(?,?,?)`).run(conversationId, envelope.senderAddress, envelope.originNodeId);
      }
      const order = Number((db.prepare(`SELECT MAX(value)+1 next_order FROM (SELECT COALESCE(MAX(server_order),0) value FROM messages UNION ALL SELECT COALESCE(MAX(server_order),0) value FROM federation_remote_messages)`).get() as Record<string, unknown>).next_order);
      const messageId = `rmsg_${envelope.eventId.slice(5)}`;
      db.prepare(`INSERT INTO federation_remote_messages(id,event_id,conversation_id,sender_address,client_id,type,ciphertext,protocol_version,reply_to_message_id,metadata_json,server_order,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`).run(messageId, envelope.eventId, conversationId, envelope.senderAddress, envelope.payload.clientId, envelope.payload.type, envelope.payload.ciphertext, envelope.payload.protocolVersion, envelope.payload.replyToMessageId ?? null, JSON.stringify(envelope.payload.metadata ?? {}), order, (envelope.payload.createdAt ?? envelope.createdAt));
      let eventOrder = Number((db.prepare(`SELECT COALESCE(MAX(event_order),0)+1 next_order FROM events WHERE account_id=?`).get(accountId) as Record<string, unknown>).next_order);
      if (!existing) {
        const conversationPayload = {
          id: conversationId,
          kind: 'direct',
          title: null,
          peerAddress: envelope.senderAddress,
          updatedOrder: order,
          unreadCount: 1,
          isMuted: false,
          isPinned: false,
        };
        db.prepare(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES(?,?,?,?,?,?)`).run(
          `evt_${randomUUID()}`,
          accountId,
          'conversation.upsert',
          eventOrder,
          JSON.stringify(conversationPayload),
          now,
        );
        eventOrder += 1;
      }
      const payload = { id: messageId, clientId: envelope.payload.clientId, conversationId, senderAddress: envelope.senderAddress, type: envelope.payload.type, ciphertext: envelope.payload.ciphertext, protocolVersion: envelope.payload.protocolVersion, replyToMessageId: envelope.payload.replyToMessageId ?? null, metadata: envelope.payload.metadata ?? {}, serverOrder: order, createdAt: (envelope.payload.createdAt ?? envelope.createdAt) };
      db.prepare(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES(?,?,?,?,?,?)`).run(`evt_${randomUUID()}`, accountId, 'message.created', eventOrder, JSON.stringify(payload), now);
      db.exec('COMMIT');
      void this.increment('received_events_total');
      return { duplicate: false, conversationId, messageId };
    } catch (e) {
      try { db.exec('ROLLBACK'); } catch { }
      throw e;
    }
  }

  private async applyInboundPostgres(envelope: FederationEnvelope, hash: string) {
    const client = await this.pool!.connect();
    const now = new Date().toISOString();
    try {
      await client.query('BEGIN');
      const ins = await client.query(`INSERT INTO federation_inbox(event_id,origin_node_id,payload_hash,received_at) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`, [envelope.eventId, envelope.originNodeId, hash, now]);
      if (ins.rowCount === 0) {
        await client.query('COMMIT');
        await this.increment('duplicate_events_rejected');
        return { duplicate: true };
      }
      const recipient = parseLoomAddress(envelope.recipientAddresses[0]);
      const account = (await client.query(`SELECT id FROM accounts WHERE lower(username)=lower($1)`, [recipient.username])).rows[0];
      if (!account) throw new Error('federation_recipient_not_found');
      const accountId = String(account.id);
      const existing = (await client.query(`SELECT c.id FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id JOIN conversation_remote_members rm ON rm.conversation_id=c.id WHERE cm.account_id=$1 AND lower(rm.remote_address)=lower($2) LIMIT 1`, [accountId, envelope.senderAddress])).rows[0];
      const conversationId = existing ? String(existing.id) : `conv_${randomUUID()}`;
      if (!existing) {
        await client.query(`INSERT INTO conversations(id,kind,title,peer_address,created_at) VALUES($1,'direct',NULL,$2,$3)`, [conversationId, envelope.senderAddress, now]);
        await client.query(`INSERT INTO conversation_members(conversation_id,account_id) VALUES($1,$2)`, [conversationId, accountId]);
        await client.query(`INSERT INTO conversation_remote_members(conversation_id,remote_address,remote_node_id) VALUES($1,$2,$3)`, [conversationId, envelope.senderAddress, envelope.originNodeId]);
      }
      const messageId = `rmsg_${envelope.eventId.slice(5)}`;
      const inserted = (await client.query(`INSERT INTO federation_remote_messages(id,event_id,conversation_id,sender_address,client_id,type,ciphertext,protocol_version,reply_to_message_id,metadata_json,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11) RETURNING server_order`, [messageId, envelope.eventId, conversationId, envelope.senderAddress, envelope.payload.clientId, envelope.payload.type, envelope.payload.ciphertext, envelope.payload.protocolVersion, envelope.payload.replyToMessageId ?? null, JSON.stringify(envelope.payload.metadata ?? {}), (envelope.payload.createdAt ?? envelope.createdAt)])).rows[0];
      if (!existing) {
        await client.query(`INSERT INTO account_event_sequences(account_id,next_order) VALUES($1,2) ON CONFLICT(account_id) DO UPDATE SET next_order=account_event_sequences.next_order+1`, [accountId]);
        const conversationSeq = (await client.query(`SELECT next_order-1 event_order FROM account_event_sequences WHERE account_id=$1`, [accountId])).rows[0];
        const conversationPayload = {
          id: conversationId,
          kind: 'direct',
          title: null,
          peerAddress: envelope.senderAddress,
          updatedOrder: Number(inserted.server_order),
          unreadCount: 1,
          isMuted: false,
          isPinned: false,
        };
        await client.query(
          `INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES($1,$2,'conversation.upsert',$3,$4::jsonb,$5)`,
          [`evt_${randomUUID()}`, accountId, conversationSeq.event_order, JSON.stringify(conversationPayload), now],
        );
      }
      await client.query(`INSERT INTO account_event_sequences(account_id,next_order) VALUES($1,2) ON CONFLICT(account_id) DO UPDATE SET next_order=account_event_sequences.next_order+1`, [accountId]);
      const seq = (await client.query(`SELECT next_order-1 event_order FROM account_event_sequences WHERE account_id=$1`, [accountId])).rows[0];
      const payload = { id: messageId, clientId: envelope.payload.clientId, conversationId, senderAddress: envelope.senderAddress, type: envelope.payload.type, ciphertext: envelope.payload.ciphertext, protocolVersion: envelope.payload.protocolVersion, replyToMessageId: envelope.payload.replyToMessageId ?? null, metadata: envelope.payload.metadata ?? {}, serverOrder: Number(inserted.server_order), createdAt: (envelope.payload.createdAt ?? envelope.createdAt) };
      await client.query(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES($1,$2,'message.created',$3,$4::jsonb,$5)`, [`evt_${randomUUID()}`, accountId, seq.event_order, JSON.stringify(payload), now]);
      await client.query('COMMIT');
      await this.increment('received_events_total');
      return { duplicate: false, conversationId, messageId };
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
  }

  private async increment(key: string) {
    const now = new Date().toISOString();
    if (this.sqlite) {
      this.sqlite.prepare(`INSERT INTO federation_metrics(key,value,updated_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET value=value+1,updated_at=excluded.updated_at`).run(key, now);
    } else {
      await this.pool!.query(`INSERT INTO federation_metrics(key,value,updated_at) VALUES($1,1,$2) ON CONFLICT(key) DO UPDATE SET value=federation_metrics.value+1,updated_at=EXCLUDED.updated_at`, [key, now]);
    }
  }

  async noteMetric(key: string) { await this.increment(key); }

  async diagnostics(): Promise<Record<string, unknown>> {
    const statuses = ['pending', 'retrying', 'failed', 'delivered'];
    const queue: Record<string, number> = {};
    for (const status of statuses) {
      if (this.sqlite) queue[status] = Number((this.sqlite.prepare(`SELECT COUNT(*) value FROM federation_outbox WHERE status=?`).get(status) as Record<string, unknown>).value);
      else queue[status] = Number((await this.pool!.query(`SELECT COUNT(*) value FROM federation_outbox WHERE status=$1`, [status])).rows[0].value);
    }
    const metrics = this.sqlite
      ? this.sqlite.prepare(`SELECT key,value,updated_at FROM federation_metrics`).all() as Array<Record<string, unknown>>
      : (await this.pool!.query(`SELECT key,value,updated_at FROM federation_metrics`)).rows;
    return { queue, counters: Object.fromEntries(metrics.map(r => [String(r.key), Number(r.value)])) };
  }

  async listUsers(limit = 200): Promise<Array<Record<string, unknown>>> {
    const n = Math.max(1, Math.min(500, limit));
    if (this.sqlite) {
      return (this.sqlite.prepare(`SELECT a.id,a.username,a.display_name,a.created_at,(SELECT COUNT(*) FROM devices d WHERE d.account_id=a.id AND d.revoked_at IS NULL) device_count,(SELECT COUNT(*) FROM sessions s WHERE s.account_id=a.id AND s.expires_at>CURRENT_TIMESTAMP) active_session_count FROM accounts a ORDER BY a.created_at DESC LIMIT ?`).all(n) as Array<Record<string, unknown>>).map(r => ({ accountId: r.id, username: r.username, displayName: r.display_name, createdAt: iso(r.created_at), deviceCount: Number(r.device_count), activeSessionCount: Number(r.active_session_count) }));
    }
    return (await this.pool!.query(`SELECT a.id,a.username,a.display_name,a.created_at,(SELECT COUNT(*) FROM devices d WHERE d.account_id=a.id AND d.revoked_at IS NULL) device_count,(SELECT COUNT(*) FROM sessions s WHERE s.account_id=a.id AND s.expires_at>CURRENT_TIMESTAMP) active_session_count FROM accounts a ORDER BY a.created_at DESC LIMIT $1`, [n])).rows.map(r => ({ accountId: r.id, username: r.username, displayName: r.display_name, createdAt: iso(r.created_at), deviceCount: Number(r.device_count), activeSessionCount: Number(r.active_session_count) }));
  }
}
