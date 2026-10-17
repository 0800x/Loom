import test from 'node:test';
import assert from 'node:assert/strict';
import { ensureAttachmentBucket } from '../src/attachments/initialize_bucket.ts';

test('existing attachment bucket is not recreated', async () => {
  const calls: string[] = [];
  await ensureAttachmentBucket(async kind => { calls.push(kind); });
  assert.deepEqual(calls, ['head']);
});
test('missing attachment bucket is created once', async () => {
  const calls: string[] = [];
  await ensureAttachmentBucket(async kind => { calls.push(kind); if (kind === 'head') throw { $metadata: { httpStatusCode: 404 } }; });
  assert.deepEqual(calls, ['head', 'create']);
});
test('authentication failure stops without retry or alternate credentials', async () => {
  for (const status of [401, 403]) {
    let count = 0;
    await assert.rejects(ensureAttachmentBucket(async () => { count++; throw { $metadata: { httpStatusCode: status } }; }, async () => { assert.fail('must not retry authentication'); }), /rejected/);
    assert.equal(count, 1);
  }
});
test('unreachable storage retries within a bounded window', async () => {
  let count = 0;
  await assert.rejects(ensureAttachmentBucket(async () => { count++; throw new Error('ECONNREFUSED'); }, async () => {}), /did not become reachable/);
  assert.equal(count, 90);
});
