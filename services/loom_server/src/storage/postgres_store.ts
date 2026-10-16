import { type ProfileUpdate, profileRevision } from '../profile/profile.ts';
import { createHash, randomBytes, randomUUID, scryptSync, timingSafeEqual } from 'node:crypto';
import type { RegistrationInput, SessionInfo } from './sqlite_store.ts';
import { validateIdentityPublicMaterial } from '../identity/public_material.ts';

type QueryResult = { rows: Array<Record<string, unknown>>; rowCount: number | null };
type PgClient = { query(sql: string, values?: unknown[]): Promise<QueryResult>; release(): void };
type PgPool = { query(sql: string, values?: unknown[]): Promise<QueryResult>; connect(): Promise<PgClient>; end(): Promise<void> };

function hashToken(token: string): string { return createHash('sha256').update(token).digest('hex'); }
function encodeCursor(order: number): string { return Buffer.from(`v1:${order}`, 'utf8').toString('base64url'); }
function decodeCursor(cursor: string | null): number {
  if (!cursor) return 0;
  try {
    const value = Buffer.from(cursor, 'base64url').toString('utf8');
    if (!value.startsWith('v1:')) throw new Error();
    const order = Number(value.slice(3));
    if (!Number.isSafeInteger(order) || order < 0) throw new Error();
    return order;
  } catch { throw new Error('invalid_cursor'); }
}

export class PostgresStore {
  readonly pool: PgPool;

  private constructor(pool: PgPool) { this.pool = pool; }

  static async connect(databaseUrl: string): Promise<PostgresStore> {
    const module = await import('pg') as unknown as { Pool: new (options: Record<string, unknown>) => PgPool };
    const pool = new module.Pool({ connectionString: databaseUrl, max: 20, idleTimeoutMillis: 30_000, connectionTimeoutMillis: 10_000, ssl: databaseUrl.includes('sslmode=disable') ? false : undefined });
    const store = new PostgresStore(pool);
    await store.migrate();
    return store;
  }

  async close(): Promise<void> { await this.pool.end(); }

  async readProfile(accountId: string, domain: string) {
    const row = (await this.pool.query(`SELECT a.username,a.display_name,p.avatar_json,p.revision FROM accounts a LEFT JOIN account_profiles p ON p.account_id=a.id WHERE a.id=$1`, [accountId])).rows[0];
    if (!row) throw new Error('unauthorized');
    return { address: `@${row.username}:${domain}`, displayName: String(row.display_name), avatar: row.avatar_json ? JSON.parse(String(row.avatar_json)) : { png: null, color: 0 }, revision: row.revision ?? null };
  }

  async updateProfile(accountId: string, domain: string, input: ProfileUpdate) {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`UPDATE accounts SET display_name=$1 WHERE id=$2`, [input.displayName, accountId]);
      await client.query(`INSERT INTO account_profiles(account_id,avatar_json,revision,updated_at) VALUES($1,$2,$3,$4) ON CONFLICT(account_id) DO UPDATE SET avatar_json=excluded.avatar_json,revision=excluded.revision,updated_at=excluded.updated_at`, [accountId, JSON.stringify(input.avatar), profileRevision(), new Date().toISOString()]);
      const row = (await client.query(`SELECT a.username,a.display_name,p.avatar_json,p.revision FROM accounts a JOIN account_profiles p ON p.account_id=a.id WHERE a.id=$1`, [accountId])).rows[0];
      if (!row) throw new Error('unauthorized');
      const profile = { address: `@${row.username}:${domain}`, displayName: String(row.display_name), avatar: JSON.parse(String(row.avatar_json)), revision: row.revision };
      await client.query('COMMIT');
      return profile;
    } catch (error) { await client.query('ROLLBACK'); throw error; }
    finally { client.release(); }
  }

  async migrate(): Promise<void> {
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS account_presence (account_id TEXT PRIMARY KEY, seen_at TIMESTAMPTZ NOT NULL);
      CREATE TABLE IF NOT EXISTS accounts (
        id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL,
        identity_id TEXT NOT NULL UNIQUE, identity_public_key TEXT NOT NULL, identity_fingerprint TEXT NOT NULL,
        password_salt TEXT NOT NULL, password_hash TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_username_ci ON accounts ((lower(username)));
      CREATE TABLE IF NOT EXISTS account_profiles (
        account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
        avatar_json TEXT NOT NULL, revision TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        name TEXT NOT NULL, revoked_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY, refresh_hash TEXT NOT NULL UNIQUE,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        expires_at TIMESTAMPTZ NOT NULL, refresh_expires_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL
      );
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT, peer_address TEXT, created_at TIMESTAMPTZ NOT NULL
      );
      CREATE TABLE IF NOT EXISTS conversation_members (
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        PRIMARY KEY(conversation_id, account_id)
      );
      CREATE SEQUENCE IF NOT EXISTS message_server_order_seq;
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        sender_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        client_id TEXT NOT NULL, type TEXT NOT NULL, ciphertext TEXT NOT NULL, protocol_version TEXT NOT NULL,
        reply_to_message_id TEXT, metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
        server_order BIGINT NOT NULL UNIQUE DEFAULT nextval('message_server_order_seq'), created_at TIMESTAMPTZ NOT NULL,
        UNIQUE(sender_account_id, client_id)
      );
      CREATE TABLE IF NOT EXISTS account_event_sequences (account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE, next_order BIGINT NOT NULL DEFAULT 1);
      CREATE TABLE IF NOT EXISTS message_route_jobs (
        message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
        status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT NOT NULL, last_error TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_message_route_jobs_due ON message_route_jobs(status,next_attempt_at);
      CREATE TABLE IF NOT EXISTS events (
        event_id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        kind TEXT NOT NULL, event_order BIGINT NOT NULL, payload_json JSONB NOT NULL, created_at TIMESTAMPTZ NOT NULL,
        UNIQUE(account_id, event_order)
      );
      CREATE TABLE IF NOT EXISTS reads (
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        through_order BIGINT NOT NULL, PRIMARY KEY(conversation_id, account_id)
      );
      CREATE TABLE IF NOT EXISTS federation_request_nonces (node_id TEXT NOT NULL, nonce TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL, PRIMARY KEY(node_id,nonce));
      CREATE TABLE IF NOT EXISTS federation_event_replay (event_id TEXT PRIMARY KEY, expires_at TIMESTAMPTZ NOT NULL);
      CREATE INDEX IF NOT EXISTS idx_events_account_order ON events(account_id,event_order);
      CREATE INDEX IF NOT EXISTS idx_messages_conversation_order ON messages(conversation_id,server_order);
    `);
  }

  async register(input: RegistrationInput, domain: string): Promise<{ accountId: string; deviceId: string; address: string; accessToken: string; refreshToken: string; accessTokenExpiresInSeconds: number }> {
    if (input.protocolVersion !== 'Loom-Identity-v1') throw new Error('unsupported_identity_protocol');
    const username = input.username.trim().toLowerCase();
    if (!/^[a-z0-9_][a-z0-9_.-]{2,31}$/.test(username)) throw new Error('invalid_username');
    if (input.displayName.trim().length < 1 || input.displayName.trim().length > 80) throw new Error('invalid_display_name');
    if (input.password.length < 10 || input.password.length > 512) throw new Error('invalid_password');
    const identity = validateIdentityPublicMaterial(input.identity);
    const salt = randomBytes(16);
    const passwordHash = scryptSync(input.password, salt, 32);
    const accountId = `acc_${randomUUID()}`;
    const deviceId = `dev_${randomUUID()}`;
    const now = new Date().toISOString();
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const existingUsername = await client.query(`SELECT 1 FROM accounts WHERE lower(username)=lower($1) LIMIT 1`, [username]);
      if (existingUsername.rowCount) throw new Error('username_taken');
      const existingIdentity = await client.query(`SELECT 1 FROM accounts WHERE identity_id=$1 LIMIT 1`, [identity.identityId]);
      if (existingIdentity.rowCount) throw new Error('identity_already_registered');
      await client.query(`INSERT INTO accounts(id,username,display_name,identity_id,identity_public_key,identity_fingerprint,password_salt,password_hash,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`, [accountId, username, input.displayName.trim(), identity.identityId, identity.publicKey, identity.fingerprint, salt.toString('base64'), passwordHash.toString('base64'), now]);
      await client.query(`INSERT INTO devices(id,account_id,name,created_at) VALUES($1,$2,$3,$4)`, [deviceId, accountId, input.deviceName.trim().slice(0, 100) || 'Loom device', now]);
      await client.query('COMMIT');
    } catch (error: unknown) {
      await client.query('ROLLBACK');
      if (error instanceof Error && ['username_taken', 'identity_already_registered'].includes(error.message)) throw error;
      const databaseError = error as { code?: string; constraint?: string };
      if (databaseError.code === '23505') {
        const constraint = databaseError.constraint ?? '';
        if (constraint.includes('username')) throw new Error('username_taken');
        if (constraint.includes('identity')) throw new Error('identity_already_registered');
      }
      throw error;
    } finally { client.release(); }
    const session = await this.issueSession(accountId, deviceId);
    return { accountId, deviceId, address: `@${username}:${domain}`, ...session };
  }

  async login(username: string, password: string, deviceName = 'Loom device'): Promise<{ accountId: string; deviceId: string; username: string; identityId: string; accessToken: string; refreshToken: string; accessTokenExpiresInSeconds: number }> {
    const result = await this.pool.query(`SELECT id,username,identity_id,password_salt,password_hash FROM accounts WHERE lower(username)=lower($1)`, [username.trim()]);
    const row = result.rows[0];
    if (!row) throw new Error('invalid_credentials');
    const expected = Buffer.from(String(row.password_hash), 'base64');
    const actual = scryptSync(password, Buffer.from(String(row.password_salt), 'base64'), expected.length);
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) throw new Error('invalid_credentials');
    const accountId = String(row.id);
    const deviceId = `dev_${randomUUID()}`;
    await this.pool.query(`INSERT INTO devices(id,account_id,name,created_at) VALUES($1,$2,$3,$4)`, [deviceId, accountId, deviceName.trim().slice(0, 100) || 'Loom device', new Date().toISOString()]);
    return { accountId, deviceId, username: String(row.username), identityId: String(row.identity_id), ...(await this.issueSession(accountId, deviceId)) };
  }

  private async issueSession(accountId: string, deviceId: string): Promise<{ accessToken: string; refreshToken: string; accessTokenExpiresInSeconds: number }> {
    const accessToken = randomBytes(32).toString('base64url');
    const refreshToken = randomBytes(48).toString('base64url');
    const accessTokenExpiresInSeconds = 900;
    const now = Date.now();
    await this.pool.query(`INSERT INTO sessions(token_hash,refresh_hash,account_id,device_id,expires_at,refresh_expires_at,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)`, [hashToken(accessToken), hashToken(refreshToken), accountId, deviceId, new Date(now + accessTokenExpiresInSeconds * 1000).toISOString(), new Date(now + 30 * 86400000).toISOString(), new Date(now).toISOString()]);
    return { accessToken, refreshToken, accessTokenExpiresInSeconds };
  }

  async refresh(refreshToken: string): Promise<{ accountId: string; deviceId: string; username: string; accessToken: string; refreshToken: string; accessTokenExpiresInSeconds: number }> {
    if (!refreshToken || refreshToken.length > 1024) throw new Error('invalid_refresh_token');
    const refreshHash = hashToken(refreshToken);
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const row = (await client.query(`SELECT s.account_id,s.device_id,s.refresh_expires_at,a.username,d.revoked_at FROM sessions s JOIN accounts a ON a.id=s.account_id JOIN devices d ON d.id=s.device_id WHERE s.refresh_hash=$1 FOR UPDATE`, [refreshHash])).rows[0];
      if (!row || row.revoked_at || Date.parse(String(row.refresh_expires_at)) <= Date.now()) throw new Error('invalid_refresh_token');
      const accessToken = randomBytes(32).toString('base64url');
      const accessTokenExpiresInSeconds = 900;
      await client.query(`UPDATE sessions SET token_hash=$1,expires_at=$2 WHERE refresh_hash=$3`, [hashToken(accessToken), new Date(Date.now() + accessTokenExpiresInSeconds * 1000).toISOString(), refreshHash]);
      await client.query('COMMIT');
      return { accountId: String(row.account_id), deviceId: String(row.device_id), username: String(row.username), accessToken, refreshToken, accessTokenExpiresInSeconds };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally { client.release(); }
  }

  async authenticate(accessToken: string): Promise<SessionInfo | null> {
    const result = await this.pool.query(`SELECT s.account_id,s.device_id,s.expires_at,a.username,a.identity_id,d.revoked_at FROM sessions s JOIN accounts a ON a.id=s.account_id JOIN devices d ON d.id=s.device_id WHERE s.token_hash=$1`, [hashToken(accessToken)]);
    const row = result.rows[0];
    if (!row || row.revoked_at || Date.parse(String(row.expires_at)) <= Date.now()) return null;
    return { accountId: String(row.account_id), deviceId: String(row.device_id), username: String(row.username), identityId: String(row.identity_id) };
  }

  async listConversations(accountId: string): Promise<Array<Record<string, unknown>>> {
    const federationTable = (await this.pool.query(`SELECT to_regclass('federation_remote_messages') value`)).rows[0]?.value;
    if (!federationTable) {
      const r = await this.pool.query(`SELECT c.id,c.kind,c.title,c.peer_address,COALESCE(MAX(m.server_order),0) updated_order,COALESCE(SUM(CASE WHEN m.server_order>COALESCE(rd.through_order,0) AND m.sender_account_id<>$1 THEN 1 ELSE 0 END),0) unread_count FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id AND cm.account_id=$1 LEFT JOIN messages m ON m.conversation_id=c.id LEFT JOIN reads rd ON rd.conversation_id=c.id AND rd.account_id=$1 GROUP BY c.id ORDER BY updated_order DESC`, [accountId]);
      return r.rows.map(x => ({ id: x.id, kind: x.kind, title: x.title, peerAddress: x.peer_address, updatedOrder: Number(x.updated_order), unreadCount: Number(x.unread_count), isMuted: false, isPinned: false }));
    }
    const r = await this.pool.query(`
      WITH activity AS (
        SELECT conversation_id,server_order,CASE WHEN sender_account_id<>$1 THEN 1 ELSE 0 END incoming FROM messages
        UNION ALL
        SELECT conversation_id,server_order,1 incoming FROM federation_remote_messages
      )
      SELECT c.id,c.kind,c.title,c.peer_address,
        COALESCE(MAX(a.server_order),0) updated_order,
        COALESCE(SUM(CASE WHEN a.server_order>COALESCE(rd.through_order,0) AND a.incoming=1 THEN 1 ELSE 0 END),0) unread_count
      FROM conversations c
      JOIN conversation_members cm ON cm.conversation_id=c.id AND cm.account_id=$1
      LEFT JOIN activity a ON a.conversation_id=c.id
      LEFT JOIN reads rd ON rd.conversation_id=c.id AND rd.account_id=$1
      GROUP BY c.id ORDER BY updated_order DESC
    `, [accountId]);
    return r.rows.map(x => ({ id: x.id, kind: x.kind, title: x.title, peerAddress: x.peer_address, updatedOrder: Number(x.updated_order), unreadCount: Number(x.unread_count), isMuted: false, isPinned: false }));
  }

  async ensureSelfConversation(accountId: string, address: string): Promise<string> {
    const existing = (await this.pool.query(`SELECT c.id FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id WHERE cm.account_id=$1 AND c.kind='self' LIMIT 1`, [accountId])).rows[0];
    if (existing) return String(existing.id);
    const id = `conv_${randomUUID()}`;
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`INSERT INTO conversations(id,kind,title,peer_address,created_at) VALUES($1,'self',NULL,$2,$3)`, [id, address, new Date().toISOString()]);
      await client.query(`INSERT INTO conversation_members(conversation_id,account_id) VALUES($1,$2)`, [id, accountId]);
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally { client.release(); }
    return id;
  }

  async createMessage(accountId: string, input: { conversationId: string; clientId: string; senderAddress: string; type: string; ciphertext: string; protocolVersion: string; replyToMessageId?: string | null; metadata?: unknown }): Promise<Record<string, unknown>> {
    if (input.ciphertext.length < 1 || input.ciphertext.length > 1024 * 1024) throw new Error('invalid_ciphertext');
    if (!input.protocolVersion.trim()) throw new Error('invalid_protocol_version');
    if (!(await this.pool.query(`SELECT 1 FROM conversation_members WHERE conversation_id=$1 AND account_id=$2`, [input.conversationId, accountId])).rows[0]) throw new Error('conversation_not_found');
    const kind = (await this.pool.query(`SELECT kind FROM conversations WHERE id=$1`, [input.conversationId])).rows[0];
    if (kind?.kind === 'group') throw new Error('group_encryption_unavailable');
    const existing = (await this.pool.query(`SELECT id,client_id,server_order,created_at FROM messages WHERE sender_account_id=$1 AND client_id=$2`, [accountId, input.clientId])).rows[0];
    if (existing) {
      await this.pool.query(`INSERT INTO message_route_jobs(message_id,next_attempt_at) VALUES($1,$2) ON CONFLICT DO NOTHING`, [existing.id, new Date().toISOString()]);
      return { messageId: existing.id, clientId: existing.client_id, serverOrder: Number(existing.server_order), createdAt: new Date(String(existing.created_at)).toISOString() };
    }
    const messageId = `msg_${randomUUID()}`;
    const createdAt = new Date().toISOString();
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const inserted = (await client.query(`INSERT INTO messages(id,conversation_id,sender_account_id,client_id,type,ciphertext,protocol_version,reply_to_message_id,metadata_json,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10) RETURNING server_order`, [messageId, input.conversationId, accountId, input.clientId, input.type, input.ciphertext, input.protocolVersion, input.replyToMessageId ?? null, JSON.stringify(input.metadata ?? {}), createdAt])).rows[0];
      const serverOrder = Number(inserted.server_order);
      await client.query(`INSERT INTO message_route_jobs(message_id,next_attempt_at) VALUES($1,$2)`, [messageId, createdAt]);
      const members = (await client.query(`SELECT account_id FROM conversation_members WHERE conversation_id=$1`, [input.conversationId])).rows;
      for (const member of members) {
        const memberId = String(member.account_id);
        await client.query(`INSERT INTO account_event_sequences(account_id,next_order) VALUES($1,2) ON CONFLICT(account_id) DO UPDATE SET next_order=account_event_sequences.next_order+1`, [memberId]);
        const seq = (await client.query(`SELECT next_order-1 event_order FROM account_event_sequences WHERE account_id=$1`, [memberId])).rows[0];
        const payload = {
          id: messageId,
          clientId: input.clientId,
          conversationId: input.conversationId,
          senderAddress: input.senderAddress,
          type: input.type,
          ciphertext: input.ciphertext,
          protocolVersion: input.protocolVersion,
          replyToMessageId: input.replyToMessageId ?? null,
          metadata: input.metadata ?? {},
          serverOrder,
          createdAt,
        };
        await client.query(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES($1,$2,'message.created',$3,$4::jsonb,$5)`, [`evt_${randomUUID()}`, memberId, seq.event_order, JSON.stringify(payload), createdAt]);
      }
      await client.query('COMMIT');
      return { messageId, clientId: input.clientId, serverOrder, createdAt };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally { client.release(); }
  }

  async sync(accountId: string, cursor: string | null, limit: number): Promise<{ events: Array<Record<string, unknown>>; nextCursor: string; hasMore: boolean }> {
    const after = decodeCursor(cursor);
    const bounded = Math.max(1, Math.min(limit, 200));
    const r = await this.pool.query(`SELECT event_id,kind,event_order,payload_json FROM events WHERE account_id=$1 AND event_order>$2 ORDER BY event_order LIMIT $3`, [accountId, after, bounded + 1]);
    const hasMore = r.rows.length > bounded;
    const page = r.rows.slice(0, bounded);
    const last = page.length ? Number(page[page.length - 1].event_order) : after;
    return { events: page.map(x => ({ eventId: x.event_id, kind: x.kind, order: Number(x.event_order), payload: x.payload_json })), nextCursor: encodeCursor(last), hasMore };
  }

  async markRead(accountId: string, conversationId: string, throughOrder: number): Promise<void> {
    if (!Number.isSafeInteger(throughOrder) || throughOrder < 0) throw new Error('invalid_read_order');
    if (!(await this.pool.query(`SELECT 1 FROM conversation_members WHERE conversation_id=$1 AND account_id=$2`, [conversationId, accountId])).rows[0]) throw new Error('conversation_not_found');
    await this.pool.query(`INSERT INTO reads(conversation_id,account_id,through_order) VALUES($1,$2,$3) ON CONFLICT(conversation_id,account_id) DO UPDATE SET through_order=GREATEST(reads.through_order,EXCLUDED.through_order)`, [conversationId, accountId, throughOrder]);
  }

  async touchPresence(accountId: string, now = new Date()): Promise<void> {
    await this.pool.query(`INSERT INTO account_presence VALUES($1,$2) ON CONFLICT(account_id) DO UPDATE SET seen_at=EXCLUDED.seen_at`, [accountId, now.toISOString()]);
  }

  async conversationPresence(accountId: string, conversationId: string, homeDomain: string, now = new Date()) {
    const row = (await this.pool.query(`SELECT c.peer_address FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id WHERE cm.account_id=$1 AND c.id=$2 AND c.kind='direct'`, [accountId, conversationId])).rows[0];
    if (!row) return { available: false, online: false, lastSeenAt: null };
    const presence = (await this.pool.query(`SELECT p.seen_at FROM accounts a JOIN account_presence p ON p.account_id=a.id WHERE lower('@' || a.username || ':' || $1) = lower($2)`, [homeDomain, row.peer_address])).rows[0];
    const lastSeenAt = presence ? new Date(String(presence.seen_at)).toISOString() : null;
    return { available: true, online: lastSeenAt != null && now.getTime() - Date.parse(lastSeenAt) < 45_000, lastSeenAt };
  }

  async acknowledgeReceived(accountId: string, ownAddress: string, clientIds: string[]): Promise<number> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      let emitted = 0;
      for (const clientId of new Set(clientIds)) {
        const incoming = (await client.query(`SELECT payload_json FROM events WHERE account_id=$1 AND kind='message.created' AND payload_json->>'clientId'=$2 AND lower(payload_json->>'senderAddress') != lower($3) LIMIT 1`, [accountId, clientId, ownAddress])).rows[0];
        if (!incoming) continue;
        const payload = incoming.payload_json as Record<string, unknown>;
        const message = (await client.query(`SELECT m.id,m.sender_account_id FROM messages m JOIN accounts a ON a.id=m.sender_account_id WHERE m.client_id=$1 AND lower('@' || a.username || ':' || $2) = lower($3)`, [clientId, ownAddress.slice(ownAddress.indexOf(':') + 1), payload.senderAddress])).rows[0];
        if (!message) continue;
        const eventId = `recipient-delivered:${message.id}`;
        if ((await client.query('SELECT 1 FROM events WHERE event_id=$1', [eventId])).rows[0]) continue;
        await client.query(`INSERT INTO account_event_sequences(account_id,next_order) VALUES($1,2) ON CONFLICT(account_id) DO UPDATE SET next_order=account_event_sequences.next_order+1`, [message.sender_account_id]);
        const seq = (await client.query('SELECT next_order-1 value FROM account_event_sequences WHERE account_id=$1', [message.sender_account_id])).rows[0];
        const result = await client.query(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES($1,$2,'message.delivered',$3,$4::jsonb,$5) ON CONFLICT(event_id) DO NOTHING`, [eventId, message.sender_account_id, seq.value, JSON.stringify({clientId, messageId: message.id, deliveryEvidence: 'recipient-device'}), new Date().toISOString()]);
        emitted += result.rowCount ?? 0;
      }
      await client.query('COMMIT');
      return emitted;
    } catch (error) { await client.query('ROLLBACK'); throw error; }
    finally { client.release(); }
  }

  async pendingMessageRoutes(limit: number, busy: string[] = []): Promise<Array<Record<string, unknown>>> {
    return (await this.pool.query(`SELECT * FROM (
      SELECT m.*,a.username,j.attempts,j.next_attempt_at,ROW_NUMBER() OVER(PARTITION BY m.conversation_id ORDER BY m.server_order) AS route_rank
      FROM message_route_jobs j JOIN messages m ON m.id=j.message_id JOIN accounts a ON a.id=m.sender_account_id
      WHERE j.status='pending' AND NOT(m.conversation_id=ANY($2::text[]))
    ) ranked WHERE route_rank=1 AND next_attempt_at<=$1 ORDER BY server_order LIMIT $3`, [new Date().toISOString(), busy, limit])).rows;
  }
  async completeMessageRoute(id: string) { await this.pool.query(`UPDATE message_route_jobs SET status='done',last_error=NULL WHERE message_id=$1`, [id]); }
  async retryMessageRoute(id: string, attempts: number, next: string, error: string) {
    await this.pool.query(`UPDATE message_route_jobs SET attempts=$1,next_attempt_at=$2,last_error=$3 WHERE message_id=$4`, [attempts,next,error,id]);
  }

  async publicAccountCount(): Promise<number> {
    const result = await this.pool.query('SELECT COUNT(*)::bigint AS value FROM accounts');
    return Number(result.rows[0].value);
  }

  async stats(): Promise<Record<string, number>> {
    const out: Record<string, number> = {};
    for (const table of ['accounts', 'devices', 'conversations', 'messages', 'events']) {
      const r = await this.pool.query(`SELECT COUNT(*)::bigint value FROM ${table}`);
      out[table] = Number(r.rows[0].value);
    }
    out.pendingMessageRoutes = Number((await this.pool.query(`SELECT COUNT(*) value FROM message_route_jobs WHERE status='pending'`)).rows[0].value);
    out.groups = Number((await this.pool.query(`SELECT COUNT(*) value FROM conversations WHERE kind='group'`)).rows[0].value);
    return out;
  }
}

