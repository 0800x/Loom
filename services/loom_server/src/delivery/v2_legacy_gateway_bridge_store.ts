import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

type QueryResult = {
  rows: Array<Record<string, unknown>>;
  rowCount: number | null;
};
type PgPool = {
  query(sql: string, values?: unknown[]): Promise<QueryResult>;
  end(): Promise<void>;
};

export interface V2LegacyGatewayDelivery {
  deliveryId: string;
  event: {
    eventId: string;
    kind: 'message.created';
    order: number;
    payload: Record<string, unknown>;
  };
  conversation: {
    id: string;
    kind: string;
    title: string | null;
    peerAddress: string | null;
    updatedOrder: number;
    unreadCount: number;
    isMuted: false;
    isPinned: false;
  };
}

export class V2LegacyGatewayBridgeStore {
  private readonly sqlite?: DatabaseSync;
  private readonly pool?: PgPool;

  private constructor(sqlite?: DatabaseSync, pool?: PgPool) {
    this.sqlite = sqlite;
    this.pool = pool;
  }

  static sqliteStore(dataDirectory: string): V2LegacyGatewayBridgeStore {
    const path = resolve(dataDirectory, 'loom.sqlite3');
    mkdirSync(dirname(path), { recursive: true });
    const db = new DatabaseSync(path);
    db.exec(
      'PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;',
    );
    return new V2LegacyGatewayBridgeStore(db);
  }

  static async postgresStore(databaseUrl: string): Promise<V2LegacyGatewayBridgeStore> {
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
    return new V2LegacyGatewayBridgeStore(undefined, pool);
  }

  async close(): Promise<void> {
    if (this.sqlite) this.sqlite.close();
    if (this.pool) await this.pool.end();
  }

  async claimRecentMessages(
    recipientDeviceId: string,
    leaseId: string,
    limit: number,
    maxBytes: number,
  ): Promise<V2LegacyGatewayDelivery[]> {
    if (limit < 1 || limit > 50) return [];
    const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60_000).toISOString();
    let accountId: string | null = null;
    let rows: Array<Record<string, unknown>> = [];

    if (this.sqlite) {
      const device = this.sqlite.prepare(`
        SELECT account_id FROM devices
        WHERE id=? AND revoked_at IS NULL
      `).get(recipientDeviceId) as Record<string, unknown> | undefined;
      accountId = device ? String(device.account_id) : null;
      if (!accountId) return [];
      rows = this.sqlite.prepare(`
        SELECT e.event_id,e.kind,e.event_order,e.payload_json,e.created_at
        FROM events e
        WHERE e.account_id=? AND e.kind='message.created' AND e.created_at>?
          AND NOT EXISTS (
            SELECT 1 FROM v2_proximity_gateway_custody c
            WHERE c.lease_id=? AND c.packet_id=('legacy:' || e.event_id)
          )
        ORDER BY e.event_order DESC
        LIMIT ?
      `).all(accountId, cutoff, leaseId, Math.min(100, limit * 4)) as
        Array<Record<string, unknown>>;
    } else {
      const device = (await this.pool!.query(`
        SELECT account_id FROM devices
        WHERE id=$1 AND revoked_at IS NULL
      `, [recipientDeviceId])).rows[0];
      accountId = device ? String(device.account_id) : null;
      if (!accountId) return [];
      rows = (await this.pool!.query(`
        SELECT e.event_id,e.kind,e.event_order,e.payload_json,e.created_at
        FROM events e
        WHERE e.account_id=$1 AND e.kind='message.created' AND e.created_at>$2
          AND NOT EXISTS (
            SELECT 1 FROM v2_proximity_gateway_custody c
            WHERE c.lease_id=$3 AND c.packet_id=('legacy:' || e.event_id)
          )
        ORDER BY e.event_order DESC
        LIMIT $4
      `, [accountId, cutoff, leaseId, Math.min(100, limit * 4)])).rows;
    }

    const selected: V2LegacyGatewayDelivery[] = [];
    let totalBytes = 0;
    for (const row of rows.reverse()) {
      let payload: Record<string, unknown>;
      try {
        const raw = typeof row.payload_json === 'string'
          ? JSON.parse(String(row.payload_json))
          : row.payload_json;
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
        payload = raw as Record<string, unknown>;
      } catch {
        continue;
      }
      const conversationId = payload.conversationId;
      if (typeof conversationId !== 'string' || !conversationId) continue;

      let conversation: Record<string, unknown> | undefined;
      if (this.sqlite) {
        conversation = this.sqlite.prepare(`
          SELECT id,kind,title,peer_address FROM conversations WHERE id=?
        `).get(conversationId) as Record<string, unknown> | undefined;
      } else {
        conversation = (await this.pool!.query(`
          SELECT id,kind,title,peer_address FROM conversations WHERE id=$1
        `, [conversationId])).rows[0];
      }
      if (!conversation) continue;

      const delivery: V2LegacyGatewayDelivery = {
        deliveryId: `legacy:${String(row.event_id)}`,
        event: {
          eventId: String(row.event_id),
          kind: 'message.created',
          order: Number(row.event_order),
          payload,
        },
        conversation: {
          id: String(conversation.id),
          kind: String(conversation.kind),
          title: conversation.title == null ? null : String(conversation.title),
          peerAddress: conversation.peer_address == null
            ? null
            : String(conversation.peer_address),
          updatedOrder: Number(payload.serverOrder ?? row.event_order),
          unreadCount: 1,
          isMuted: false,
          isPinned: false,
        },
      };
      const bytes = Buffer.byteLength(JSON.stringify(delivery), 'utf8');
      if (bytes > 240 * 1024) continue;
      if (totalBytes + bytes > maxBytes) break;
      totalBytes += bytes;
      selected.push(delivery);
      if (selected.length >= limit) break;
    }
    return selected;
  }

  /// Emits a sender-side delivered event only for legacy messages that were
  /// explicitly ACKed by the recipient over the encrypted Nearby link.
  ///
  /// The caller has already verified the recipient device signature over each
  /// delivery id and its active lease before this method is reached.
  async emitRecipientDeliveredReceipts(deliveryIds: unknown): Promise<number> {
    if (!Array.isArray(deliveryIds) || deliveryIds.length > 50) return 0;
    const legacyIds = [...new Set(deliveryIds)]
      .filter((value): value is string =>
        typeof value === 'string' && value.startsWith('legacy:') && value.length <= 256)
      .map((value) => value.slice('legacy:'.length));
    let emitted = 0;
    for (const recipientEventId of legacyIds) {
      let recipientEvent: Record<string, unknown> | undefined;
      if (this.sqlite) {
        recipientEvent = this.sqlite.prepare(`
          SELECT payload_json FROM events
          WHERE event_id=? AND kind='message.created'
        `).get(recipientEventId) as Record<string, unknown> | undefined;
      } else {
        recipientEvent = (await this.pool!.query(`
          SELECT payload_json FROM events
          WHERE event_id=$1 AND kind='message.created'
        `, [recipientEventId])).rows[0];
      }
      if (!recipientEvent) continue;

      let payload: Record<string, unknown>;
      try {
        const raw = typeof recipientEvent.payload_json === 'string'
          ? JSON.parse(String(recipientEvent.payload_json))
          : recipientEvent.payload_json;
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
        payload = raw as Record<string, unknown>;
      } catch {
        continue;
      }
      const messageId = payload.id;
      const clientId = payload.clientId;
      if (typeof messageId !== 'string' || typeof clientId !== 'string') continue;

      let message: Record<string, unknown> | undefined;
      if (this.sqlite) {
        message = this.sqlite.prepare(`
          SELECT sender_account_id FROM messages WHERE id=?
        `).get(messageId) as Record<string, unknown> | undefined;
      } else {
        message = (await this.pool!.query(`
          SELECT sender_account_id FROM messages WHERE id=$1
        `, [messageId])).rows[0];
      }
      if (!message) continue;
      const senderAccountId = String(message.sender_account_id);
      const deliveryEventId = `nearby-delivered:${messageId}`;
      const deliveredPayload = JSON.stringify({ clientId, messageId });
      const createdAt = new Date().toISOString();

      if (this.sqlite) {
        const exists = this.sqlite.prepare(
          `SELECT 1 FROM events WHERE event_id=?`,
        ).get(deliveryEventId);
        if (exists) continue;
        const orderRow = this.sqlite.prepare(`
          SELECT COALESCE(MAX(event_order),0)+1 next_order
          FROM events WHERE account_id=?
        `).get(senderAccountId) as Record<string, unknown>;
        this.sqlite.prepare(`
          INSERT OR IGNORE INTO events(
            event_id,account_id,kind,event_order,payload_json,created_at
          ) VALUES(?,?,?,?,?,?)
        `).run(
          deliveryEventId,
          senderAccountId,
          'message.delivered',
          Number(orderRow.next_order),
          deliveredPayload,
          createdAt,
        );
        const inserted = this.sqlite.prepare(
          `SELECT 1 FROM events WHERE event_id=?`,
        ).get(deliveryEventId);
        if (inserted) emitted++;
      } else {
        const exists = (await this.pool!.query(
          `SELECT 1 FROM events WHERE event_id=$1`,
          [deliveryEventId],
        )).rows[0];
        if (exists) continue;
        const orderRow = (await this.pool!.query(`
          SELECT COALESCE(MAX(event_order),0)+1 next_order
          FROM events WHERE account_id=$1
        `, [senderAccountId])).rows[0];
        if (!orderRow) continue;
        const result = await this.pool!.query(`
          INSERT INTO events(
            event_id,account_id,kind,event_order,payload_json,created_at
          ) VALUES($1,$2,'message.delivered',$3,$4::jsonb,$5)
          ON CONFLICT(event_id) DO NOTHING
        `, [
          deliveryEventId,
          senderAccountId,
          Number(orderRow.next_order),
          deliveredPayload,
          createdAt,
        ]);
        if (result.rowCount === 1) emitted++;
      }
    }
    return emitted;
  }
}
