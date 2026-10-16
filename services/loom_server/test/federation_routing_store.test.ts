import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { FederationRoutingStore } from '../src/federation/routing_store.ts';
import type { FederationEnvelope } from '../src/federation/event.ts';

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

function envelope(input: { messageId: string; clientId: string; conversationId: string }): FederationEnvelope {
  return {
    protocol: 'loom-federation-v1',
    eventId: `fevt_${randomUUID()}`,
    eventType: 'message.created',
    originNodeId: 'node:source-test',
    originDomain: 'loom-a.test',
    destinationNodeId: 'node:destination-test',
    destinationDomain: 'loom-b.test',
    senderAddress: '@alice:loom-a.test',
    recipientAddresses: ['@bob:loom-b.test'],
    conversationId: input.conversationId,
    createdAt: new Date().toISOString(),
    payload: {
      messageId: input.messageId,
      clientId: input.clientId,
      type: 'TEXT',
      ciphertext: '{"opaque":true}',
      protocolVersion: 'Loom-Direct-v1',
    },
    signature: 'queued-envelope-does-not-need-validation-in-store-test',
  };
}

test('federated inbound delivery is idempotent and reconstructs normal sync state', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-federation-routing-'));
  const accounts = new SqliteStore(dir);
  const routing = FederationRoutingStore.sqliteStore(dir);
  try {
    const bob = accounts.register({
      username: 'bob',
      displayName: 'Bob',
      password: 'correct horse battery staple',
      deviceName: 'Bob test device',
      identity: identityMaterial(),
      protocolVersion: 'Loom-Identity-v1',
    }, 'loom-b.test');

    const eventId = `fevt_${randomUUID()}`;
    const inbound: FederationEnvelope = {
      protocol: 'loom-federation-v1',
      eventId,
      eventType: 'message.created',
      originNodeId: 'node:remote-test',
      originDomain: 'loom-a.test',
      destinationNodeId: 'node:local-test',
      destinationDomain: 'loom-b.test',
      senderAddress: '@alice:loom-a.test',
      recipientAddresses: ['@bob:loom-b.test'],
      conversationId: 'conv-node-a-only',
      createdAt: new Date().toISOString(),
      payload: {
        messageId: `msg_${randomUUID()}`,
        clientId: 'alice-client-1',
        type: 'TEXT',
        ciphertext: '{"opaque":true}',
        protocolVersion: 'Loom-Direct-v1',
        replyToMessageId: 'msg_parent',
        metadata: { attachmentCount: 0, e2ee: true },
      },
      signature: 'already-validated-by-federation-service',
    };

    const first = await routing.applyInbound(inbound);
    assert.equal(first.duplicate, false);
    assert.ok(first.conversationId);
    const second = await routing.applyInbound(inbound);
    assert.equal(second.duplicate, true);

    const page = accounts.sync(bob.accountId, null, 200);
    const conversationEvents = page.events.filter((event) => event.kind === 'conversation.upsert');
    assert.equal(conversationEvents.length, 1);
    assert.equal(page.events[0].kind, 'conversation.upsert');
    assert.equal(page.events[1].kind, 'message.created');
    assert.equal(conversationEvents[0].payload.id, first.conversationId);
    assert.equal(conversationEvents[0].payload.peerAddress, '@alice:loom-a.test');
    const messages = page.events.filter((event) => event.kind === 'message.created');
    assert.equal(messages.length, 1);
    const payload = messages[0].payload as Record<string, unknown>;
    assert.equal(payload.conversationId, first.conversationId);
    assert.equal(payload.replyToMessageId, 'msg_parent');
    assert.deepEqual(payload.metadata, { attachmentCount: 0, e2ee: true });
    assert.equal(payload.ciphertext, '{"opaque":true}');
    assert.equal(payload.protocolVersion, 'Loom-Direct-v1');

    const direct = accounts.listConversations(bob.accountId)
      .find((conversation) => conversation.id === first.conversationId);
    assert.ok(direct);
    assert.equal(direct.unreadCount, 1);
    assert.ok(Number(direct.updatedOrder) > 0);

    const selfConversationId = accounts.ensureSelfConversation(bob.accountId, bob.address);
    const local = accounts.createMessage(bob.accountId, {
      conversationId: selfConversationId,
      clientId: 'bob-local-after-federation',
      senderAddress: bob.address,
      type: 'TEXT',
      ciphertext: '{"self":true}',
      protocolVersion: 'Loom-Self-v1',
      metadata: { local: true },
    });
    assert.ok(Number(local.serverOrder) > Number(payload.serverOrder));
  } finally {
    await routing.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('remote outbox completion emits node-custody sync feedback to the sender exactly once', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-federation-delivered-'));
  const accounts = new SqliteStore(dir);
  const routing = FederationRoutingStore.sqliteStore(dir);
  try {
    const alice = accounts.register({
      username: 'alice',
      displayName: 'Alice',
      password: 'correct horse battery staple',
      deviceName: 'Alice test device',
      identity: identityMaterial(),
      protocolVersion: 'Loom-Identity-v1',
    }, 'loom-a.test');
    const conversationId = await routing.ensureRemoteConversation(alice.accountId, '@bob:loom-b.test', 'node:destination-test');
    const local = accounts.createMessage(alice.accountId, {
      conversationId,
      clientId: 'alice-delivery-client-1',
      senderAddress: alice.address,
      type: 'TEXT',
      ciphertext: '{"opaque":"delivery"}',
      protocolVersion: 'Loom-Direct-v1',
    });
    const delivery = await routing.enqueue(
      envelope({ messageId: String(local.messageId), clientId: String(local.clientId), conversationId }),
      'https://loom-b.test',
      String(local.messageId),
    );

    await routing.markDelivered(delivery.deliveryId);
    await routing.markDelivered(delivery.deliveryId);

    const events = accounts.sync(alice.accountId, null, 200).events;
    const delivered = events.filter((event) => event.kind === 'message.nodeAccepted');
    assert.equal(delivered.length, 1);
    assert.equal(events.filter(event => event.kind === 'message.delivered').length, 0, 'Node acceptance is not recipient delivery');
    assert.equal(delivered[0].payload.clientId, 'alice-delivery-client-1');
    assert.equal(delivered[0].payload.messageId, local.messageId);
    assert.equal(delivered[0].payload.destinationDomain, 'loom-b.test');
    assert.equal(delivered[0].payload.status, 'nodeAccepted');
  } finally {
    await routing.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('terminal remote failure emits failed sync feedback and a later retry may recover to node acceptance', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-federation-failed-'));
  const accounts = new SqliteStore(dir);
  const routing = FederationRoutingStore.sqliteStore(dir);
  try {
    const alice = accounts.register({
      username: 'alice',
      displayName: 'Alice',
      password: 'correct horse battery staple',
      deviceName: 'Alice test device',
      identity: identityMaterial(),
      protocolVersion: 'Loom-Identity-v1',
    }, 'loom-a.test');
    const conversationId = await routing.ensureRemoteConversation(alice.accountId, '@bob:loom-b.test', 'node:destination-test');
    const local = accounts.createMessage(alice.accountId, {
      conversationId,
      clientId: 'alice-failure-client-1',
      senderAddress: alice.address,
      type: 'TEXT',
      ciphertext: '{"opaque":"failure"}',
      protocolVersion: 'Loom-Direct-v1',
    });
    const delivery = await routing.enqueue(
      envelope({ messageId: String(local.messageId), clientId: String(local.clientId), conversationId }),
      'https://loom-b.test',
      String(local.messageId),
    );

    await routing.markFailed(delivery.deliveryId, 8, 'federation_delivery_http_503');
    assert.equal(await routing.retryFailed(delivery.deliveryId), 1);
    await routing.markDelivered(delivery.deliveryId);

    const events = accounts.sync(alice.accountId, null, 200).events;
    const failed = events.filter((event) => event.kind === 'message.failed');
    const delivered = events.filter((event) => event.kind === 'message.nodeAccepted');
    assert.equal(failed.length, 1);
    assert.equal(failed[0].payload.clientId, 'alice-failure-client-1');
    assert.equal(failed[0].payload.error, 'federation_delivery_http_503');
    assert.equal(delivered.length, 1);
    assert.equal(events.filter(event => event.kind === 'message.delivered').length, 0, 'Node acceptance is not recipient delivery');
    assert.equal(delivered[0].payload.clientId, 'alice-failure-client-1');
  } finally {
    await routing.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('same-node delivery feedback is idempotent', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-local-delivered-'));
  const accounts = new SqliteStore(dir);
  const routing = FederationRoutingStore.sqliteStore(dir);
  try {
    const alice = accounts.register({
      username: 'alice',
      displayName: 'Alice',
      password: 'correct horse battery staple',
      deviceName: 'Alice test device',
      identity: identityMaterial(),
      protocolVersion: 'Loom-Identity-v1',
    }, 'loom-a.test');
    const conversationId = await routing.ensureRemoteConversation(alice.accountId, '@bob:loom-a.test', 'node:local-test');
    const local = accounts.createMessage(alice.accountId, {
      conversationId,
      clientId: 'alice-local-delivery-client-1',
      senderAddress: alice.address,
      type: 'TEXT',
      ciphertext: '{"opaque":"local"}',
      protocolVersion: 'Loom-Direct-v1',
    });

    await routing.markLocalDelivered(String(local.messageId), 'loom-a.test');
    await routing.markLocalDelivered(String(local.messageId), 'loom-a.test');

    const events = accounts.sync(alice.accountId, null, 200).events;
    const delivered = events
      .filter((event) => event.kind === 'message.nodeAccepted');
    assert.equal(delivered.length, 1);
    assert.equal(events.filter(event => event.kind === 'message.delivered').length, 0, 'Node acceptance is not recipient delivery');
    assert.equal(delivered[0].payload.clientId, 'alice-local-delivery-client-1');
  } finally {
    await routing.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('federated recipient receipt binds original destination, account and client ID; duplicates never add ticks', async () => {
  const dirA=mkdtempSync(join(tmpdir(),'loom-receipt-a-')), dirB=mkdtempSync(join(tmpdir(),'loom-receipt-b-'));
  const a=new SqliteStore(dirA), b=new SqliteStore(dirB);
  const ra=FederationRoutingStore.sqliteStore(dirA), rb=FederationRoutingStore.sqliteStore(dirB);
  const register=(store:SqliteStore, username:string,domain:string)=>store.register({username,displayName:username,password:'correct horse battery staple',deviceName:'phone',identity:identityMaterial(),protocolVersion:'Loom-Identity-v1'},domain);
  try {
    const alice=register(a,'alice','loom-a.test'),bob=register(b,'bob','loom-b.test'),eve=register(b,'eve','loom-b.test');
    const conversationId=await ra.ensureRemoteConversation(alice.accountId,bob.address,'node:destination-test');
    const local=a.createMessage(alice.accountId,{conversationId,clientId:'receipt-client',senderAddress:alice.address,type:'TEXT',ciphertext:'opaque',protocolVersion:'Loom-Direct-v1'});
    const original=envelope({conversationId,messageId:String(local.messageId),clientId:'receipt-client'});
    const queued=await ra.enqueue(original,'https://loom-b.test',String(local.messageId));
    await rb.applyInbound(original); await ra.markDelivered(queued.deliveryId);
    assert.equal(a.sync(alice.accountId,null,200).events.filter(e=>e.kind==='message.delivered').length,0);
    assert.deepEqual(await rb.incomingReceiptTargets(eve.accountId,eve.address,['receipt-client']),[]);
    const targets=await rb.incomingReceiptTargets(bob.accountId,bob.address,['receipt-client']);
    assert.equal(targets.length,1); assert.equal(targets[0].eventId,original.eventId);
    const receipt: FederationEnvelope={...original,eventId:`fevt_${randomUUID()}`,eventType:'message.received',originNodeId:original.destinationNodeId,originDomain:original.destinationDomain,destinationNodeId:original.originNodeId,destinationDomain:original.originDomain,senderAddress:bob.address,recipientAddresses:[alice.address],payload:{messageId:original.eventId,clientId:'receipt-client',type:'RECEIPT',ciphertext:'',protocolVersion:'Loom-Receipt-v1'}};
    await assert.rejects(ra.applyInbound({...receipt,originNodeId:'node:impostor'}),/unknown_message/);
    await assert.rejects(ra.applyInbound({...receipt,senderAddress:eve.address}),/recipient_mismatch/);
    await assert.rejects(ra.applyInbound({...receipt,payload:{...receipt.payload,clientId:'other-client'}}),/recipient_mismatch/);
    assert.equal((await ra.applyInbound(receipt)).duplicate,false);
    assert.equal((await ra.applyInbound(receipt)).duplicate,true);
    const delivered=a.sync(alice.accountId,null,200).events.filter(e=>e.kind==='message.delivered');
    assert.equal(delivered.length,1); assert.equal(delivered[0].payload.deliveryEvidence,'recipient-device');
    assert.equal(delivered[0].payload.clientId,'receipt-client');
  } finally {await ra.close();await rb.close();a.close();b.close();rmSync(dirA,{recursive:true,force:true});rmSync(dirB,{recursive:true,force:true});}
});

test('due delivery selection is fair across destinations before applying its limit', async () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-fair-outbox-'));
  const store=FederationRoutingStore.sqliteStore(dir);
  try {
    for(let i=0;i<25;i++) {
      const e=envelope({messageId:`m${i}`,clientId:`c${i}`,conversationId:'c'});
      e.destinationNodeId='node:slow';
      await store.enqueue(e,'https://slow.example');
    }
    const fast=envelope({messageId:'fast',clientId:'fast',conversationId:'c'});
    fast.destinationNodeId='node:fast';
    await store.enqueue(fast,'https://fast.example');
    const due=await store.dueDeliveries(2);
    assert.equal(due.length,2);
    assert.deepEqual(new Set(due.map(d=>d.destinationNodeId)),new Set(['node:slow','node:fast']));
    const whileSlowBusy=await store.dueDeliveries(1,['node:slow']);
    assert.equal(whileSlowBusy[0].destinationNodeId,'node:fast');
  } finally {await store.close();rmSync(dir,{recursive:true,force:true});}
});
