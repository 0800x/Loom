import { passwordHasher } from '../security/password_hash.ts';
import { type ProfileUpdate, profileRevision } from '../profile/profile.ts';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { validateIdentityPublicMaterial } from '../identity/public_material.ts';

export interface RegistrationInput {
  username: string;
  displayName: string;
  password: string;
  deviceName: string;
  identity: { identityId: string; publicKey: string; fingerprint: string };
  protocolVersion: string;
}

export interface SessionInfo {
  accountId: string;
  deviceId: string;
  username: string;
  identityId: string;
}

function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

function encodeCursor(order: number): string {
  return Buffer.from(`v1:${order}`, 'utf8').toString('base64url');
}

function decodeCursor(cursor: string | null): number {
  if (!cursor) return 0;
  try {
    const value = Buffer.from(cursor, 'base64url').toString('utf8');
    if (!value.startsWith('v1:')) throw new Error();
    const order = Number(value.slice(3));
    if (!Number.isSafeInteger(order) || order < 0) throw new Error();
    return order;
  } catch {
    throw new Error('invalid_cursor');
  }
}

export class SqliteStore {
  readonly db: DatabaseSync;

  constructor(dataDirectory: string) {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
    this.migrate();
  }

  close(): void { this.db.close(); }

  private withTransaction<T>(action: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const value = action();
      this.db.exec('COMMIT');
      return value;
    } catch (error) {
      try { this.db.exec('ROLLBACK'); } catch { /* best effort rollback */ }
      throw error;
    }
  }

  private hasFederationMessages(): boolean {
    return Boolean(this.db.prepare(`SELECT 1 FROM sqlite_master WHERE type='table' AND name='federation_remote_messages'`).get());
  }

  readProfile(accountId: string, domain: string) {
    const row = this.db.prepare(`SELECT a.username,a.display_name,p.avatar_json,p.revision FROM accounts a LEFT JOIN account_profiles p ON p.account_id=a.id WHERE a.id=?`).get(accountId) as Record<string, unknown> | undefined;
    if (!row) throw new Error('unauthorized');
    return { address: `@${row.username}:${domain}`, displayName: String(row.display_name), avatar: row.avatar_json ? JSON.parse(String(row.avatar_json)) : { png: null, color: 0 }, revision: row.revision ?? null };
  }

  updateProfile(accountId: string, domain: string, input: ProfileUpdate) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.db.prepare(`UPDATE accounts SET display_name=? WHERE id=?`).run(input.displayName, accountId);
      this.db.prepare(`INSERT INTO account_profiles(account_id,avatar_json,revision,updated_at) VALUES(?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET avatar_json=excluded.avatar_json,revision=excluded.revision,updated_at=excluded.updated_at`).run(accountId, JSON.stringify(input.avatar), profileRevision(), new Date().toISOString());
      const profile = this.readProfile(accountId, domain);
      this.db.exec('COMMIT');
      return profile;
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }

  migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS account_presence (
        account_id TEXT PRIMARY KEY, seen_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS accounts (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL UNIQUE COLLATE NOCASE,
        display_name TEXT NOT NULL,
        identity_id TEXT NOT NULL UNIQUE,
        identity_public_key TEXT NOT NULL,
        identity_fingerprint TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS account_profiles (
        account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
        avatar_json TEXT NOT NULL, revision TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        revoked_at TEXT,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY,
        refresh_hash TEXT NOT NULL UNIQUE,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        expires_at TEXT NOT NULL,
        refresh_expires_at TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT,
        peer_address TEXT,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS conversation_members (
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        PRIMARY KEY (conversation_id, account_id)
      );
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        sender_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        client_id TEXT NOT NULL,
        type TEXT NOT NULL,
        ciphertext TEXT NOT NULL,
        protocol_version TEXT NOT NULL,
        reply_to_message_id TEXT,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        server_order INTEGER NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        UNIQUE(sender_account_id, client_id)
      );
      CREATE TABLE IF NOT EXISTS message_route_jobs (
        message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
        status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT NOT NULL, last_error TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_message_route_jobs_due ON message_route_jobs(status,next_attempt_at);
      CREATE TABLE IF NOT EXISTS events (
        event_id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        event_order INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(account_id, event_order)
      );
      CREATE TABLE IF NOT EXISTS reads (
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        through_order INTEGER NOT NULL,
        PRIMARY KEY(conversation_id, account_id)
      );
      CREATE TABLE IF NOT EXISTS federation_request_nonces (
        node_id TEXT NOT NULL,
        nonce TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY(node_id, nonce)
      );
      CREATE TABLE IF NOT EXISTS federation_event_replay (
        event_id TEXT PRIMARY KEY,
        expires_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS node_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_events_account_order ON events(account_id, event_order);
      CREATE INDEX IF NOT EXISTS idx_messages_conversation_order ON messages(conversation_id, server_order);
    `);
  }

  async register(input: RegistrationInput, domain: string): Promise<{ accountId: string; deviceId: string; address: string; accessToken: string; refreshToken: string; accessTokenExpiresInSeconds: number }> {
    if (input.protocolVersion !== 'Loom-Identity-v1') throw new Error('unsupported_identity_protocol');
    const username = input.username.trim().toLowerCase();
    if (!/^[a-z0-9_][a-z0-9_.-]{2,31}$/.test(username)) throw new Error('invalid_username');
    if (input.displayName.trim().length < 1 || input.displayName.trim().length > 80) throw new Error('invalid_display_name');
    if (input.password.length < 10 || input.password.length > 512) throw new Error('invalid_password');
    const identity = validateIdentityPublicMaterial(input.identity);
    const existingUsername = this.db.prepare(`SELECT 1 FROM accounts WHERE username=?`).get(username);
    if (existingUsername) throw new Error('username_taken');
    const existingIdentity = this.db.prepare(`SELECT 1 FROM accounts WHERE identity_id=?`).get(identity.identityId);
    if (existingIdentity) throw new Error('identity_already_registered');
    const salt = randomBytes(16);
    const passwordHash = await passwordHasher.hash(input.password, salt);
    const accountId = `acc_${randomUUID()}`;
    const deviceId = `dev_${randomUUID()}`;
    const now = new Date().toISOString();
    const transaction = () => this.withTransaction(() => {
      this.db.prepare(`INSERT INTO accounts(id,username,display_name,identity_id,identity_public_key,identity_fingerprint,password_salt,password_hash,created_at) VALUES(?,?,?,?,?,?,?,?,?)`)
        .run(accountId, username, input.displayName.trim(), identity.identityId, identity.publicKey, identity.fingerprint, salt.toString('base64'), passwordHash, now);
      this.db.prepare(`INSERT INTO devices(id,account_id,name,created_at) VALUES(?,?,?,?)`).run(deviceId, accountId, input.deviceName.trim().slice(0, 100) || 'Loom device', now);
    });
    try {
      transaction();
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes('accounts.username')) throw new Error('username_taken');
      if (message.includes('accounts.identity_id')) throw new Error('identity_already_registered');
      throw error;
    }
    const session = this.issueSession(accountId, deviceId);
    return { accountId, deviceId, address: `@${username}:${domain}`, ...session };
  }

  async login(username: string, password: string, deviceName = 'Loom device'): Promise<{ accountId: string; deviceId: string; username: string; identityId: string; accessToken: string; refreshToken: string; accessTokenExpiresInSeconds: number }> {
    const row = this.db.prepare(`SELECT id, username, identity_id, password_salt, password_hash FROM accounts WHERE username=?`).get(username.trim().toLowerCase()) as Record<string, unknown> | undefined;
    if (!row) throw new Error('invalid_credentials');
    const salt = Buffer.from(String(row.password_salt), 'base64');
    const oldHash=String(row.password_hash);
    const checked=await passwordHasher.verify(password,salt,oldHash);
    if(!checked.valid)throw new Error('invalid_credentials');
    if(checked.legacy){
      const upgraded=await passwordHasher.hash(password,salt);
      this.db.prepare('UPDATE accounts SET password_hash=? WHERE id=? AND password_hash=?').run(upgraded,String(row.id),oldHash);
    }
    const accountId = String(row.id);
    const deviceId = `dev_${randomUUID()}`;
    this.db.prepare(`INSERT INTO devices(id,account_id,name,created_at) VALUES(?,?,?,?)`)
      .run(deviceId, accountId, deviceName.trim().slice(0, 100) || 'Loom device', new Date().toISOString());
    return { accountId, deviceId, username: String(row.username), identityId: String(row.identity_id), ...this.issueSession(accountId, deviceId) };
  }

  private issueSession(accountId: string, deviceId: string): { accessToken: string; refreshToken: string; accessTokenExpiresInSeconds: number } {
    const accessToken = randomBytes(32).toString('base64url');
    const refreshToken = randomBytes(48).toString('base64url');
    const accessSeconds = 900;
    const now = Date.now();
    this.db.prepare(`INSERT INTO sessions(token_hash,refresh_hash,account_id,device_id,expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?)`)
      .run(hashToken(accessToken), hashToken(refreshToken), accountId, deviceId, new Date(now + accessSeconds * 1000).toISOString(), new Date(now + 30 * 86400000).toISOString(), new Date(now).toISOString());
    return { accessToken, refreshToken, accessTokenExpiresInSeconds: accessSeconds };
  }

  refresh(refreshToken: string): { accountId: string; deviceId: string; username: string; accessToken: string; refreshToken: string; accessTokenExpiresInSeconds: number } {
    if (!refreshToken || refreshToken.length > 1024) throw new Error('invalid_refresh_token');
    const refreshHash = hashToken(refreshToken);
    const row = this.db.prepare(`SELECT s.account_id,s.device_id,s.refresh_expires_at,a.username,d.revoked_at FROM sessions s JOIN accounts a ON a.id=s.account_id JOIN devices d ON d.id=s.device_id WHERE s.refresh_hash=?`).get(refreshHash) as Record<string, unknown> | undefined;
    if (!row || row.revoked_at || Date.parse(String(row.refresh_expires_at)) <= Date.now()) throw new Error('invalid_refresh_token');
    const accessToken = randomBytes(32).toString('base64url');
    const accessTokenExpiresInSeconds = 900;
    this.db.prepare(`UPDATE sessions SET token_hash=?,expires_at=? WHERE refresh_hash=?`)
      .run(hashToken(accessToken), new Date(Date.now() + accessTokenExpiresInSeconds * 1000).toISOString(), refreshHash);
    return { accountId: String(row.account_id), deviceId: String(row.device_id), username: String(row.username), accessToken, refreshToken, accessTokenExpiresInSeconds };
  }

  authenticate(accessToken: string): SessionInfo | null {
    const row = this.db.prepare(`SELECT s.account_id,s.device_id,s.expires_at,a.username,a.identity_id,d.revoked_at FROM sessions s JOIN accounts a ON a.id=s.account_id JOIN devices d ON d.id=s.device_id WHERE s.token_hash=?`).get(hashToken(accessToken)) as Record<string, unknown> | undefined;
    if (!row || row.revoked_at || Date.parse(String(row.expires_at)) <= Date.now()) return null;
    return { accountId: String(row.account_id), deviceId: String(row.device_id), username: String(row.username), identityId: String(row.identity_id) };
  }

  listConversations(accountId: string): Array<Record<string, unknown>> {
    if (!this.hasFederationMessages()) {
      const rows = this.db.prepare(`
        SELECT c.id,c.kind,c.title,c.peer_address,
          COALESCE(MAX(m.server_order),0) updated_order,
          COALESCE(SUM(CASE WHEN m.server_order > COALESCE(r.through_order,0) AND m.sender_account_id <> ? THEN 1 ELSE 0 END),0) unread_count
        FROM conversations c
        JOIN conversation_members cm ON cm.conversation_id=c.id AND cm.account_id=?
        LEFT JOIN messages m ON m.conversation_id=c.id
        LEFT JOIN reads r ON r.conversation_id=c.id AND r.account_id=?
        GROUP BY c.id ORDER BY updated_order DESC
      `).all(accountId, accountId, accountId) as Array<Record<string, unknown>>;
      return rows.map((r) => ({ id: r.id, kind: r.kind, title: r.title, peerAddress: r.peer_address, updatedOrder: Number(r.updated_order), unreadCount: Number(r.unread_count), isMuted: false, isPinned: false }));
    }
    const rows = this.db.prepare(`
      WITH activity AS (
        SELECT conversation_id,server_order,CASE WHEN sender_account_id<>? THEN 1 ELSE 0 END incoming FROM messages
        UNION ALL
        SELECT conversation_id,server_order,1 incoming FROM federation_remote_messages
      )
      SELECT c.id,c.kind,c.title,c.peer_address,
        COALESCE(MAX(a.server_order),0) updated_order,
        COALESCE(SUM(CASE WHEN a.server_order>COALESCE(r.through_order,0) AND a.incoming=1 THEN 1 ELSE 0 END),0) unread_count
      FROM conversations c
      JOIN conversation_members cm ON cm.conversation_id=c.id AND cm.account_id=?
      LEFT JOIN activity a ON a.conversation_id=c.id
      LEFT JOIN reads r ON r.conversation_id=c.id AND r.account_id=?
      GROUP BY c.id ORDER BY updated_order DESC
    `).all(accountId, accountId, accountId) as Array<Record<string, unknown>>;
    return rows.map((r) => ({ id: r.id, kind: r.kind, title: r.title, peerAddress: r.peer_address, updatedOrder: Number(r.updated_order), unreadCount: Number(r.unread_count), isMuted: false, isPinned: false }));
  }

  ensureSelfConversation(accountId: string, address: string): string {
    const existing = this.db.prepare(`SELECT c.id FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id WHERE cm.account_id=? AND c.kind='self' LIMIT 1`).get(accountId) as Record<string, unknown> | undefined;
    if (existing) return String(existing.id);
    const id = `conv_${randomUUID()}`;
    const tx = () => this.withTransaction(() => {
      this.db.prepare(`INSERT INTO conversations(id,kind,title,peer_address,created_at) VALUES(?,?,?,?,?)`).run(id, 'self', null, address, new Date().toISOString());
      this.db.prepare(`INSERT INTO conversation_members(conversation_id,account_id) VALUES(?,?)`).run(id, accountId);
    });
    tx();
    return id;
  }

  createMessage(accountId: string, input: { conversationId: string; clientId: string; senderAddress: string; type: string; ciphertext: string; protocolVersion: string; replyToMessageId?: string | null; metadata?: unknown }): Record<string, unknown> {
    if (input.ciphertext.length < 1 || input.ciphertext.length > 1024 * 1024) throw new Error('invalid_ciphertext');
    if (!input.protocolVersion.trim()) throw new Error('invalid_protocol_version');
    const member = this.db.prepare(`SELECT 1 ok FROM conversation_members WHERE conversation_id=? AND account_id=?`).get(input.conversationId, accountId);
    if (!member) throw new Error('conversation_not_found');
    const kind = this.db.prepare(`SELECT kind FROM conversations WHERE id=?`).get(input.conversationId) as Record<string, unknown> | undefined;
    if (kind?.kind === 'group') throw new Error('group_encryption_unavailable');
    const existing = this.db.prepare(`SELECT id,client_id,server_order,created_at FROM messages WHERE sender_account_id=? AND client_id=?`).get(accountId, input.clientId) as Record<string, unknown> | undefined;
    if (existing) {
      this.db.prepare(`INSERT OR IGNORE INTO message_route_jobs(message_id,next_attempt_at) VALUES(?,?)`).run(existing.id, new Date().toISOString());
      return { messageId: existing.id, clientId: existing.client_id, serverOrder: Number(existing.server_order), createdAt: existing.created_at };
    }
    const messageId = `msg_${randomUUID()}`;
    const eventId = `evt_${randomUUID()}`;
    const createdAt = new Date().toISOString();
    const tx = () => this.withTransaction(() => {
      const orderRow = this.hasFederationMessages()
        ? this.db.prepare(`SELECT MAX(value)+1 next_order FROM (SELECT COALESCE(MAX(server_order),0) value FROM messages UNION ALL SELECT COALESCE(MAX(server_order),0) value FROM federation_remote_messages)`).get() as Record<string, unknown>
        : this.db.prepare(`SELECT COALESCE(MAX(server_order),0)+1 next_order FROM messages`).get() as Record<string, unknown>;
      const serverOrder = Number(orderRow.next_order);
      this.db.prepare(`INSERT INTO messages(id,conversation_id,sender_account_id,client_id,type,ciphertext,protocol_version,reply_to_message_id,metadata_json,server_order,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)`)
        .run(messageId, input.conversationId, accountId, input.clientId, input.type, input.ciphertext, input.protocolVersion, input.replyToMessageId ?? null, JSON.stringify(input.metadata ?? {}), serverOrder, createdAt);
      this.db.prepare(`INSERT INTO message_route_jobs(message_id,next_attempt_at) VALUES(?,?)`).run(messageId, createdAt);
      const members = this.db.prepare(`SELECT account_id FROM conversation_members WHERE conversation_id=?`).all(input.conversationId) as Array<Record<string, unknown>>;
      for (const memberRow of members) {
        const memberAccount = String(memberRow.account_id);
        const eventOrderRow = this.db.prepare(`SELECT COALESCE(MAX(event_order),0)+1 next_order FROM events WHERE account_id=?`).get(memberAccount) as Record<string, unknown>;
        const eventOrder = Number(eventOrderRow.next_order);
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
        this.db.prepare(`INSERT INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES(?,?,?,?,?,?)`).run(`${eventId}_${memberAccount}`, memberAccount, 'message.created', eventOrder, JSON.stringify(payload), createdAt);
      }
      return serverOrder;
    });
    const serverOrder = tx() as number;
    return { messageId, clientId: input.clientId, serverOrder, createdAt };
  }

  sync(accountId: string, cursor: string | null, limit: number): { events: Array<Record<string, unknown>>; nextCursor: string; hasMore: boolean } {
    const after = decodeCursor(cursor);
    const bounded = Math.max(1, Math.min(limit, 200));
    const rows = this.db.prepare(`SELECT event_id,kind,event_order,payload_json FROM events WHERE account_id=? AND event_order>? ORDER BY event_order LIMIT ?`).all(accountId, after, bounded + 1) as Array<Record<string, unknown>>;
    const hasMore = rows.length > bounded;
    const page = rows.slice(0, bounded);
    const lastOrder = page.length ? Number(page[page.length - 1].event_order) : after;
    return { events: page.map((r) => ({ eventId: r.event_id, kind: r.kind, order: Number(r.event_order), payload: JSON.parse(String(r.payload_json)) })), nextCursor: encodeCursor(lastOrder), hasMore };
  }

  markRead(accountId: string, conversationId: string, throughOrder: number): void {
    if (!Number.isSafeInteger(throughOrder) || throughOrder < 0) throw new Error('invalid_read_order');
    const member = this.db.prepare(`SELECT 1 ok FROM conversation_members WHERE conversation_id=? AND account_id=?`).get(conversationId, accountId);
    if (!member) throw new Error('conversation_not_found');
    this.db.prepare(`INSERT INTO reads(conversation_id,account_id,through_order) VALUES(?,?,?) ON CONFLICT(conversation_id,account_id) DO UPDATE SET through_order=MAX(reads.through_order,excluded.through_order)`).run(conversationId, accountId, throughOrder);
  }

  touchPresence(accountId: string, now = new Date()): void {
    this.db.prepare(`INSERT INTO account_presence VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET seen_at=excluded.seen_at`).run(accountId, now.toISOString());
  }

  conversationPresence(accountId: string, conversationId: string, homeDomain: string, now = new Date()) {
    const row = this.db.prepare(`SELECT c.peer_address FROM conversations c JOIN conversation_members cm ON cm.conversation_id=c.id WHERE cm.account_id=? AND c.id=? AND c.kind='direct'`).get(accountId, conversationId) as Record<string, unknown> | undefined;
    if (!row) return { available: false, online: false, lastSeenAt: null };
    const presence = this.db.prepare(`SELECT p.seen_at FROM accounts a JOIN account_presence p ON p.account_id=a.id WHERE lower('@' || a.username || ':' || ?) = lower(?)`).get(homeDomain, String(row.peer_address)) as Record<string, unknown> | undefined;
    const lastSeenAt = presence ? String(presence.seen_at) : null;
    return { available: true, online: lastSeenAt != null && now.getTime() - Date.parse(lastSeenAt) < 45_000, lastSeenAt };
  }

  /** Only the authenticated recipient can acknowledge its own incoming event. */
  acknowledgeReceived(accountId: string, ownAddress: string, clientIds: string[]): number {
    return this.withTransaction(() => {
      let emitted = 0;
      for (const clientId of new Set(clientIds)) {
        const incoming = this.db.prepare(`SELECT payload_json FROM events WHERE account_id=? AND kind='message.created' AND json_extract(payload_json,'$.clientId')=? AND lower(json_extract(payload_json,'$.senderAddress')) != lower(?) LIMIT 1`).get(accountId, clientId, ownAddress) as Record<string, unknown> | undefined;
        if (!incoming) continue;
        const payload = JSON.parse(String(incoming.payload_json));
        const message = this.db.prepare(`SELECT m.id,m.sender_account_id FROM messages m JOIN accounts a ON a.id=m.sender_account_id WHERE m.client_id=? AND lower('@' || a.username || ':' || ?) = lower(?)`).get(clientId, ownAddress.slice(ownAddress.indexOf(':') + 1), payload.senderAddress) as Record<string, unknown> | undefined;
        if (!message) continue; // Remote-node receipts need their authenticated federation path.
        const eventId = `recipient-delivered:${message.id}`;
        const order = this.db.prepare(`SELECT COALESCE(MAX(event_order),0)+1 value FROM events WHERE account_id=?`).get(String(message.sender_account_id)) as Record<string, unknown>;
        const result = this.db.prepare(`INSERT OR IGNORE INTO events(event_id,account_id,kind,event_order,payload_json,created_at) VALUES(?,?,'message.delivered',?,?,?)`).run(eventId, String(message.sender_account_id), Number(order.value), JSON.stringify({clientId, messageId: message.id, deliveryEvidence: 'recipient-device'}), new Date().toISOString());
        emitted += Number(result.changes);
      }
      return emitted;
    });
  }

  rememberFederationNonce(nodeId: string, nonce: string, expiresAt: Date): boolean {
    this.cleanupReplay();
    const result = this.db.prepare(`INSERT OR IGNORE INTO federation_request_nonces(node_id,nonce,expires_at) VALUES(?,?,?)`).run(nodeId, nonce, expiresAt.toISOString());
    return Number(result.changes) === 1;
  }

  rememberFederationEvent(eventId: string, expiresAt: Date): boolean {
    this.cleanupReplay();
    const result = this.db.prepare(`INSERT OR IGNORE INTO federation_event_replay(event_id,expires_at) VALUES(?,?)`).run(eventId, expiresAt.toISOString());
    return Number(result.changes) === 1;
  }

  private cleanupReplay(): void {
    const now = new Date().toISOString();
    this.db.prepare(`DELETE FROM federation_request_nonces WHERE expires_at < ?`).run(now);
    this.db.prepare(`DELETE FROM federation_event_replay WHERE expires_at < ?`).run(now);
  }

  pendingMessageRoutes(limit: number, busy: string[] = []): Array<Record<string, unknown>> {
    return this.db.prepare(`SELECT * FROM (
      SELECT m.*,a.username,j.attempts,j.next_attempt_at,ROW_NUMBER() OVER(PARTITION BY m.conversation_id ORDER BY m.server_order) AS route_rank
      FROM message_route_jobs j JOIN messages m ON m.id=j.message_id JOIN accounts a ON a.id=m.sender_account_id
      WHERE j.status='pending' AND m.conversation_id NOT IN (SELECT value FROM json_each(?))
    ) WHERE route_rank=1 AND next_attempt_at<=? ORDER BY server_order LIMIT ?`).all(JSON.stringify(busy), new Date().toISOString(), limit) as Array<Record<string, unknown>>;
  }
  completeMessageRoute(id: string) { this.db.prepare(`UPDATE message_route_jobs SET status='done',last_error=NULL WHERE message_id=?`).run(id); }
  retryMessageRoute(id: string, attempts: number, next: string, error: string) {
    this.db.prepare(`UPDATE message_route_jobs SET attempts=?,next_attempt_at=?,last_error=? WHERE message_id=?`).run(attempts,next,error,id);
  }

  publicAccountCount(): number {
    return Number((this.db.prepare('SELECT COUNT(*) AS value FROM accounts').get() as { value: number }).value);
  }

  stats(): Record<string, number> {
    const count = (table: string): number => Number((this.db.prepare(`SELECT COUNT(*) value FROM ${table}`).get() as Record<string, unknown>).value);
    const pendingRoutes = Number((this.db.prepare(`SELECT COUNT(*) value FROM message_route_jobs WHERE status='pending'`).get() as Record<string, unknown>).value);
    const groups = Number((this.db.prepare(`SELECT COUNT(*) value FROM conversations WHERE kind='group'`).get() as Record<string, unknown>).value);
    return { pendingMessageRoutes: pendingRoutes, groups, accounts: count('accounts'), devices: count('devices'), conversations: count('conversations'), messages: count('messages'), events: count('events') };
  }
}

