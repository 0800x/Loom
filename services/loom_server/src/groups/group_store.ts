import type { GroupCallAuthority, GroupCallRecord } from '../calls/group_call_policy.ts';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type { DatabaseSync } from 'node:sqlite';
import type { SessionInfo } from '../storage/sqlite_store.ts';
import { verifyRawEd25519 } from '../identity/public_material.ts';

export const GROUP_PROTOCOL = 'Loom-MLS-v1';
type Row = Record<string, unknown>;
type Statement = { sql: string; values: unknown[] };
type Query = (sql: string, values?: unknown[]) => Statement;
type Work<T> = Generator<Statement, T, Row[]>;
type PgClient = { query(sql: string, values?: unknown[]): Promise<{ rows: Row[] }>; release(): void };
export type GroupPool = { connect(): Promise<PgClient> };
export type GroupMember = { accountId: string; deviceId: string; role: 'owner' | 'admin' | 'member'; identityId: string; mlsSignatureKey: string; mlsSignature: string };
export type GroupState = { id: string; title: string; epoch: number; revision: number; sequence: number; members: GroupMember[] };
type PackageInput = { id: string; serialized: string; expiresAt: string; signature: string };
type Change = { operationId: string; title: string; epoch: number; members: GroupMember[]; commit: string; welcomes: Record<string, string>; claims: Record<string, string>; joinRequestDeviceId?: string };

export class GroupError extends Error {
  readonly status: number;
  constructor(status: number, code: string) { super(code); this.status = status; }
}
function fail(status: number, code: string): never { throw new GroupError(status, code); }
function id(value: unknown): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) fail(400, 'invalid_group_id');
  return value;
}
function bytes(value: unknown, max = 1048576): string {
  if (typeof value !== 'string' || !value || value.length > Math.ceil(max / 3) * 4 || Buffer.from(value, 'base64').toString('base64') !== value) fail(400, 'invalid_mls_payload');
  return value;
}
function integer(value: unknown): number {
  if (!Number.isSafeInteger(value) || Number(value) < 0) fail(400, 'invalid_group_revision');
  return Number(value);
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(400, 'invalid_group_request');
  return value as Record<string, unknown>;
}
function digest(value: unknown): string { return createHash('sha256').update(JSON.stringify(value)).digest('hex'); }
export function keyPackageBinding(session: Pick<SessionInfo, 'identityId' | 'deviceId'>, p: PackageInput): Buffer {
  return Buffer.from(JSON.stringify({ protocol: GROUP_PROTOCOL, identityId: session.identityId, deviceId: session.deviceId, id: p.id, sha256: createHash('sha256').update(Buffer.from(p.serialized, 'base64')).digest('hex'), expiresAt: p.expiresAt }));
}
export function mlsDeviceBinding(m: Pick<GroupMember, 'identityId' | 'deviceId' | 'mlsSignatureKey'>): Buffer {
  return Buffer.from(JSON.stringify({ protocol: 'Loom-MLSDevice-v1', identityId: m.identityId, deviceId: m.deviceId, mlsSignatureKey: m.mlsSignatureKey }));
}
function change(value: unknown): Change {
  const v = object(value);
  const operationId = id(v.operationId);
  if (typeof v.title !== 'string' || !v.title.trim() || v.title.length > 100) fail(400, 'invalid_group_title');
  if (!Array.isArray(v.members) || v.members.length < 1 || v.members.length > 256) fail(400, 'invalid_group_members');
  const members = v.members.map(raw => {
    const m = object(raw);
    if (!['owner', 'admin', 'member'].includes(String(m.role))) fail(400, 'invalid_group_role');
    if (typeof m.identityId !== 'string' || !/^chn:[A-Za-z0-9_-]{43}$/.test(m.identityId)) fail(400, 'invalid_group_identity');
    const mlsSignatureKey = bytes(m.mlsSignatureKey, 32), mlsSignature = bytes(m.mlsSignature, 64);
    if (Buffer.from(mlsSignatureKey, 'base64').length !== 32 || Buffer.from(mlsSignature, 'base64').length !== 64) fail(400, 'invalid_group_credential');
    return { accountId: id(m.accountId), deviceId: id(m.deviceId), role: m.role, identityId: m.identityId, mlsSignatureKey, mlsSignature } as GroupMember;
  }).sort((a, b) => a.deviceId.localeCompare(b.deviceId));
  if (new Set(members.map(m => m.deviceId)).size !== members.length) fail(400, 'duplicate_group_device');
  const owners = new Set(members.filter(m => m.role === 'owner').map(m => m.accountId));
  if (owners.size !== 1 || members.some(m => members.some(n => n.accountId === m.accountId && n.role !== m.role))) fail(400, 'invalid_group_owner');
  const welcomes = Object.fromEntries(Object.entries(object(v.welcomes)).map(([k, val]) => [id(k), bytes(val)]));
  const claims = Object.fromEntries(Object.entries(object(v.claims)).map(([k, val]) => [id(k), id(val)]));
  return { operationId, title: v.title.trim(), epoch: integer(v.epoch), members, commit: bytes(v.commit), welcomes, claims, ...(v.joinRequestDeviceId == null ? {} : { joinRequestDeviceId: id(v.joinRequestDeviceId) }) };
}

/** Opaque MLS delivery and membership authority. Never handles group secret keys.
 * One transaction serializes each group's commits, messages, membership and inbox.
 * SQLite and PostgreSQL use the same SQL and the same authorization code. */
export class GroupStore {
  private ready: Promise<void>;
  private sqlite?: DatabaseSync;
  private pool?: GroupPool;
  constructor(sqlite?: DatabaseSync, pool?: GroupPool) {
    this.sqlite = sqlite; this.pool = pool;
    if (!sqlite && !pool) throw new Error('Group database required');
    this.ready = this.transaction(function* (q) {
      for (const sql of [
        `CREATE TABLE IF NOT EXISTS mls_credentials(device_id TEXT PRIMARY KEY,account_id TEXT NOT NULL,identity_id TEXT NOT NULL,signature_key TEXT NOT NULL,payload_json TEXT NOT NULL)`,
        `CREATE TABLE IF NOT EXISTS mls_groups(id TEXT PRIMARY KEY, state_json TEXT NOT NULL)`,
        `CREATE TABLE IF NOT EXISTS mls_group_calls(group_id TEXT PRIMARY KEY,room_name TEXT UNIQUE NOT NULL,phase TEXT NOT NULL,record_json TEXT NOT NULL)`,
        `CREATE TABLE IF NOT EXISTS mls_group_policy(group_id TEXT PRIMARY KEY, paused INTEGER NOT NULL, revision BIGINT NOT NULL)`,
        `CREATE TABLE IF NOT EXISTS mls_group_invites(token_hash TEXT PRIMARY KEY, group_id TEXT NOT NULL, mode TEXT NOT NULL, expires_at TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0)`,
        `CREATE INDEX IF NOT EXISTS mls_invite_group ON mls_group_invites(group_id)`,
        `CREATE TABLE IF NOT EXISTS mls_group_join_requests(group_id TEXT NOT NULL, device_id TEXT NOT NULL, account_id TEXT NOT NULL, identity_id TEXT NOT NULL, invite_hash TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(group_id,device_id))`,
        `CREATE TABLE IF NOT EXISTS mls_packages(id TEXT PRIMARY KEY, device_id TEXT NOT NULL, account_id TEXT NOT NULL, payload_json TEXT NOT NULL, expires_at TEXT NOT NULL, claim_id TEXT, claimed_by TEXT, claim_expires_at TEXT, consumed INTEGER NOT NULL DEFAULT 0)`,
        `CREATE INDEX IF NOT EXISTS mls_package_device ON mls_packages(device_id,consumed,expires_at)`,
        `CREATE TABLE IF NOT EXISTS mls_operations(group_id TEXT NOT NULL, device_id TEXT NOT NULL, operation_id TEXT NOT NULL, request_hash TEXT NOT NULL, result_json TEXT NOT NULL, PRIMARY KEY(group_id,device_id,operation_id))`,
        `CREATE TABLE IF NOT EXISTS mls_inbox(device_id TEXT NOT NULL, group_id TEXT NOT NULL, sequence BIGINT NOT NULL, event_json TEXT NOT NULL, PRIMARY KEY(device_id,group_id,sequence))`,
        `CREATE INDEX IF NOT EXISTS mls_inbox_group ON mls_inbox(group_id)`,
      ]) yield q(sql);
    });
  }
  async initialize(): Promise<void> { await this.ready; }
  /** Fresh authority and room updates share the MLS membership transaction. */
  async withGroupCall<T>(groupId:string,session:SessionInfo|undefined,action:(a:GroupCallAuthority)=>T):Promise<T> {
    id(groupId);
    return this.run(function* (q) {
      if(session)yield* this.active(q,session);
      const group=yield* this.state(q,groupId);
      const actor=session?this.member(group,session):undefined;
      const policy=yield* this.policy(q,groupId);
      const rows=yield q(`SELECT id,account_id FROM devices WHERE revoked_at IS NULL AND id IN (${group.members.map((_,i)=>'$'+(i+1)).join(',')})`,group.members.map(m=>m.deviceId));
      const activeDevices=new Set(rows.filter(r=>group.members.some(m=>m.deviceId===r.id&&m.accountId===r.account_id)).map(r=>String(r.id)));
      const calls=yield q(`SELECT record_json FROM mls_group_calls WHERE group_id=$1`,[groupId]);
      const a:GroupCallAuthority={group,actor,paused:policy.paused,activeDevices,call:calls[0]?JSON.parse(String(calls[0].record_json)) as GroupCallRecord:null};
      const result=action(a);if(result instanceof Promise)throw new Error('Room transactions must be synchronous');
      if(a.call)yield q(`INSERT INTO mls_group_calls VALUES($1,$2,$3,$4) ON CONFLICT(group_id) DO UPDATE SET room_name=excluded.room_name,phase=excluded.phase,record_json=excluded.record_json`,[groupId,a.call.room,a.call.phase==='ended'&&!a.call.transportClosed?'closing':a.call.phase,JSON.stringify(a.call)]);
      return result;
    });
  }
  async groupCallIdForRoom(room:string):Promise<string|undefined>{
    if(!/^gc_[a-f0-9-]{36}$/.test(room))return undefined;
    return this.run(function* (q){const rows=yield q(`SELECT group_id FROM mls_group_calls WHERE room_name=$1`,[room]);return rows[0]?String(rows[0].group_id):undefined;});
  }
  async activeGroupCallIds():Promise<string[]>{return this.run(function* (q){return (yield q(`SELECT group_id FROM mls_group_calls WHERE phase IN ('active','closing') ORDER BY group_id LIMIT 1000`)).map(r=>String(r.group_id));});}
  private inviteHash(token: string) {
    if (!/^[A-Za-z0-9_-]{43}$/.test(token)) fail(404, 'group_invite_unavailable');
    return createHash('sha256').update(token).digest('hex');
  }
  private *invite(q: Query, token: string): Work<Row> {
    const row = (yield q(`SELECT * FROM mls_group_invites WHERE token_hash=$1 AND revoked=0 AND expires_at>$2`, [this.inviteHash(token), new Date().toISOString()]))[0];
    if (!row) fail(404, 'group_invite_unavailable');
    return row;
  }
  private admin(state: GroupState, s: SessionInfo) {
    if (this.member(state, s).role === 'member') fail(403, 'group_admin_required');
  }
  async memberProfile(s: SessionInfo, deviceId: string) {
    return this.run(function* (q) {
      yield* this.active(q, s);
      const row = (yield q(`SELECT a.id,a.username,a.display_name,a.identity_id FROM accounts a JOIN devices d ON d.account_id=a.id WHERE d.id=$1 AND d.revoked_at IS NULL`, [id(deviceId)]))[0];
      if (!row) fail(404, 'group_device_unavailable');
      return { accountId: String(row.id), identityId: String(row.identity_id), username: String(row.username), displayName: String(row.display_name) };
    });
  }
  async createInvite(s: SessionInfo, groupId: string, value: unknown) {
    const v = object(value);
    if (!['open', 'approval'].includes(String(v.mode))) fail(400, 'invalid_group_join_mode');
    const hours = v.expiresInHours == null ? 168 : integer(v.expiresInHours);
    if (hours < 1 || hours > 8760) fail(400, 'invalid_group_invite_expiry');
    const token = randomBytes(32).toString('base64url');
    return this.run(function* (q) {
      yield* this.active(q, s); const state = yield* this.state(q, groupId); this.admin(state, s);
      yield q(`UPDATE mls_group_invites SET revoked=1 WHERE group_id=$1`, [groupId]);
      const expiresAt = new Date(Date.now() + hours * 3600000).toISOString();
      yield q(`INSERT INTO mls_group_invites VALUES($1,$2,$3,$4,0)`, [this.inviteHash(token), groupId, v.mode, expiresAt]);
      return { token, groupId, mode: v.mode, expiresAt };
    });
  }
  async revokeInvites(s: SessionInfo, groupId: string) {
    return this.run(function* (q) {
      yield* this.active(q, s); const state = yield* this.state(q, groupId); this.admin(state, s);
      yield q(`UPDATE mls_group_invites SET revoked=1 WHERE group_id=$1`, [groupId]);
      return { ok: true };
    });
  }
  async previewInvite(s: SessionInfo, token: string) {
    return this.run(function* (q) {
      yield* this.active(q, s); const invite = yield* this.invite(q, token);
      const state = yield* this.state(q, String(invite.group_id));
      const request = (yield q(`SELECT status FROM mls_group_join_requests WHERE group_id=$1 AND device_id=$2 AND invite_hash=$3`, [state.id, s.deviceId, invite.token_hash]))[0];
      return { groupId: state.id, title: state.title, memberCount: new Set(state.members.map(m => m.accountId)).size,
        mode: invite.mode, expiresAt: invite.expires_at, status: state.members.some(m => m.deviceId === s.deviceId) ? 'joined' : request?.status === 'joined' ? 'removed' : request?.status ?? 'none' };
    });
  }
  async requestJoin(s: SessionInfo, token: string) {
    return this.run(function* (q) {
      yield* this.active(q, s); const invite = yield* this.invite(q, token);
      const state = yield* this.state(q, String(invite.group_id));
      if (state.members.some(m => m.deviceId === s.deviceId)) return { groupId: state.id, status: 'joined' };
      if ((yield* this.policy(q, state.id)).paused) fail(423, 'group_paused');
      if (state.members.length >= 256) fail(409, 'group_full');
      if (!(yield q(`SELECT device_id FROM mls_credentials WHERE device_id=$1 AND account_id=$2 AND identity_id=$3`, [s.deviceId, s.accountId, s.identityId]))[0]) fail(409, 'group_credential_unavailable');
      const prior = (yield q(`SELECT status,invite_hash FROM mls_group_join_requests WHERE group_id=$1 AND device_id=$2`, [state.id, s.deviceId]))[0];
      if (prior?.status === 'joined') fail(409, 'group_rejoin_requires_new_device');
      if (prior?.invite_hash === invite.token_hash) return { groupId: state.id, status: prior.status };
      const count = (yield q(`SELECT COUNT(*) AS count FROM mls_group_join_requests r JOIN mls_group_invites i ON i.token_hash=r.invite_hash JOIN devices d ON d.id=r.device_id WHERE r.group_id=$1 AND r.status IN ('pending','approved') AND i.revoked=0 AND i.expires_at>$2 AND d.revoked_at IS NULL`, [state.id, new Date().toISOString()]))[0];
      if (Number(count.count) >= 256) fail(429, 'group_join_queue_full');
      const status = invite.mode === 'open' ? 'approved' : 'pending';
      yield q(`INSERT INTO mls_group_join_requests VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(group_id,device_id) DO UPDATE SET invite_hash=excluded.invite_hash,status=excluded.status,created_at=excluded.created_at`, [state.id, s.deviceId, s.accountId, s.identityId, invite.token_hash, status, new Date().toISOString()]);
      return { groupId: state.id, status };
    });
  }
  async joinRequests(s: SessionInfo, groupId: string) {
    return this.run(function* (q) {
      yield* this.active(q, s); const state = yield* this.state(q, groupId); this.admin(state, s);
      const rows = yield q(`SELECT r.device_id,r.status,c.payload_json FROM mls_group_join_requests r JOIN mls_group_invites i ON i.token_hash=r.invite_hash JOIN mls_credentials c ON c.device_id=r.device_id JOIN devices d ON d.id=r.device_id WHERE r.group_id=$1 AND r.status IN ('pending','approved') AND i.revoked=0 AND i.expires_at>$2 AND d.revoked_at IS NULL ORDER BY r.created_at LIMIT 256`, [groupId, new Date().toISOString()]);
      return { requests: rows.map(r => ({ status: r.status, member: JSON.parse(String(r.payload_json)) })) };
    });
  }
  async decideJoin(s: SessionInfo, groupId: string, deviceId: string, approve: boolean) {
    return this.run(function* (q) {
      yield* this.active(q, s); const state = yield* this.state(q, groupId); this.admin(state, s);
      const row = (yield q(`SELECT r.status FROM mls_group_join_requests r JOIN mls_group_invites i ON i.token_hash=r.invite_hash WHERE r.group_id=$1 AND r.device_id=$2 AND i.revoked=0 AND i.expires_at>$3`, [groupId, id(deviceId), new Date().toISOString()]))[0];
      if (!row || !['pending','approved'].includes(String(row.status))) fail(404, 'group_join_request_unavailable');
      const status = approve ? 'approved' : 'rejected';
      yield q(`UPDATE mls_group_join_requests SET status=$1 WHERE group_id=$2 AND device_id=$3`, [status, groupId, deviceId]);
      return { groupId, status };
    });
  }
  async packageStock(s: SessionInfo): Promise<{ available: number }> {
    return this.run(function* (q) {
      yield* this.active(q, s);
      const now = new Date().toISOString();
      const rows = yield q(`SELECT COUNT(*) AS count FROM mls_packages WHERE device_id=$1 AND account_id=$2 AND consumed=0 AND expires_at>$3 AND (claim_id IS NULL OR claim_expires_at<=$4)`, [s.deviceId, s.accountId, now, now]);
      return { available: Number(rows[0].count) };
    });
  }
  /** Operator metadata only: no credentials, key packages or ciphertext leave these methods. */
  async diagnostics() {
    return this.run(function* (q) {
      const now = new Date().toISOString();
      const groups = yield q(`SELECT COUNT(*) AS count FROM mls_groups`);
      const paused = yield q(`SELECT COUNT(*) AS count FROM mls_group_policy WHERE paused=1`);
      const inbox = yield q(`SELECT COUNT(*) AS count FROM mls_inbox`);
      const available = yield q(`SELECT COUNT(*) AS count FROM mls_packages p JOIN devices d ON d.id=p.device_id AND d.account_id=p.account_id WHERE d.revoked_at IS NULL AND p.consumed=0 AND p.expires_at>$1 AND (p.claim_id IS NULL OR p.claim_expires_at<=$2)`, [now, now]);
      return { infrastructureReady: true, messagingReady: true, clientIntegrationReady: true,
        protocol: GROUP_PROTOCOL, scope: 'home-node', groupCount: Number(groups[0].count),
        pausedGroups: Number(paused[0].count), inboxRecords: Number(inbox[0].count), availableKeyPackages: Number(available[0].count) };
    });
  }
  private *policy(q: Query, groupId: string): Work<{ paused: boolean; policyRevision: number }> {
    const rows = yield q(`SELECT paused,revision FROM mls_group_policy WHERE group_id=$1`, [groupId]);
    return { paused: rows.length > 0 && Number(rows[0].paused) === 1, policyRevision: rows.length ? Number(rows[0].revision) : 0 };
  }
  private *summary(q: Query, state: GroupState) {
    const policy = yield* this.policy(q, state.id);
    const inbox = yield q(`SELECT COUNT(*) AS count FROM mls_inbox WHERE group_id=$1`, [state.id]);
    return { id: state.id, title: state.title, epoch: state.epoch, revision: state.revision, sequence: state.sequence,
      deviceCount: state.members.length, accountCount: new Set(state.members.map(m => m.accountId)).size,
      inboxRecords: Number(inbox[0].count), ...policy };
  }
  async adminList(limit = 50, after = '') {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) fail(400, 'invalid_group_limit');
    if (after) id(after);
    return this.run(function* (q) {
      const rows = yield q(`SELECT state_json FROM mls_groups WHERE id>$1 ORDER BY id LIMIT $2`, [after, limit + 1]);
      const groups = [];
      for (const row of rows.slice(0, limit)) groups.push(yield* this.summary(q, JSON.parse(String(row.state_json)) as GroupState));
      return { protocol: GROUP_PROTOCOL, groups, nextAfter: rows.length > limit ? groups[groups.length - 1].id : '' };
    });
  }
  async adminGet(groupId: string) {
    id(groupId);
    return this.run(function* (q) {
      const state = yield* this.state(q, groupId);
      const members = [];
      for (const member of state.members) {
        const device = yield q(`SELECT revoked_at FROM devices WHERE id=$1 AND account_id=$2`, [member.deviceId, member.accountId]);
        members.push({ accountId: member.accountId, deviceId: member.deviceId, identityId: member.identityId,
          role: member.role, active: device.length > 0 && device[0].revoked_at == null });
      }
      return { ...yield* this.summary(q, state), members };
    });
  }
  async adminSetPolicy(groupId: string, value: unknown) {
    id(groupId); const v = object(value);
    if (typeof v.paused !== 'boolean') fail(400, 'invalid_group_policy');
    const paused = v.paused, expected = integer(v.expectedPolicyRevision);
    return this.run(function* (q) {
      // Same row lock/order as send: a pause and a new message cannot race.
      const state = yield* this.state(q, groupId);
      const policy = yield* this.policy(q, groupId);
      if (policy.policyRevision !== expected) fail(409, 'group_policy_conflict');
      yield q(`INSERT INTO mls_group_policy(group_id,paused,revision) VALUES($1,$2,$3) ON CONFLICT(group_id) DO UPDATE SET paused=excluded.paused,revision=excluded.revision`, [groupId, paused ? 1 : 0, expected + 1]);
      return yield* this.summary(q, state);
    });
  }
  async adminCleanupPackages() {
    return this.run(function* (q) {
      const now = new Date().toISOString();
      // Preserve consumed tombstones, live reservations and all inbox/operation history.
      const removed = yield q(`DELETE FROM mls_packages WHERE id IN (SELECT id FROM mls_packages WHERE consumed=0 AND expires_at<=$1 AND (claim_id IS NULL OR claim_expires_at<=$2) ORDER BY expires_at,id LIMIT 1000) RETURNING id`, [now, now]);
      return { removed: removed.length, limit: 1000 };
    });
  }
  private transaction<T>(fn: (this: GroupStore, query: Query) => Work<T>): Promise<T> {
    const q: Query = (sql, values = []) => ({ sql, values });
    if (this.sqlite) {
      // Drive the generator synchronously: no await while the shared SQLite
      // connection holds a transaction, so unrelated requests cannot interleave.
      try {
        this.sqlite.exec('BEGIN IMMEDIATE');
        const work = fn.call(this, q);
        let step = work.next();
        while (!step.done) {
          const { sql, values } = step.value;
          const rows = this.sqlite.prepare(sql.replace(/\$\d+/g, '?')).all(...values as (string | number | null)[]) as Row[];
          step = work.next(rows);
        }
        this.sqlite.exec('COMMIT'); return Promise.resolve(step.value);
      } catch (error) { this.sqlite.exec('ROLLBACK'); return Promise.reject(error); }
    }
    return (async () => {
      const client = await this.pool!.connect();
      try {
        await client.query('BEGIN'); const work = fn.call(this, q); let step = work.next();
        while (!step.done) { const result = await client.query(step.value.sql, step.value.values); step = work.next(result.rows); }
        await client.query('COMMIT'); return step.value;
      } catch (error) { await client.query('ROLLBACK');
        if (['40001','40P01'].includes(String((error as {code?: string}).code))) fail(409,'group_busy');
        throw error; }
      finally { client.release(); }
    })();
  }
  private async run<T>(fn: (this: GroupStore, q: Query) => Work<T>): Promise<T> { await this.ready; return this.transaction(fn); }
  private *active(q: Query, s: Pick<SessionInfo, 'accountId' | 'deviceId'>, lock: 'SHARE' | 'UPDATE' = 'SHARE') {
    if (!(yield q(`SELECT id FROM devices WHERE id=$1 AND account_id=$2 AND revoked_at IS NULL${this.pool ? ' FOR ' + lock : ''}`, [s.deviceId, s.accountId]))[0]) fail(403, 'group_device_revoked');
  }
  private *state(q: Query, groupId: string): Work<GroupState> {
    const row = (yield q(`SELECT state_json FROM mls_groups WHERE id=$1${this.pool ? ' FOR UPDATE' : ''}`, [id(groupId)]))[0];
    if (!row) fail(404, 'group_not_found');
    return JSON.parse(String(row.state_json));
  }
  private member(state: GroupState, s: SessionInfo): GroupMember {
    const member = state.members.find(m => m.accountId === s.accountId && m.deviceId === s.deviceId);
    if (!member) fail(403, 'group_not_member');
    return member;
  }
  private *replay(q: Query, groupId: string, s: SessionInfo, operationId: string, hash: string): Work<Row | null> {
    const row = (yield q(`SELECT request_hash,result_json FROM mls_operations WHERE group_id=$1 AND device_id=$2 AND operation_id=$3`, [groupId, s.deviceId, operationId]))[0];
    if (!row) return null;
    if (row.request_hash !== hash) fail(409, 'group_operation_conflict');
    return JSON.parse(String(row.result_json));
  }
  private *remember(q: Query, groupId: string, s: SessionInfo, op: string, hash: string, result: unknown) {
    yield q(`INSERT INTO mls_operations VALUES($1,$2,$3,$4,$5)`, [groupId, s.deviceId, op, hash, JSON.stringify(result)]);
  }
  async publishCredential(s: SessionInfo, value: unknown, signingPublicKey: string) {
    const v = object(value);
    const member: GroupMember = { accountId: s.accountId, deviceId: s.deviceId, identityId: s.identityId, role: 'member', mlsSignatureKey: bytes(v.mlsSignatureKey,32), mlsSignature: bytes(v.mlsSignature,64) };
    if (v.deviceId !== s.deviceId || v.identityId !== s.identityId || Buffer.from(member.mlsSignatureKey,'base64').length !== 32 || !verifyRawEd25519(mlsDeviceBinding(member),member.mlsSignature,signingPublicKey)) fail(400,'invalid_group_credential');
    return this.run(function* (q) {
      yield* this.active(q,s,'UPDATE');
      const row=(yield q(`SELECT signature_key FROM mls_credentials WHERE device_id=$1`,[s.deviceId]))[0];
      if(row && row.signature_key !== member.mlsSignatureKey) fail(409,'group_credential_change_requires_new_device');
      yield q(`INSERT INTO mls_credentials VALUES($1,$2,$3,$4,$5) ON CONFLICT(device_id) DO NOTHING`,[s.deviceId,s.accountId,s.identityId,member.mlsSignatureKey,JSON.stringify(member)]);
      return member;
    });
  }
  async credential(s: SessionInfo,deviceId: string) {
    return this.run(function* (q) {
      yield* this.active(q,s);
      const row=(yield q(`SELECT c.payload_json FROM mls_credentials c JOIN devices d ON d.id=c.device_id WHERE c.device_id=$1 AND d.revoked_at IS NULL`,[id(deviceId)]))[0];
      if(!row) fail(404,'group_credential_unavailable');
      return JSON.parse(String(row.payload_json)) as GroupMember;
    });
  }
  async publish(s: SessionInfo, value: unknown, signingPublicKey: string) {
    const v = object(value);
    const p: PackageInput = { id: id(v.id), serialized: bytes(v.serialized, 65536), expiresAt: String(v.expiresAt), signature: bytes(v.signature, 64) };
    const expiry = Date.parse(p.expiresAt);
    if (!Number.isFinite(expiry) || new Date(expiry).toISOString() !== p.expiresAt || expiry <= Date.now() || expiry > Date.now() + 30 * 86400000) fail(400, 'invalid_key_package_expiry');
    if (!verifyRawEd25519(keyPackageBinding(s, p), p.signature, signingPublicKey)) fail(400, 'invalid_key_package_binding');
    return this.run(function* (q) {
      yield* this.active(q, s, 'UPDATE');
      const prior = (yield q(`SELECT payload_json FROM mls_packages WHERE id=$1`, [p.id]))[0];
      const payload = JSON.stringify({ ...p, identityId: s.identityId, deviceId: s.deviceId, accountId: s.accountId });
      if (prior) { if (prior.payload_json !== payload) fail(409, 'key_package_conflict'); return { id: p.id }; }
      const count = (yield q(`SELECT COUNT(*) AS n FROM mls_packages WHERE device_id=$1 AND consumed=0 AND expires_at>$2`, [s.deviceId, new Date().toISOString()]))[0];
      if (Number(count.n) >= 64) fail(409, 'key_package_limit');
      yield q(`INSERT INTO mls_packages(id,device_id,account_id,payload_json,expires_at) VALUES($1,$2,$3,$4,$5)`, [p.id, s.deviceId, s.accountId, payload, p.expiresAt]);
      return { id: p.id };
    });
  }
  async claim(s: SessionInfo, deviceId: string) {
    return this.run(function* (q) {
      yield* this.active(q, s); id(deviceId);
      const now = new Date().toISOString();
      // Lock target device so two workers cannot reserve the same key package.
      const target = (yield q(`SELECT id FROM devices WHERE id=$1 AND revoked_at IS NULL${this.pool ? ' FOR UPDATE' : ''}`, [deviceId]))[0];
      if (!target) fail(404, 'device_not_found');
      const row = (yield q(`SELECT id,payload_json FROM mls_packages WHERE device_id=$1 AND consumed=0 AND expires_at>$2 AND (claim_id IS NULL OR claim_expires_at<$3) ORDER BY expires_at LIMIT 1`, [deviceId, now, now]))[0];
      if (!row) fail(409, 'key_package_unavailable');
      const claimId = randomUUID();
      yield q(`UPDATE mls_packages SET claim_id=$1,claimed_by=$2,claim_expires_at=$3 WHERE id=$4`, [claimId, s.deviceId, new Date(Date.now() + 600000).toISOString(), row.id]);
      return { ...JSON.parse(String(row.payload_json)), claimId };
    });
  }
  private *consume(q: Query, s: SessionInfo, next: Change, added: GroupMember[]) {
    if (Object.keys(next.claims).length !== added.length || Object.keys(next.welcomes).length !== added.length) fail(400, 'group_welcome_mismatch');
    for (const m of next.members) {
      yield* this.active(q, m);
      const record = (yield q(`SELECT identity_id,signing_public_key FROM device_key_bundles WHERE account_id=$1 AND device_id=$2`, [m.accountId,m.deviceId]))[0];
      if (!record || record.identity_id !== m.identityId || !verifyRawEd25519(mlsDeviceBinding(m), m.mlsSignature, String(record.signing_public_key))) fail(400, 'invalid_group_credential');
    }
    for (const m of added) {
      const claimId = next.claims[m.deviceId];
      if (!claimId || !next.welcomes[m.deviceId]) fail(400, 'group_welcome_mismatch');
      const row = (yield q(`SELECT id FROM mls_packages WHERE device_id=$1 AND account_id=$2 AND claim_id=$3 AND claimed_by=$4 AND consumed=0 AND claim_expires_at>$5 AND expires_at>$6${this.pool ? ' FOR UPDATE' : ''}`, [m.deviceId, m.accountId, claimId, s.deviceId, new Date().toISOString(), new Date().toISOString()]))[0];
      if (!row) fail(409, 'key_package_claim_expired');
      yield q(`UPDATE mls_packages SET consumed=1 WHERE id=$1`, [row.id]);
    }
  }
  private *deliver(q: Query, state: GroupState, recipients: GroupMember[], event: Row) {
    for (const m of recipients) yield q(`INSERT INTO mls_inbox VALUES($1,$2,$3,$4)`, [m.deviceId, state.id, state.sequence, JSON.stringify({ ...event, groupId: state.id, sequence: state.sequence })]);
  }
  async create(s: SessionInfo, groupId: string, value: unknown) {
    const next = change(value); id(groupId);
    if (next.epoch !== 1 || !next.members.some(m => m.accountId === s.accountId && m.deviceId === s.deviceId && m.role === 'owner')) fail(400, 'invalid_initial_group');
    return this.run(function* (q) {
      yield* this.active(q, s);
      // Serialize creation and idempotent retries across PostgreSQL workers.
      if (this.pool) yield q(`SELECT pg_advisory_xact_lock(hashtext($1))`, [groupId]);
      const hash = digest(next);
      const prior = yield* this.replay(q, groupId, s, next.operationId, hash); if (prior) return prior;
      if ((yield q(`SELECT id FROM mls_groups WHERE id=$1`, [groupId]))[0]) fail(409, 'group_exists');
      const added = next.members.filter(m => m.deviceId !== s.deviceId);
      yield* this.consume(q, s, next, added);
      const state: GroupState = { id: groupId, title: next.title, epoch: 1, revision: 1, sequence: 1, members: next.members };
      yield q(`INSERT INTO mls_groups VALUES($1,$2)`, [groupId, JSON.stringify(state)]);
      yield q(`INSERT INTO conversations(id,kind,title,created_at) VALUES($1,'group',$2,$3)`, [groupId, state.title, new Date().toISOString()]);
      for (const accountId of new Set(state.members.map(m => m.accountId))) yield q(`INSERT INTO conversation_members VALUES($1,$2)`, [groupId, accountId]);
      for (const member of added) yield* this.deliver(q, state, [member], { kind: 'welcome', welcome: next.welcomes[member.deviceId], state });
      yield* this.remember(q, groupId, s, next.operationId, hash, state);
      return state;
    });
  }
  async commit(s: SessionInfo, groupId: string, expectedRevision: number, value: unknown) {
    const next = change(value); integer(expectedRevision);
    return this.run(function* (q) {
      yield* this.active(q, s);
      const state = yield* this.state(q, groupId);
      const hash = digest({ expectedRevision, next });
      const prior = yield* this.replay(q, groupId, s, next.operationId, hash); if (prior) return prior;
      const actor = this.member(state, s);
      if (state.revision !== expectedRevision || next.epoch !== state.epoch + 1) fail(409, 'group_epoch_conflict');
      for (const m of next.members) {
        const old = state.members.find(o => o.deviceId === m.deviceId);
        if (old && (old.accountId !== m.accountId || old.identityId !== m.identityId || old.mlsSignatureKey !== m.mlsSignatureKey || old.mlsSignature !== m.mlsSignature)) fail(409, 'group_credential_change_requires_remove');
      }
      const added = next.members.filter(m => !state.members.some(old => old.deviceId === m.deviceId));
      const removed = state.members.filter(m => !next.members.some(n => n.deviceId === m.deviceId));
      const ownLeave = added.length === 0 && removed.length > 0 && removed.every(m => m.accountId === s.accountId) && next.title === state.title && next.members.every(m => state.members.some(old => JSON.stringify(old) === JSON.stringify(m)));
      if (actor.role === 'member' && !ownLeave) fail(403, 'group_admin_required');
      if (actor.role !== 'owner' && !ownLeave && (removed.some(m => m.role !== 'member') || next.members.some(m => { const old = state.members.find(o => o.deviceId === m.deviceId); return old ? old.role !== m.role : m.role !== 'member'; }))) fail(403, 'group_owner_required');
      if (next.joinRequestDeviceId) {
        if (added.length !== 1 || added[0].deviceId !== next.joinRequestDeviceId || removed.length || next.title !== state.title || next.members.some(m => { const old = state.members.find(o => o.deviceId === m.deviceId); return old ? JSON.stringify(old) !== JSON.stringify(m) : m.role !== (state.members.find(o => o.accountId === m.accountId)?.role ?? 'member'); })) fail(400, 'invalid_group_join_commit');
        const approved = (yield q(`SELECT r.device_id FROM mls_group_join_requests r JOIN mls_group_invites i ON i.token_hash=r.invite_hash WHERE r.group_id=$1 AND r.device_id=$2 AND r.status='approved' AND i.revoked=0 AND i.expires_at>$3`, [groupId, next.joinRequestDeviceId, new Date().toISOString()]))[0];
        if (!approved) fail(409, 'group_join_request_unavailable');
      }
      yield* this.consume(q, s, next, added);
      const updated: GroupState = { ...state, title: next.title, members: next.members, epoch: next.epoch, revision: state.revision + 1, sequence: state.sequence + 1 };
      yield q(`UPDATE mls_groups SET state_json=$1 WHERE id=$2`, [JSON.stringify(updated), groupId]);
      yield q(`UPDATE conversations SET title=$1 WHERE id=$2`, [next.title, groupId]);
      yield q(`DELETE FROM conversation_members WHERE conversation_id=$1`, [groupId]);
      for (const accountId of new Set(updated.members.map(m => m.accountId))) yield q(`INSERT INTO conversation_members VALUES($1,$2)`, [groupId, accountId]);
      yield* this.deliver(q, updated, state.members, { kind: 'commit', senderDeviceId: s.deviceId, commit: next.commit, state: updated });
      for (const m of added) yield* this.deliver(q, updated, [m], { kind: 'welcome', welcome: next.welcomes[m.deviceId], state: updated });
      for (const m of added) yield q(`UPDATE mls_group_join_requests SET status='joined' WHERE group_id=$1 AND device_id=$2`, [groupId, m.deviceId]);
      yield* this.remember(q, groupId, s, next.operationId, hash, updated);
      return updated;
    });
  }
  async send(s: SessionInfo, groupId: string, value: unknown) {
    const v = object(value); const operationId = id(v.operationId), epoch = integer(v.epoch), ciphertext = bytes(v.ciphertext);
    return this.run(function* (q) {
      yield* this.active(q, s); const state = yield* this.state(q, groupId);
      const hash = digest({ operationId, epoch, ciphertext });
      const prior = yield* this.replay(q, groupId, s, operationId, hash); if (prior) return prior;
      this.member(state, s);
      if ((yield* this.policy(q, groupId)).paused) fail(423, 'group_paused');
      if (state.epoch !== epoch) fail(409, 'group_epoch_conflict');
      for (const member of state.members) yield* this.active(q, member);
      state.sequence++;
      const event = { kind: 'message', operationId, epoch, ciphertext, senderDeviceId: s.deviceId, senderAccountId: s.accountId, createdAt: new Date().toISOString() };
      yield* this.deliver(q, state, state.members, event);
      yield q(`UPDATE mls_groups SET state_json=$1 WHERE id=$2`, [JSON.stringify(state), groupId]);
      const receipt = { groupId, operationId, sequence: state.sequence, epoch };
      yield* this.remember(q, groupId, s, operationId, hash, receipt);
      return receipt;
    });
  }
  async get(s: SessionInfo, groupId: string) {
    return this.run(function* (q) { yield* this.active(q, s); const state = yield* this.state(q, groupId); this.member(state, s); return state; });
  }
  async inbox(s: SessionInfo, groupId: string, after: number) {
    integer(after);
    return this.run(function* (q) {
      yield* this.active(q, s); id(groupId);
      // Removed members may read only their previously addressed ciphertext and removal commit.
      const rows = yield q(`SELECT event_json FROM mls_inbox WHERE device_id=$1 AND group_id=$2 AND sequence>$3 ORDER BY sequence LIMIT 100`, [s.deviceId, groupId, after]);
      const events: Row[] = []; let size = 0;
      for (const row of rows) {
        const payload = String(row.event_json);
        if (size + Buffer.byteLength(payload) > 4 * 1024 * 1024) break;
        size += Buffer.byteLength(payload); events.push(JSON.parse(payload));
      }
      return { events, hasMore: events.length < rows.length || rows.length === 100 };
    });
  }
  async list(s: SessionInfo) {
    return this.run(function* (q) {
      yield* this.active(q, s);
      const rows = yield q(`SELECT DISTINCT group_id FROM mls_inbox WHERE device_id=$1`, [s.deviceId]);
      // Owners can have no inbox before the first message.
      const owned = yield q(`SELECT c.id AS group_id FROM conversations c JOIN conversation_members m ON m.conversation_id=c.id WHERE m.account_id=$1 AND c.kind='group'`, [s.accountId]);
      return { groupIds: [...new Set([...rows, ...owned].map(r => String(r.group_id)))] };
    });
  }
}
