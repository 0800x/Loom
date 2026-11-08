import { createHmac, randomBytes } from 'node:crypto';

export class RateLimitError extends Error {
  retryAfter: number;
  constructor(retryAfter = 60) { super('rate_limited'); this.retryAfter = retryAfter; }
}

type Bucket = { tokens: number; updatedAt: number; limit: number };

/** Bounded concurrency admission gate. `enter()` throws a short-retry
 * RateLimitError while saturated and every release is idempotent. */
export class LoomAdmissionGate {
  private active = 0;
  private readonly maxConcurrent: number;
  constructor(maxConcurrent: number) {
    if (!Number.isSafeInteger(maxConcurrent) || maxConcurrent < 1) throw new Error('invalid_admission_capacity');
    this.maxConcurrent = maxConcurrent;
  }
  enter(): () => void {
    if (this.active >= this.maxConcurrent) throw new RateLimitError(1);
    this.active++;
    let released = false;
    return () => { if (!released) { released = true; this.active--; } };
  }
  get busy(): number { return this.active; }
}

/** Process-local token buckets. Exact entries evict only after being idle
 * long enough to have fully refilled (see `sweep`); once exact capacity is
 * reached anyway, new subjects use a fixed number of shared, conservatively
 * charged overflow buckets. Collisions can throttle unrelated subjects, but
 * cannot reset an exhausted subject or grow memory without bound.
 */
export class LoomRateLimiter {
  private buckets = new Map<string, Bucket>();
  private readonly bucketKey = randomBytes(32);
  private overflow: Array<Bucket | undefined>;
  private readonly gate: LoomAdmissionGate;
  private readonly idleMs: number;
  private maxEntries: number;
  constructor(maxEntries = 10000, maxConcurrent = 32, overflowEntries = 256, idleMs = 600_000) {
    if (![maxEntries, maxConcurrent, overflowEntries].every(n => Number.isSafeInteger(n) && n > 0)) throw new Error('invalid_rate_limiter_capacity');
    if (!Number.isSafeInteger(idleMs) || idleMs < 0) throw new Error('invalid_rate_limiter_idle_window');
    this.maxEntries = maxEntries;
    this.gate = new LoomAdmissionGate(maxConcurrent);
    this.idleMs = idleMs;
    this.overflow = new Array(overflowEntries);
  }
  /** Evict exact buckets that have been idle long enough to have fully
   * refilled. Rotating credentials (Internet scanners sending random bearer
   * tokens, or the 15-minute client access-token rotation) otherwise fill the
   * exact map once and degrade every new subject into the shared overflow
   * shards until the process is restarted. */
  private sweep(now = Date.now()): void {
    if (this.idleMs <= 0 || this.buckets.size === 0) return;
    for (const [key, bucket] of this.buckets) {
      const idle = now - bucket.updatedAt;
      if (idle < this.idleMs) continue;
      // The bucket is never re-consumed, so its refill must be computed here:
      // only a bucket that has effectively fully refilled may be discarded.
      const effective = Math.min(bucket.limit, bucket.tokens + idle * bucket.limit / 60000);
      if (effective + 1e-9 >= bucket.limit) this.buckets.delete(key);
    }
  }
  consume(scope: string, subject: string, limit: number, now = Date.now()): void {
    if (!Number.isSafeInteger(limit) || limit < 1 || !Number.isFinite(now)) throw new Error('invalid_rate_limiter_quota');
    const digest = createHmac('sha256', this.bucketKey).update(JSON.stringify([scope, subject])).digest();
    const key = digest.toString('hex');
    let bucket = this.buckets.get(key);
    if (!bucket) {
      if (this.buckets.size >= this.maxEntries) this.sweep(now);
      if (this.buckets.size < this.maxEntries) {
        bucket = { tokens: limit, updatedAt: now, limit };
        this.buckets.set(key, bucket);
      } else {
        const index = digest.readUInt32BE(0) % this.overflow.length;
        bucket = this.overflow[index];
        if (!bucket) this.overflow[index] = bucket = { tokens: limit, updatedAt: now, limit };
      }
    }
    const elapsed = Math.max(0, now - bucket.updatedAt);
    bucket.tokens = Math.min(bucket.limit, bucket.tokens + elapsed * bucket.limit / 60000);
    // Only a fully recovered bucket has no outstanding quota history. An idle
    // shard must not retain a colliding subject's smaller quota forever.
    if (bucket.tokens >= bucket.limit) {
      bucket.limit = limit;
      bucket.tokens = limit;
    } else {
      bucket.limit = Math.min(bucket.limit, limit);
      bucket.tokens = Math.min(bucket.tokens, bucket.limit);
    }
    bucket.updatedAt = Math.max(bucket.updatedAt, now);
    if (bucket.tokens + 1e-9 < 1) throw new RateLimitError(Math.max(1, Math.ceil((1 - bucket.tokens) * 60 / bucket.limit)));
    bucket.tokens = Math.max(0, bucket.tokens - 1);
  }
  enter(): () => void { return this.gate.enter(); }
  get busy(): number { return this.gate.busy; }
}

export function endpointClass(path: string): [string, number] {
  if (path.startsWith('/api/v1/auth/')) return ['auth', 30];
  if (path.startsWith('/api/v1/device-links/')) return ['link', 30];
  if (path.includes('attachments')) return ['upload', 60];
  if (path.includes('federation')) return ['federation', 240];
  if (path.endsWith('/challenge') || path.includes('/security/') || path.includes('device-bundle')) return ['crypto', 120];
  return ['general', 600];
}
