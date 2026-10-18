import test from 'node:test';
import assert from 'node:assert/strict';
import { scryptSync, generateKeyPairSync, createHash } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { PostgresStore } from '../src/storage/postgres_store.ts';
import { PasswordHasher } from '../src/security/password_hash.ts';

test('legacy SQLite password login upgrades cost, rejects wrong passwords and preserves identity', async () => {
 const dir=mkdtempSync(join(tmpdir(),'loom-password-')), store=new SqliteStore(dir);
 try {
  const pub=generateKeyPairSync('ed25519').publicKey.export({type:'spki',format:'der'}).subarray(-32);
  const digest=createHash('sha256').update(pub).digest();
  const created=await store.register({username:'alice',displayName:'Alice',password:'correct horse battery staple',deviceName:'test',protocolVersion:'Loom-Identity-v1',identity:{identityId:'chn:'+digest.toString('base64url'),publicKey:pub.toString('base64'),fingerprint:digest.toString('hex').toUpperCase().match(/.{1,4}/g)!.join(' ')}},'localhost');
  const salt=Buffer.alloc(16,7),legacy=scryptSync('correct horse battery staple',salt,32).toString('base64');
  store.db.prepare('UPDATE accounts SET password_salt=?,password_hash=? WHERE id=?').run(salt.toString('base64'),legacy,created.accountId);
  await assert.rejects(store.login('alice','wrong password'),/invalid_credentials/);
  assert.equal(store.db.prepare('SELECT password_hash FROM accounts').get()!.password_hash,legacy);
  assert.equal((await store.login('alice','correct horse battery staple')).accountId,created.accountId);
  const upgraded=String(store.db.prepare('SELECT password_hash FROM accounts').get()!.password_hash);
  assert.match(upgraded,/^scrypt\$131072\$8\$1\$/);
  assert.equal((await store.login('alice','correct horse battery staple')).accountId,created.accountId);
 } finally {store.close();rmSync(dir,{recursive:true,force:true});}
});

test('legacy Postgres login uses async verification and compare-and-swap upgrade', async () => {
 const salt=Buffer.alloc(16,8),hash=scryptSync('correct horse battery staple',salt,32).toString('base64');
 const calls:Array<{sql:string;args:unknown[]}>=[];
 const row={id:'acc_test',username:'alice',identity_id:'chn:test',password_salt:salt.toString('base64'),password_hash:hash};
 const pool={async query(sql:string,args:unknown[]=[]){calls.push({sql,args});return {rows:sql.startsWith('SELECT')?[row]:[],rowCount:1};}};
 const store=Object.assign(Object.create(PostgresStore.prototype),{pool}) as PostgresStore;
 assert.equal((await store.login('alice','correct horse battery staple')).accountId,'acc_test');
 const update=calls.find(c=>c.sql.startsWith('UPDATE accounts SET password_hash'));
 assert.ok(update);assert.match(String(update.args[0]),/^scrypt\$131072\$8\$1\$/);assert.equal(update.args[2],hash);
});

test('hash queue is bounded and malformed or costly hash descriptors fail closed', async () => {
 const hasher=new PasswordHasher(1,0),salt=Buffer.alloc(16,9);
 const first=hasher.hash('correct horse battery staple',salt);
 await assert.rejects(hasher.hash('another password',salt),/rate_limited/);
 const encoded=await first;
 assert.equal((await hasher.verify('wrong',salt,encoded)).valid,false);
 for(const bad of ['scrypt$999999999$8$1$AAAA','scrypt$131072$1$1$AAAA','bad','scrypt$131072$8$1$AAAA']) await assert.rejects(hasher.verify('password',salt,bad),/invalid_password_hash/);
});
