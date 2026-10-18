import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadOrCreateConfig } from '../src/config/config.ts';
import { LoomNodeIdentity } from '../src/identity/node_identity.ts';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { FederationNodeRegistry } from '../src/federation/node_registry.ts';
import { FederationRoutingStore } from '../src/federation/routing_store.ts';
import { FederationService } from '../src/federation/service.ts';

function identityMaterial() {
  const pair = generateKeyPairSync('ed25519');
  const der = pair.publicKey.export({ type: 'spki', format: 'der' });
  const raw = der.subarray(-32);
  const digest = createHash('sha256').update(raw).digest();
  const hex = digest.toString('hex').toUpperCase();
  return {
    identityId: `chn:${digest.toString('base64url')}`,
    publicKey: raw.toString('base64'),
    fingerprint: hex.match(/.{1,4}/g)!.join(' '),
  };
}

test('same-Node direct ciphertext routes without enabling federation or network discovery', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-same-node-direct-'));
  const base = loadOrCreateConfig(join(dir, 'node.json')).config;
  const config = {
    ...base,
    dataDirectory: dir,
    attachmentsDirectory: join(dir, 'attachments'),
    publicDomain: 'loom-local.test',
    publicBaseUrl: 'https://loom-local.test',
    federationMode: 'disabled' as const,
  };
  const accounts = new SqliteStore(dir);
  const nodes = FederationNodeRegistry.sqliteStore(dir);
  const routing = FederationRoutingStore.sqliteStore(dir);
  const nodeIdentity = LoomNodeIdentity.loadOrCreate(dir);
  const service = new FederationService(config, nodeIdentity, nodes, routing);
  try {
    const alice = await accounts.register({
      username: 'alice',
      displayName: 'Alice',
      password: 'correct horse battery staple',
      deviceName: 'Alice phone',
      identity: identityMaterial(),
      protocolVersion: 'Loom-Identity-v1',
    }, config.publicDomain);
    const bob = await accounts.register({
      username: 'bob',
      displayName: 'Bob',
      password: 'correct horse battery staple',
      deviceName: 'Bob phone',
      identity: identityMaterial(),
      protocolVersion: 'Loom-Identity-v1',
    }, config.publicDomain);

    const created = await service.createRemoteConversation(alice.accountId, bob.address);
    assert.equal(created.peerAddress, bob.address);
    assert.equal(created.profile.homeNode.nodeId, nodeIdentity.publicInfo().nodeId);

    const receipt = accounts.createMessage(alice.accountId, {
      conversationId: created.conversationId,
      clientId: 'alice-direct-1',
      senderAddress: alice.address,
      type: 'TEXT',
      ciphertext: '{"opaque":"e2ee-direct"}',
      protocolVersion: 'Loom-Direct-v1',
      metadata: { e2ee: true },
    });
    const outbound = await service.routeLocalMessage({
      conversationId: created.conversationId,
      senderAddress: alice.address,
      receipt,
      message: {
        messageId: String(receipt.messageId),
        clientId: 'alice-direct-1',
        type: 'TEXT',
        ciphertext: '{"opaque":"e2ee-direct"}',
        protocolVersion: 'Loom-Direct-v1',
        metadata: { e2ee: true },
      },
    });
    assert.deepEqual(outbound, [], 'same-Node delivery must not enter the network outbox');

    const bobSync = accounts.sync(bob.accountId, null, 200);
    const incoming = bobSync.events.filter((event) => event.kind === 'message.created');
    assert.equal(incoming.length, 1);
    const payload = incoming[0].payload as Record<string, unknown>;
    assert.equal(payload.senderAddress, alice.address);
    assert.equal(payload.ciphertext, '{"opaque":"e2ee-direct"}');
    assert.equal(payload.protocolVersion, 'Loom-Direct-v1');
    assert.notEqual(payload.conversationId, created.conversationId, 'each account keeps its own Node-local conversation row');

    const aliceSync = accounts.sync(alice.accountId, null, 200);
    const delivered = aliceSync.events.filter((event) => event.kind === 'message.nodeAccepted');
    assert.equal(delivered.length, 1);
    assert.equal(aliceSync.events.filter(event => event.kind === 'message.delivered').length, 0, 'Node acceptance is not recipient delivery');
    assert.equal(delivered[0].payload.clientId, 'alice-direct-1');
    assert.equal(delivered[0].payload.messageId, receipt.messageId);
    assert.equal(delivered[0].payload.status, 'nodeAccepted');

    const bobConversation = accounts.listConversations(bob.accountId)
      .find((conversation) => conversation.id === payload.conversationId);
    assert.ok(bobConversation);
    assert.equal(bobConversation.peerAddress, alice.address);
    assert.equal(bobConversation.unreadCount, 1);

    assert.equal(accounts.acknowledgeReceived(alice.accountId, alice.address, ['alice-direct-1']), 0, 'sender cannot acknowledge for the offline recipient');
    assert.equal(accounts.acknowledgeReceived(bob.accountId, bob.address, ['unknown-client']), 0);
    assert.equal(accounts.acknowledgeReceived(bob.accountId, bob.address, ['alice-direct-1']), 1);
    assert.equal(accounts.acknowledgeReceived(bob.accountId, bob.address, ['alice-direct-1']), 0, 'duplicate receipt is idempotent');
    const received = accounts.sync(alice.accountId, null, 200).events.filter(event => event.kind === 'message.delivered');
    assert.equal(received.length, 1);
    assert.equal(received[0].payload.deliveryEvidence, 'recipient-device');

    const seen = new Date('2026-09-21T12:00:00Z');
    accounts.touchPresence(bob.accountId, seen);
    assert.equal(accounts.conversationPresence(alice.accountId, created.conversationId, config.publicDomain, seen).online, true);
    const stale = accounts.conversationPresence(alice.accountId, created.conversationId, config.publicDomain, new Date(seen.getTime() + 46_000));
    assert.equal(stale.online, false);
    assert.equal(stale.lastSeenAt, seen.toISOString());
    assert.equal(accounts.conversationPresence(bob.accountId, created.conversationId, config.publicDomain, seen).available, false, 'non-member cannot inspect a conversation');
    accounts.markRead(bob.accountId, String(payload.conversationId), Number(payload.serverOrder));
    assert.equal(accounts.listConversations(bob.accountId).find(c => c.id === payload.conversationId)?.unreadCount, 0);

    const queue = await routing.listQueue();
    assert.equal(queue.length, 0);
  } finally {
    service.stop();
    await routing.close();
    await nodes.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
