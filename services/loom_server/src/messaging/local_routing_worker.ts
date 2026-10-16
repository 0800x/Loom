import type { SqliteStore } from '../storage/sqlite_store.ts';
import type { PostgresStore } from '../storage/postgres_store.ts';
import type { FederationService } from '../federation/service.ts';

/** Acceptance is a database transaction. DNS/discovery/routing runs afterwards
 * from a durable intent and survives a process restart or peer outage. */
export class LocalRoutingWorker {
  private timer?: NodeJS.Timeout;
  private readonly active = new Map<string, Promise<void>>();
  private stopped = true;
  private pumping = false;
  private requested = false;
  private lastError: string | null = null;
  private readonly store: SqliteStore | PostgresStore;
  private readonly federation: Pick<FederationService, 'routeLocalMessage'>;
  private readonly domain: string;
  private readonly committed: () => void;

  constructor(store: SqliteStore | PostgresStore,
      federation: Pick<FederationService, 'routeLocalMessage'>, domain: string, committed: () => void) {
    this.store = store; this.federation = federation; this.domain = domain; this.committed = committed;
  }
  start() {
    if (!this.stopped) return;
    this.stopped = false;
    this.timer = setInterval(() => this.kick(), 1000);
    this.timer.unref();
    this.kick();
  }
  async stop() {
    this.stopped = true;
    clearInterval(this.timer);
    await Promise.allSettled([...this.active.values()]);
  }
  diagnostics() { return { inFlight: this.active.size, lastError: this.lastError }; }
  kick() {
    if (this.stopped) return;
    this.requested = true;
    if (!this.pumping) void this.pump().catch(error => {
      this.lastError = error instanceof Error ? error.message.slice(0,160) : 'routing_store_failed';
    });
  }
  private async pump() {
    this.pumping = true;
    try {
      while (this.requested && !this.stopped) {
        this.requested = false;
        const capacity = 4 - this.active.size;
        if (capacity <= 0) break;
        const jobs = await this.store.pendingMessageRoutes(capacity, [...this.active.keys()]);
        if (this.stopped) break;
        for (const row of jobs) {
          const conversationId = String(row.conversation_id);
          if (this.active.has(conversationId)) continue;
          const task = this.route(row).catch(error => {
            this.lastError = error instanceof Error ? error.message.slice(0,160) : 'routing_store_failed';
          }).finally(() => { this.active.delete(conversationId); this.kick(); });
          this.active.set(conversationId, task);
        }
      }
    } finally { this.pumping = false; }
  }
  private async route(row: Record<string, unknown>) {
    const id = String(row.id);
    try {
      const createdAt = row.created_at instanceof Date
        ? row.created_at.toISOString() : new Date(String(row.created_at)).toISOString();
      await this.federation.routeLocalMessage({
        conversationId: String(row.conversation_id),
        senderAddress: `@${row.username}:${this.domain}`,
        receipt: { messageId: id, clientId: row.client_id, serverOrder: Number(row.server_order),
          createdAt },
        message: { messageId: id, clientId: String(row.client_id), type: String(row.type),
          ciphertext: String(row.ciphertext), protocolVersion: String(row.protocol_version),
          replyToMessageId: row.reply_to_message_id == null ? null : String(row.reply_to_message_id),
          metadata: typeof row.metadata_json === 'string' ? JSON.parse(row.metadata_json) : row.metadata_json,
          createdAt },
      });
      await this.store.completeMessageRoute(id);
      this.lastError = null;
      this.committed();
    } catch (error) {
      const reason = error instanceof Error ? error.message.slice(0,160) : 'routing_failed';
      const attempt = Number(row.attempts) + 1;
      await this.store.retryMessageRoute(id, attempt,
        new Date(Date.now() + Math.min(300, 2 ** Math.min(attempt, 8)) * 1000).toISOString(), reason);
      this.lastError = reason;
    }
  }
}
