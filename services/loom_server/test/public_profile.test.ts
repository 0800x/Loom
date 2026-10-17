import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { FederationRoutingStore } from '../src/federation/routing_store.ts';
import { validateProfileUpdate } from '../src/profile/profile.ts';
import { LoomNodeIdentity } from '../src/identity/node_identity.ts';
import { signFederationUserProfile, verifyFederationUserProfile } from '../src/federation/user_protocol.ts';

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

function pngChunk(type: string, data: Buffer): Buffer {
  const chunk = Buffer.alloc(12 + data.length);
  chunk.writeUInt32BE(data.length);
  chunk.write(type, 4, 'ascii');
  data.copy(chunk, 8);
  let crc = 0xffffffff;
  for (const byte of chunk.subarray(4, 8 + data.length)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  chunk.writeUInt32BE((crc ^ 0xffffffff) >>> 0, 8 + data.length);
  return chunk;
}

test('Flutter channel-precision PNG chunk is accepted without accepting arbitrary metadata', () => {
  const bytes = Buffer.from(png, 'base64');
  const withChunks = (...chunks: Buffer[]) => Buffer.concat([bytes.subarray(0,33),...chunks,bytes.subarray(33)]).toString('base64');
  const update = (image: string) => validateProfileUpdate({displayName:'Alice',avatar:{png:image,color:0}});
  const sbit = pngChunk('sBIT', Buffer.from([8,8])); // grayscale + alpha fixture
  assert.equal(update(withChunks(sbit)).avatar.png, withChunks(sbit));
  assert.throws(() => update(withChunks(sbit, sbit)));
  assert.throws(() => update(withChunks(pngChunk('sBIT', Buffer.from([0,8])))));
  assert.throws(() => update(withChunks(pngChunk('sBIT', Buffer.from([8])))));
  assert.throws(() => update(withChunks(pngChunk('tEXt', Buffer.from('author\0private')))));
  assert.throws(() => update(withChunks(pngChunk('eXIf', Buffer.from('private')))));
});

test('public profile validates bounded metadata-free PNGs and immutable identity fields', () => {
  assert.equal(validateProfileUpdate({displayName:' Alice ', avatar:{png,color:2}}).displayName, 'Alice');
  for (const bad of [
    {displayName:'Alice', avatar:{png:'https://example.org/avatar.svg',color:0}},
    {displayName:'Alice', avatar:{png,color:6}},
    {displayName:'Alice', avatar:{png,color:0}, username:'someone_else'},
    {displayName:'Alice\nadmin', avatar:{png:null,color:0}},
  ]) assert.throws(() => validateProfileUpdate(bad));
  const corrupted = Buffer.from(png,'base64'); corrupted[corrupted.length-1] ^= 1;
  assert.throws(() => validateProfileUpdate({displayName:'Alice', avatar:{png:corrupted.toString('base64'),color:0}}));
});

test('profile persists, clears and is covered by the federation signature', async () => {
  const dir=mkdtempSync(join(tmpdir(),'loom-profile-'));
  const store=new SqliteStore(dir);
  const routes=FederationRoutingStore.sqliteStore(dir);
  try {
    // Use the same identity fixture shape as existing storage tests.
    const identity=LoomNodeIdentity.loadOrCreate(join(dir,'node'));
    const info=identity.publicInfo();
    // Registration validates user key binding separately; seed a minimal account
    // here to isolate persistence from account bootstrap.
    const {DatabaseSync}=await import('node:sqlite');
    const db=new DatabaseSync(join(dir,'loom.sqlite3'));
    db.prepare(`INSERT INTO accounts(id,username,display_name,identity_id,identity_public_key,identity_fingerprint,password_salt,password_hash,created_at) VALUES(?,?,?,?,?,?,?,?,?)`).run('account','alice','Alice','chn:test',info.publicKey,info.fingerprint,'salt','hash',new Date().toISOString());
    db.close();
    const saved=store.updateProfile('account','node.example', validateProfileUpdate({displayName:'Alice R',avatar:{png,color:2}}));
    assert.equal(store.readProfile('account','node.example').avatar.png,png);
    const local=await routes.resolveLocalUser('alice','node.example');
    assert.equal(local?.avatar?.png,png);
    local!.homeNode.nodeId=info.nodeId;
    const signed=signFederationUserProfile(identity,local!);
    const expected={address:local!.address,nodeId:info.nodeId,domain:'node.example'};
    assert.equal(verifyFederationUserProfile(signed,info.publicKey,expected).avatar?.png,png);
    assert.throws(() => verifyFederationUserProfile({...signed,avatar:{png:null,color:2}},info.publicKey,expected));
    await routes.cacheRemoteUser(local!);
    assert.equal((await routes.getCachedRemoteUser(local!.address))?.avatar?.png,png);
    const cleared=store.updateProfile('account','node.example',validateProfileUpdate({displayName:'Alice R',avatar:{png:null,color:2}}));
    assert.notEqual(saved.revision,cleared.revision);
    assert.equal((await routes.resolveLocalUser('alice','node.example'))?.avatar?.png,null);
    assert.equal(store.readProfile('account','node.example').address,'@alice:node.example');
  } finally { await routes.close(); store.close(); rmSync(dir,{recursive:true,force:true}); }
});
