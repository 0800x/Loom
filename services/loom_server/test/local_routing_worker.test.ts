import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { LocalRoutingWorker } from '../src/messaging/local_routing_worker.ts';

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'loom-routing-'));
  const store = new SqliteStore(dir);
  store.db.prepare(`INSERT INTO accounts(id,username,display_name,identity_id,identity_public_key,identity_fingerprint,password_salt,password_hash,created_at) VALUES(?,?,?,?,?,?,?,?,?)`)
    .run('alice', 'alice', 'Alice', 'chn:test', 'public', 'fingerprint', 'salt', 'hash', new Date().toISOString());
  for (const conversation of ['slow', 'fast']) {
    store.db.prepare(`INSERT INTO conversations(id,kind,peer_address,created_at) VALUES(?,'direct',?,?)`).run(conversation, `@bob:${conversation}.test`, new Date().toISOString());
    store.db.prepare(`INSERT INTO conversation_members(conversation_id,account_id) VALUES(?,'alice')`).run(conversation);
  }
  const input = (clientId: string, conversationId = 'slow') => ({ conversationId, clientId,
    senderAddress: '@alice:home.test', type: 'TEXT', ciphertext: 'opaque', protocolVersion: 'Loom-Direct-v1' });
  return { dir, store, input, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

async function until(predicate: () => boolean) {
  for (let i = 0; i < 200; i++) { if (predicate()) return; await delay(5); }
  assert.fail('routing did not reach the expected state');
}

test('acceptance and routing intent roll back together; duplicate retries repair old missing intents', () => {
  const f = fixture();
  try {
    f.store.db.exec(`CREATE TRIGGER reject_route BEFORE INSERT ON message_route_jobs BEGIN SELECT RAISE(ABORT,'route_store_failed'); END;`);
    assert.throws(() => f.store.createMessage('alice', f.input('once')), /route_store_failed/);
    assert.equal(f.store.stats().messages, 0);
    assert.equal(f.store.stats().events, 0);
    f.store.db.exec('DROP TRIGGER reject_route');
    const receipt = f.store.createMessage('alice', f.input('once'));
    assert.equal(f.store.pendingMessageRoutes(10).length, 1);
    f.store.db.exec('DELETE FROM message_route_jobs'); // old installation's interrupted acceptance
    assert.deepEqual(f.store.createMessage('alice', f.input('once')), receipt);
    assert.equal(f.store.pendingMessageRoutes(10).length, 1);
    assert.equal(f.store.stats().messages, 1);
    f.store.completeMessageRoute(String(receipt.messageId));
    f.store.createMessage('alice', f.input('once'));
    assert.equal(f.store.pendingMessageRoutes(10).length, 0, 'completed intent must not be reopened');
  } finally { f.store.close(); f.cleanup(); }
});

test('worker resumes accepted ciphertext after restart; slow peer does not block another chat', async () => {
  const f = fixture();
  f.store.createMessage('alice', f.input('slow-1'));
  f.store.createMessage('alice', f.input('slow-2'));
  f.store.createMessage('alice', f.input('fast-1', 'fast'));
  f.store.close();
  const restored = new SqliteStore(f.dir);
  const seen: string[] = [];
  const completed: string[] = [];
  let unblock!: () => void;
  const gate = new Promise<void>(resolve => { unblock = resolve; });
  let notifications = 0;
  const worker = new LocalRoutingWorker(restored, {
    async routeLocalMessage(input) {
      const id = input.message.clientId;
      assert.equal(input.senderAddress, '@alice:home.test');
      assert.equal(input.message.ciphertext, 'opaque');
      seen.push(id);
      if (id === 'slow-1') await gate;
      completed.push(id);
      return [];
    },
  }, 'home.test', () => { notifications++; });
  try {
    worker.start();
    await until(() => completed.includes('fast-1'));
    assert.deepEqual(completed, ['fast-1']);
    assert.ok(!seen.includes('slow-2'), 'same-chat order must survive concurrency');
    unblock();
    await until(() => restored.stats().pendingMessageRoutes === 0);
    assert.deepEqual(completed, ['fast-1', 'slow-1', 'slow-2']);
    assert.equal(notifications, 3);
  } finally { unblock(); await worker.stop(); restored.close(); f.cleanup(); }
});

test('failed routing persists retry state and preserves order while other chats progress', async () => {
  const f = fixture();
  const first = f.store.createMessage('alice', f.input('slow-1'));
  f.store.createMessage('alice', f.input('slow-2'));
  f.store.createMessage('alice', f.input('fast-1', 'fast'));
  let fail = true;
  const completed: string[] = [];
  const worker = new LocalRoutingWorker(f.store, {
    async routeLocalMessage(input) {
      if (input.conversationId === 'slow' && fail) throw new Error('discovery_temporarily_unavailable');
      completed.push(input.message.clientId);
      return [];
    },
  }, 'home.test', () => {});
  try {
    worker.start();
    await until(() => completed.includes('fast-1') && worker.diagnostics().inFlight === 0);
    const row = f.store.db.prepare(`SELECT * FROM message_route_jobs WHERE message_id=?`).get(String(first.messageId));
    assert.equal(row?.attempts, 1);
    assert.equal(row?.last_error, 'discovery_temporarily_unavailable');
    assert.equal(f.store.stats().pendingMessageRoutes, 2);
    assert.deepEqual(f.store.pendingMessageRoutes(10), [], 'later message cannot overtake backoff');
    fail = false;
    f.store.retryMessageRoute(String(first.messageId), 1, new Date(0).toISOString(), 'manual_retry');
    worker.kick();
    await until(() => f.store.stats().pendingMessageRoutes === 0);
    assert.deepEqual(completed, ['fast-1', 'slow-1', 'slow-2']);
  } finally { await worker.stop(); f.store.close(); f.cleanup(); }
});
