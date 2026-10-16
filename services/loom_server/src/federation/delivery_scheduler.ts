import type { OutboxDelivery } from './routing_store.ts';

/** Bounded workers, with one request per destination and no batch barrier. */
export class FederationDeliveryScheduler {
  private readonly active = new Map<string, string>();
  private pumping = false;
  private requested = false;
  private stopped = false;
  private readonly listDue: (limit: number, busyNodes: string[]) => Promise<OutboxDelivery[]>;
  private readonly deliver: (delivery: OutboxDelivery) => Promise<void>;
  private readonly onError: (error: unknown) => void;
  private readonly concurrency: number;

  constructor(
    listDue: (limit: number, busyNodes: string[]) => Promise<OutboxDelivery[]>,
    deliver: (delivery: OutboxDelivery) => Promise<void>,
    onError: (error: unknown) => void,
    concurrency = 4,
  ) {
    this.listDue = listDue;
    this.deliver = deliver;
    this.onError = onError;
    this.concurrency = concurrency;
  }

  get inFlight(): number { return this.active.size; }
  resume(): void { this.stopped = false; }
  stop(): void { this.stopped = true; this.requested = false; }

  async kick(): Promise<void> {
    if (this.stopped) return;
    this.requested = true;
    if (this.pumping) return;
    this.pumping = true;
    try {
      while (this.requested && !this.stopped) {
        this.requested = false;
        const capacity = this.concurrency - this.active.size;
        if (capacity <= 0) break;
        const due = await this.listDue(capacity, [...this.active.keys()]);
        if (this.stopped) break;
        for (const delivery of due) {
          if (this.active.size >= this.concurrency) break;
          const nodeId = delivery.destinationNodeId;
          if (this.active.has(nodeId)) continue;
          this.active.set(nodeId, delivery.deliveryId);
          // A completion replenishes its own slot, even when another Node is
          // still waiting for its HTTPS deadline. Store failures wait for the
          // periodic sweep instead of creating an immediate retry spin.
          void Promise.resolve().then(() => this.deliver(delivery)).then(
            () => {
              this.active.delete(nodeId);
              void this.kick().catch(this.onError);
            },
            (error: unknown) => {
              this.active.delete(nodeId);
              this.onError(error);
            },
          );
        }
      }
    } finally {
      this.pumping = false;
    }
  }
}
