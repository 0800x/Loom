import { createHash } from 'node:crypto';

export class RateLimitError extends Error {
  retryAfter: number;
  constructor(retryAfter = 60) { super('rate_limited'); this.retryAfter = retryAfter; }
}

/** Fixed-window quotas with bounded state. Saturation fails closed rather than
 * evicting active buckets and letting an attacker reset another user's quota. */
export class LoomRateLimiter {
  private buckets = new Map<string, { count: number; expires: number }>();
  private active = 0;
  private maxEntries: number;
  private maxConcurrent: number;
  constructor(maxEntries = 10000, maxConcurrent = 32) { this.maxEntries = maxEntries; this.maxConcurrent = maxConcurrent; }
  consume(scope: string, subject: string, limit: number, now = Date.now()): void {
    const key = scope + ':' + createHash('sha256').update(subject).digest('hex');
    let bucket = this.buckets.get(key);
    if (!bucket || bucket.expires <= now) {
      if (this.buckets.size >= this.maxEntries) {
        for (const [k, b] of this.buckets) if (b.expires <= now) this.buckets.delete(k);
        if (this.buckets.size >= this.maxEntries && !bucket) throw new RateLimitError();
      }
      bucket = { count: 0, expires: now + 60000 };
      this.buckets.set(key, bucket);
    }
    if (bucket.count >= limit) throw new RateLimitError(Math.max(1, Math.ceil((bucket.expires - now)/1000)));
    bucket.count++;
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
