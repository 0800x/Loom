import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LoomNodeIdentity } from '../src/identity/node_identity.ts';
import { createFederationEnvelope, renewFederationEnvelope, validateFederationEnvelope } from '../src/federation/event.ts';

test('receipt kind and payload are covered by the origin signature', () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-receipt-sig-'));
  try {
    const identity=LoomNodeIdentity.loadOrCreate(dir);
    const receipt=createFederationEnvelope(identity,{eventType:'message.received',originDomain:'b.example',destinationNodeId:'node:a',destinationDomain:'a.example',senderAddress:'@bob:b.example',recipientAddresses:['@alice:a.example'],conversationId:'conversation',createdAt:new Date().toISOString(),payload:{messageId:'fevt_00000000-0000-4000-8000-000000000001',clientId:'client',type:'RECEIPT',ciphertext:'',protocolVersion:'Loom-Receipt-v1'}});
    const options={localDomain:'a.example',localNodeId:'node:a'};
    assert.equal(validateFederationEnvelope(receipt,identity.publicInfo().publicKey,options).eventType,'message.received');
    assert.throws(()=>validateFederationEnvelope({...receipt,payload:{...receipt.payload,clientId:'forged'}},identity.publicInfo().publicKey,options),/signature/);
    assert.throws(()=>validateFederationEnvelope({...receipt,eventType:'message.created'},identity.publicInfo().publicKey,options),/ciphertext/);
    assert.throws(()=>validateFederationEnvelope({...receipt,senderAddress:'@eve:b.example'},identity.publicInfo().publicKey,options),/signature/);
  } finally {rmSync(dir,{recursive:true,force:true});}
});

test('durable retry renews transport freshness without moving old messages to the end of a chat', () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-retry-sig-'));
  try {
    const identity=LoomNodeIdentity.loadOrCreate(dir);
    const createdAt=new Date(Date.now()-60*60_000).toISOString();
    const original=createFederationEnvelope(identity,{eventType:'message.created',originDomain:'a.example',destinationNodeId:'node:b',destinationDomain:'b.example',senderAddress:'@alice:a.example',recipientAddresses:['@bob:b.example'],conversationId:'conversation',createdAt,payload:{messageId:'message',clientId:'client',type:'TEXT',ciphertext:'opaque',protocolVersion:'Loom-Direct-v1'}});
    const options={localDomain:'b.example',localNodeId:'node:b'};
    assert.throws(()=>validateFederationEnvelope(original,identity.publicInfo().publicKey,options),/stale/);
    const retry=renewFederationEnvelope(identity,original);
    assert.equal(validateFederationEnvelope(retry,identity.publicInfo().publicKey,options).payload.createdAt,createdAt);
    assert.equal(retry.eventId,original.eventId); assert.equal(retry.payload.ciphertext,original.payload.ciphertext);
    assert.equal(renewFederationEnvelope(identity,retry).payload.createdAt,createdAt);
  } finally {rmSync(dir,{recursive:true,force:true});}
});
