import type { WebSocket } from 'ws';

type SyncPage = { events: Array<Record<string, unknown>>; nextCursor: string; hasMore: boolean };
type SyncReader = (accountId: string, cursor: string | null, limit: number) => Promise<SyncPage>;
type Connection = { socket: WebSocket; accountId: string; cursor: string | null; flushing: boolean; again: boolean; alive: boolean };

/** Authenticated account events; durable REST cursors remain the recovery source. */
export class LoomAccountRealtimeService {
  private readonly connections = new Set<Connection>();
  private readonly poll?: NodeJS.Timeout;
  private readonly ping: NodeJS.Timeout;
  private readonly read: SyncReader;
  private deliveredFrames = 0;
  private syncFailures = 0;

  constructor(read: SyncReader, pollIntervalMs = 1000) {
    this.read = read;
    // Covers commits from federation workers and other server processes too.
    if (pollIntervalMs > 0) {
      this.poll = setInterval(() => this.notifyCommitted(), pollIntervalMs);
      this.poll.unref();
    }
    this.ping = setInterval(() => {
      for (const connection of this.connections) {
        if (connection.socket.readyState !== 1) { this.connections.delete(connection); continue; }
        if (!connection.alive) { connection.socket.terminate(); continue; }
        connection.alive = false;
        connection.socket.ping();
      }
    }, 20_000);
    this.ping.unref();
  }

  attach(accountId: string, socket: WebSocket, cursor: string | null): void {
    if (this.connections.size >= 2000 || [...this.connections].filter(c => c.accountId === accountId).length >= 8) {socket.close(1013, 'connection limit'); return;}
    const connection: Connection = { accountId, socket, cursor, flushing: false, again: false, alive: true };
    this.connections.add(connection);
    socket.on('pong', () => { connection.alive = true; });
    socket.on('close', () => this.connections.delete(connection));
    socket.on('error', () => this.connections.delete(connection));
    void this.flush(connection);
  }

  notifyCommitted(): void {
    for (const connection of this.connections) void this.flush(connection);
  }

  private async flush(connection: Connection): Promise<void> {
    if (connection.flushing) { connection.again = true; return; }
    connection.flushing = true;
    try {
      do {
        connection.again = false;
        if (!this.connections.has(connection) || connection.socket.readyState !== 1) return;
        const page = await this.read(connection.accountId, connection.cursor, 100);
        if (page.hasMore && page.nextCursor === connection.cursor) throw new Error('non-progressing account cursor');
        for (const event of page.events) {
          const frame = JSON.stringify(event);
          if (Buffer.byteLength(frame) > 512 * 1024 || connection.socket.bufferedAmount > 1024 * 1024) {
            // Do not drop an event silently. The reconnecting client catches up
            // with REST, where attachments/large envelopes have their own limit.
            connection.socket.close(1013, 'resume with account sync');
            return;
          }
          if (connection.socket.readyState !== 1) return;
          connection.socket.send(frame);
          this.deliveredFrames++;
        }
        connection.cursor = page.nextCursor;
        connection.again ||= page.hasMore;
        if (connection.again) await new Promise<void>(resolve => setImmediate(resolve));
      } while (connection.again);
    } catch {
      this.syncFailures++;
      connection.socket.close(1011, 'account sync unavailable');
    } finally {
      connection.flushing = false;
    }
  }

  connectedAccountCount(): number {
    return new Set([...this.connections].filter(c => c.socket.readyState === 1).map(c => c.accountId)).size;
  }

  diagnostics(): Record<string, unknown> {
    return {
      accountStreams: this.connections.size,
      flushingStreams: [...this.connections].filter(connection => connection.flushing).length,
      deliveredFrames: this.deliveredFrames,
      syncFailures: this.syncFailures,
    };
  }

  close(): void {
    if (this.poll) clearInterval(this.poll);
    clearInterval(this.ping);
    for (const connection of this.connections) connection.socket.close(1001, 'server shutdown');
    this.connections.clear();
  }
}


