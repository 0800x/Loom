import { createHmac, randomBytes } from 'node:crypto';

export class RateLimitError extends Error {
  retryAfter: number;
  constructor(retryAfter = 60) { super('rate_limited'); this.retryAfter = retryAfter; }
}

type Bucket = { tokens: number; updatedAt: number; limit: number };

/** Process-local token buckets. Exact entries never evict active quota history.
 * Once exact capacity is reached, new subjects use a fixed number of shared,
 * conservatively charged overflow buckets. Collisions can throttle unrelated
 * subjects, but cannot reset an exhausted subject or grow memory without bound.
 */
export class LoomRateLimiter {
  private buckets = new Map<string, Bucket>();
  private readonly bucketKey = randomBytes(32);
  private overflow: Array<Bucket | undefined>;
  private active = 0;
  private maxEntries: number;
  private maxConcurrent: number;
  constructor(maxEntries = 10000, maxConcurrent = 32, overflowEntries = 256) {
    if (![maxEntries, maxConcurrent, overflowEntries].every(n => Number.isSafeInteger(n) && n > 0)) throw new Error('invalid_rate_limiter_capacity');
    this.maxEntries = maxEntries; this.maxConcurrent = maxConcurrent;
    this.overflow = new Array(overflowEntries);
  }
  consume(scope: string, subject: string, limit: number, now = Date.now()): void {
    if (!Number.isSafeInteger(limit) || limit < 1 || !Number.isFinite(now)) throw new Error('invalid_rate_limiter_quota');
    const digest = createHmac('sha256', this.bucketKey).update(JSON.stringify([scope, subject])).digest();
    const key = digest.toString('hex');
    let bucket = this.buckets.get(key);
    if (!bucket) {
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
  enter(): () => void {
    if (this.active >= this.maxConcurrent) throw new RateLimitError(1);
    this.active++;
    let released = false;
    return () => { if (!released) { released = true; this.active--; } };
  }
}

export function endpointClass(path: string): [string, number] {
  if (path.startsWith('/api/v1/auth/')) return ['auth', 30];
  if (path.startsWith('/api/v1/device-links/')) return ['link', 30];
  if (path.includes('attachments')) return ['upload', 60];
  if (path.includes('federation')) return ['federation', 240];
  if (path.endsWith('/challenge') || path.includes('/security/') || path.includes('device-bundle')) return ['crypto', 120];
  return ['general', 600];
}
