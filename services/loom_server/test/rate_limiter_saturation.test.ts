import test from 'node:test';
import assert from 'node:assert/strict';
import { LoomRateLimiter, RateLimitError } from '../src/security/rate_limiter.ts';

test('token bucket refills continuously without a fixed-window double burst', () => {
  const limiter = new LoomRateLimiter();
  for (let i = 0; i < 10; i++) limiter.consume('auth', 'alice', 10, 0);
  assert.throws(() => limiter.consume('auth', 'alice', 10, 5999), RateLimitError);
  limiter.consume('auth', 'alice', 10, 6000);
  assert.throws(() => limiter.consume('auth', 'alice', 10, 6000), RateLimitError);
  for (let i = 0; i < 9; i++) limiter.consume('auth', 'alice', 10, 60000);
  assert.throws(() => limiter.consume('auth', 'alice', 10, 60000), RateLimitError);
});

test('saturation does not reject every fresh subject or evict exhausted quotas', () => {
  const limiter = new LoomRateLimiter(2, 1, 1);
  limiter.consume('login', 'a', 1, 0);
  limiter.consume('login', 'b', 1, 0);
  // A fixed-size overflow shard admits an initial burst, even with exact state full.
  limiter.consume('login', 'c', 1, 0);
  assert.throws(() => limiter.consume('login', 'a', 1, 0), RateLimitError);
  assert.throws(() => limiter.consume('login', 'c', 1, 0), RateLimitError);
  // Another subject cannot evict or reset that shared quota.
  assert.throws(() => limiter.consume('login', 'd', 1, 0), RateLimitError);
  limiter.consume('login', 'd', 1, 60000);
});

test('overflow state cannot be escaped by promotion into a recovered exact bucket', () => {
  const limiter = new LoomRateLimiter(1, 1, 1);
  limiter.consume('login', 'a', 1, 0);
  limiter.consume('login', 'b', 1, 1000);
  // Keep a in exact state; b must continue using its original shared history.
  limiter.consume('login', 'a', 1, 60000);
  assert.throws(() => limiter.consume('login', 'b', 1, 60000), RateLimitError);
});

test('high-cardinality churn keeps memory fixed and cannot increase a collided quota', () => {
  const limiter = new LoomRateLimiter(2, 1, 1);
  limiter.consume('small', 'a', 1, 0); limiter.consume('small', 'b', 1, 0);
  limiter.consume('small', 'c', 1, 0);
  for (let i = 0; i < 10000; i++) assert.throws(() => limiter.consume('large', String(i), 1000, 0), RateLimitError);
  const state = limiter as unknown as { buckets: Map<string, unknown>; overflow: unknown[] };
  assert.equal(state.buckets.size, 2); assert.equal(state.overflow.length, 1);
  assert.throws(() => limiter.consume('small', 'c', 1, 59000), RateLimitError);
  limiter.consume('small', 'c', 1, 60000);
});
