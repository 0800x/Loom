#!/usr/bin/env node
// Phase 11 deterministic fault checks that require only Node built-ins.
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';

const boundedBackoff = (attempt, base = 250, cap = 30_000) => Math.min(cap, base * 2 ** Math.max(0, attempt));
for (let i = 0; i < 16; i += 1) {
  const delay = boundedBackoff(i);
  assert(delay >= 250 && delay <= 30_000);
}
assert.equal(boundedBackoff(99), 30_000);

const controller = new AbortController();
const pending = sleep(2_000, undefined, { signal: controller.signal });
controller.abort();
await assert.rejects(pending, /Abort/);

console.log('Deterministic Node chaos primitives passed');
