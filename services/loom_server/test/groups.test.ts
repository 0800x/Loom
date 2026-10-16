import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { generateKeyPairSync, sign } from 'node:crypto';
import { GroupStore, keyPackageBinding, mlsDeviceBinding } from '../src/groups/group_store.ts';
import type { SessionInfo } from '../src/storage/sqlite_store.ts';

const wire = Buffer.from('opaque MLS data').toString('base64');
function fixture() {
  const db = new DatabaseSync(':memory:');
  db.exec(`CREATE TABLE device_key_bundles(device_id TEXT,account_id TEXT,identity_id TEXT,signing_public_key TEXT); CREATE TABLE devices(id TEXT PRIMARY KEY,account_id TEXT,revoked_at TEXT); CREATE TABLE conversations(id TEXT PRIMARY KEY,kind TEXT,title TEXT,created_at TEXT); CREATE TABLE conversation_members(conversation_id TEXT,account_id TEXT,PRIMARY KEY(conversation_id,account_id));`);
  const sessions = ['a','b','c'].map(n => ({ accountId: 'account-'+n, deviceId: 'device-'+n, identityId: 'chn:'+n.repeat(43), username: n }));
  for (const s of sessions) db.prepare('INSERT INTO devices VALUES(?,?,NULL)').run(s.deviceId,s.accountId);
  const store = new GroupStore(db);
  const keys = generateKeyPairSync('ed25519');
  const publicKey = keys.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64');
  async function publish(s: SessionInfo, id: string) {
    const p = {id,serialized:wire,expiresAt:new Date(Date.now()+86400000).toISOString(),signature:''};
    p.signature=sign(null,keyPackageBinding(s,p),keys.privateKey).toString('base64');
    await store.publish(s,p,publicKey); return p;
  }
  for (const s of sessions) db.prepare('INSERT INTO device_key_bundles VALUES(?,?,?,?)').run(s.deviceId,s.accountId,s.identityId,publicKey);
  const members = sessions.slice(0,2).map((s,i) => {
    const m={accountId:s.accountId,deviceId:s.deviceId,identityId:s.identityId,mlsSignatureKey:Buffer.alloc(32,i+1).toString('base64'),mlsSignature:'',role:i===0?'owner':'member'};
    m.mlsSignature=sign(null,mlsDeviceBinding(m),keys.privateKey).toString('base64'); return m;
  });
  async function create() {
    await publish(sessions[1],'package-b'); const claim = await store.claim(sessions[0],sessions[1].deviceId);
    const request = {operationId:'create',title:'Friends',epoch:1,members,commit:wire,welcomes:{'device-b':wire},claims:{'device-b':claim.claimId}};
    await store.create(sessions[0],'group-1',request); return request;
  }
  return {db,store,sessions,publish,members,create,publicKey,keys};
}

async function newcomer(f: ReturnType<typeof fixture>) {
  const s = f.sessions[2];
  const member = {accountId:s.accountId,deviceId:s.deviceId,identityId:s.identityId,
    role:'member',mlsSignatureKey:Buffer.alloc(32,3).toString('base64'),mlsSignature:''};
  member.mlsSignature=sign(null,mlsDeviceBinding(member),f.keys.privateKey).toString('base64');
  await f.store.publishCredential(s,member,f.publicKey);
  await f.publish(s,'package-c');
  return member;
}

test('invite capabilities are hashed, expiring, replaceable and administrator-controlled', async () => {
  const f=fixture(); try {
    await f.create();
    await assert.rejects(f.store.createInvite(f.sessions[1],'group-1',{mode:'open'}),/admin_required/);
    await assert.rejects(f.store.createInvite(f.sessions[0],'group-1',{mode:'bad'}),/invalid_group_join_mode/);
    const invite=await f.store.createInvite(f.sessions[0],'group-1',{mode:'open'});
    const stored=f.db.prepare('SELECT * FROM mls_group_invites').get()!;
    assert.notEqual(stored.token_hash,invite.token);
    assert.equal(JSON.stringify(stored).includes(invite.token),false);
    const preview=await f.store.previewInvite(f.sessions[2],invite.token);
    assert.equal(preview.title,'Friends'); assert.equal(preview.memberCount,2);
    assert.equal('members' in preview,false); assert.equal(preview.status,'none');
    const rotated=await f.store.createInvite(f.sessions[0],'group-1',{mode:'approval'});
    await assert.rejects(f.store.previewInvite(f.sessions[2],invite.token),/invite_unavailable/);
    f.db.prepare('UPDATE mls_group_invites SET expires_at=? WHERE revoked=0').run('2000-01-01T00:00:00.000Z');
    await assert.rejects(f.store.previewInvite(f.sessions[2],rotated.token),/invite_unavailable/);
    const fresh=await f.store.createInvite(f.sessions[0],'group-1',{mode:'open'});
    await f.store.revokeInvites(f.sessions[0],'group-1');
    await assert.rejects(f.store.requestJoin(f.sessions[2],fresh.token),/invite_unavailable/);
    assert.equal((await f.store.get(f.sessions[0],'group-1')).members.length,2);
  } finally { f.db.close(); }
});

test('open join is idempotent and becomes membership only through an authorized MLS commit', async () => {
  const f=fixture(); try {
    await f.create(); const member=await newcomer(f);
    const invite=await f.store.createInvite(f.sessions[0],'group-1',{mode:'open'});
    assert.deepEqual(await f.store.requestJoin(f.sessions[2],invite.token),{groupId:'group-1',status:'approved'});
    assert.equal((await f.store.requestJoin(f.sessions[2],invite.token)).status,'approved');
    assert.equal(f.db.prepare('SELECT COUNT(*) AS n FROM mls_group_join_requests').get()!.n,1);
    await assert.rejects(f.store.get(f.sessions[2],'group-1'),/not_member/);
    await assert.rejects(f.store.joinRequests(f.sessions[1],'group-1'),/admin_required/);
    const claim=await f.store.claim(f.sessions[0],member.deviceId);
    const commit={operationId:'join-c',epoch:2,title:'Friends',members:[...f.members,member],commit:wire,
      welcomes:{[member.deviceId]:wire},claims:{[member.deviceId]:claim.claimId},joinRequestDeviceId:member.deviceId};
    await f.store.send(f.sessions[0],'group-1',{operationId:'before',epoch:1,ciphertext:wire});
    const result=await f.store.commit(f.sessions[0],'group-1',1,commit);
    assert.equal(result.members.length,3);
    assert.equal((await f.store.previewInvite(f.sessions[2],invite.token)).status,'joined');
    await f.store.send(f.sessions[2],'group-1',{operationId:'after',epoch:2,ciphertext:wire});
    assert.deepEqual((await f.store.inbox(f.sessions[2],'group-1',0)).events.map(e=>e.kind),['welcome','message']);
    assert.equal((await f.store.joinRequests(f.sessions[0],'group-1')).requests.length,0);
    assert.deepEqual(await f.store.commit(f.sessions[0],'group-1',1,commit),result);
  } finally { f.db.close(); }
});

test('moderated requests cannot bypass approval, role rules, expiry or revocation', async () => {
  const f=fixture(); try {
    await f.create(); const member=await newcomer(f);
    const invite=await f.store.createInvite(f.sessions[0],'group-1',{mode:'approval'});
    assert.equal((await f.store.requestJoin(f.sessions[2],invite.token)).status,'pending');
    await assert.rejects(f.store.decideJoin(f.sessions[2],'group-1','device-c',true),/not_member/);
    const claim=await f.store.claim(f.sessions[0],member.deviceId);
    const commit={operationId:'join-c',epoch:2,title:'Friends',members:[...f.members,member],commit:wire,
      welcomes:{[member.deviceId]:wire},claims:{[member.deviceId]:claim.claimId},joinRequestDeviceId:member.deviceId};
    await assert.rejects(f.store.commit(f.sessions[0],'group-1',1,commit),/request_unavailable/);
    await f.store.decideJoin(f.sessions[0],'group-1','device-c',true);
    await assert.rejects(f.store.commit(f.sessions[0],'group-1',1,{...commit,members:[...f.members,{...member,role:'admin'}]}),/invalid_group_join_commit/);
    await f.store.revokeInvites(f.sessions[0],'group-1');
    await assert.rejects(f.store.commit(f.sessions[0],'group-1',1,commit),/request_unavailable/);
    assert.equal((await f.store.get(f.sessions[0],'group-1')).revision,1);
    assert.equal(f.db.prepare('SELECT consumed FROM mls_packages WHERE id=?').get('package-c')!.consumed,0);
    assert.equal((await f.store.joinRequests(f.sessions[0],'group-1')).requests.length,0);
  } finally { f.db.close(); }
});

test('rejected requests stay rejected on retry, and revoked devices cannot request admission', async () => {
  const f=fixture(); try {
    await f.create(); await newcomer(f);
    const invite=await f.store.createInvite(f.sessions[0],'group-1',{mode:'approval'});
    await f.store.requestJoin(f.sessions[2],invite.token);
    await f.store.decideJoin(f.sessions[0],'group-1','device-c',false);
    assert.equal((await f.store.requestJoin(f.sessions[2],invite.token)).status,'rejected');
    f.db.prepare('UPDATE devices SET revoked_at=? WHERE id=?').run(new Date().toISOString(),'device-c');
    await assert.rejects(f.store.requestJoin(f.sessions[2],invite.token),/device_revoked/);
  } finally { f.db.close(); }
});

test('create is atomic; key packages are single-use and device-scoped welcomes do not leak', async () => {
  const f=fixture(); try {
    const request=await f.create();
    assert.equal((await f.store.create(f.sessions[0],'group-1',request)).epoch,1);
    await assert.rejects(f.store.claim(f.sessions[0],'device-b'),/key_package_unavailable/);
    assert.equal((await f.store.inbox(f.sessions[1],'group-1',0)).events[0].kind,'welcome');
    assert.equal((await f.store.inbox(f.sessions[2],'group-1',0)).events.length,0);
    await assert.rejects(f.store.get(f.sessions[2],'group-1'),/group_not_member/);
  } finally {f.db.close();}
});
test('failed creation rolls back reservations and conversation metadata', async () => {
  const f=fixture();try {
    await f.publish(f.sessions[1],'p'); const claim=await f.store.claim(f.sessions[0],'device-b');
    const request={operationId:'create',title:'Friends',epoch:1,members:f.members,commit:wire,welcomes:{'device-b':wire},claims:{'device-b':'wrong'}};
    await assert.rejects(f.store.create(f.sessions[0],'g',request),/claim_expired/);
    assert.equal(f.db.prepare('SELECT COUNT(*) n FROM conversations').get()!.n,0);
    request.claims['device-b']=claim.claimId; await f.store.create(f.sessions[0],'g',request);
  }finally{f.db.close();}
});
test('message retries return the same receipt, payload collisions and stale epochs fail',async()=>{
  const f=fixture();try{
    await f.create(); const body={operationId:'message-1',epoch:1,ciphertext:wire};
    const first=await f.store.send(f.sessions[0],'group-1',body);
    assert.deepEqual(await f.store.send(f.sessions[0],'group-1',body),first);
    await assert.rejects(f.store.send(f.sessions[0],'group-1',{...body,ciphertext:Buffer.from('other').toString('base64')}),/operation_conflict/);
    await assert.rejects(f.store.send(f.sessions[0],'group-1',{...body,operationId:'stale',epoch:0}),/epoch_conflict/);
    await assert.rejects(f.store.send(f.sessions[2],'group-1',body),/group_not_member/);
    assert.equal((await f.store.inbox(f.sessions[1],'group-1',0)).events.length,2);
  }finally{f.db.close();}
});
test('concurrent commits have one CAS winner; removed member gets removal only',async()=>{
  const f=fixture();try{
    await f.create();
    const body={operationId:'remove',title:'Friends',epoch:2,members:[f.members[0]],commit:wire,welcomes:{},claims:{}};
    const outcomes=await Promise.allSettled([f.store.commit(f.sessions[0],'group-1',1,body),f.store.commit(f.sessions[0],'group-1',1,{...body,operationId:'competing'})]);
    assert.equal(outcomes.filter(r=>r.status==='fulfilled').length,1);
    await assert.rejects(f.store.send(f.sessions[1],'group-1',{operationId:'bad',epoch:2,ciphertext:wire}),/group_not_member/);
    await f.store.send(f.sessions[0],'group-1',{operationId:'new',epoch:2,ciphertext:wire});
    const events=(await f.store.inbox(f.sessions[1],'group-1',0)).events;
    assert.deepEqual(events.map(e=>e.kind),['welcome','commit']);
    assert.equal(f.db.prepare('SELECT COUNT(*) n FROM conversation_members WHERE account_id=?').get('account-b')!.n,0);
  }finally{f.db.close();}
});
test('members cannot edit membership, admins cannot promote themselves; device revocation blocks send',async()=>{
  const f=fixture();try{
    await f.create(); const body={operationId:'edit',title:'hacked',epoch:2,members:f.members,commit:wire,welcomes:{},claims:{}};
    await assert.rejects(f.store.commit(f.sessions[1],'group-1',1,body),/admin_required/);
    await f.store.commit(f.sessions[0],'group-1',1,{...body,title:'Friends',members:[f.members[0],{...f.members[1],role:'admin'}]});
    await assert.rejects(f.store.commit(f.sessions[1],'group-1',2,{...body,epoch:3,members:[{...f.members[0],role:'member'},{...f.members[1],role:'owner'}]}),/owner_required/);
    f.db.prepare('UPDATE devices SET revoked_at=? WHERE id=?').run(new Date().toISOString(),'device-b');
    await assert.rejects(f.store.send(f.sessions[1],'group-1',{operationId:'revoked',epoch:2,ciphertext:wire}),/device_revoked/);
  }finally{f.db.close();}
});
test('publication requires a signed device binding; expiry and package limits are enforced',async()=>{
  const f=fixture();try{
    const p=await f.publish(f.sessions[1],'p');
    await assert.rejects(f.store.publish(f.sessions[1],{...p,id:'altered'},f.publicKey),/binding/);
    await assert.rejects(f.store.publish(f.sessions[1],{...p,expiresAt:'2000-01-01T00:00:00.000Z'},f.publicKey),/expiry/);
    for(let n=1;n<64;n++) await f.publish(f.sessions[1],'limit-'+n);
    await assert.rejects(f.publish(f.sessions[1],'over-limit'),/key_package_limit/);
    f.db.prepare('DELETE FROM mls_packages WHERE id LIKE ?').run('limit-%');
    const claims=await Promise.allSettled([f.store.claim(f.sessions[0],'device-b'),f.store.claim(f.sessions[2],'device-b')]);
    assert.equal(claims.filter(c=>c.status==='fulfilled').length,1);
  }finally{f.db.close();}
});

test('published MLS credentials are device-bound and cannot silently rotate',async()=>{
  const f=fixture();try{
    const published=await f.store.publishCredential(f.sessions[0],f.members[0],f.publicKey);
    assert.equal(published.role,'member');
    const changed={...f.members[0],mlsSignatureKey:Buffer.alloc(32,99).toString('base64')};
    changed.mlsSignature=sign(null,mlsDeviceBinding(changed),f.keys.privateKey).toString('base64');
    await assert.rejects(f.store.publishCredential(f.sessions[0],changed,f.publicKey),/requires_new_device/);
    assert.equal((await f.store.credential(f.sessions[1],'device-a')).mlsSignatureKey,f.members[0].mlsSignatureKey);
    await assert.rejects(f.store.publishCredential(f.sessions[1],f.members[0],f.publicKey),/invalid_group_credential/);
    f.db.prepare('UPDATE devices SET revoked_at=? WHERE id=?').run(new Date().toISOString(),'device-a');
    await assert.rejects(f.store.credential(f.sessions[1],'device-a'),/credential_unavailable/);
  }finally{f.db.close();}
});


test('key package stock counts only own usable packages and rejects revoked devices', async () => {
  const f=fixture(); try {
    assert.deepEqual(await f.store.packageStock(f.sessions[1]), {available:0});
    await f.publish(f.sessions[1],'stock-1');
    await f.publish(f.sessions[1],'stock-2');
    await f.publish(f.sessions[2],'other-device');
    assert.deepEqual(await f.store.packageStock(f.sessions[1]), {available:2});
    await f.store.claim(f.sessions[0],f.sessions[1].deviceId);
    assert.deepEqual(await f.store.packageStock(f.sessions[1]), {available:1});
    f.db.prepare("UPDATE mls_packages SET claim_expires_at=? WHERE device_id=? AND claim_id IS NOT NULL").run('2000-01-01T00:00:00.000Z',f.sessions[1].deviceId);
    assert.deepEqual(await f.store.packageStock(f.sessions[1]), {available:2});
    f.db.prepare("UPDATE mls_packages SET consumed=1 WHERE id=?").run('stock-1');
    assert.deepEqual(await f.store.packageStock(f.sessions[1]), {available:1});
    f.db.prepare("UPDATE devices SET revoked_at=? WHERE id=?").run(new Date().toISOString(),f.sessions[1].deviceId);
    await assert.rejects(f.store.packageStock(f.sessions[1]), /group_device_revoked/);
  } finally { f.db.close(); }
});

test('operator metadata is redacted, paginated, and reflects device revocation', async () => {
 const f=fixture();try {
  await f.create();
  const state=await f.store.get(f.sessions[0],'group-1');
  f.db.prepare('INSERT INTO mls_groups VALUES(?,?)').run('group-2',JSON.stringify({...state,id:'group-2'}));
  const page=await f.store.adminList(1);
  assert.equal(page.groups.length,1);assert.equal(page.nextAfter,'group-1');
  assert.equal((await f.store.adminList(1,page.nextAfter)).groups[0].id,'group-2');
  await assert.rejects(f.store.adminList(0),/invalid_group_limit/);
  await assert.rejects(f.store.adminList(101),/invalid_group_limit/);
  await assert.rejects(f.store.adminList(50,'../escape'),/invalid_group_id/);
  f.db.prepare('UPDATE devices SET revoked_at=? WHERE id=?').run(new Date().toISOString(),'device-b');
  const detail=await f.store.adminGet('group-1');
  assert.equal(detail.members[1].active,false);
  assert.equal(detail.inboxRecords,1);
  for(const value of [page,detail,await f.store.diagnostics()]) {
   const text=JSON.stringify(value);
   for(const forbidden of ['mlsSignature','ciphertext','serialized','welcome','request_hash',wire]) assert.ok(!text.includes(forbidden),forbidden);
  }
  assert.equal((await f.store.diagnostics()).groupCount,2);
 }finally{f.db.close();}
});

test('pause survives restart, preserves retry receipts and commits, and uses independent CAS', async()=>{
 const f=fixture();try {
  await f.create();
  const body={operationId:'accepted',epoch:1,ciphertext:wire};
  const receipt=await f.store.send(f.sessions[0],'group-1',body);
  const paused=await f.store.adminSetPolicy('group-1',{paused:true,expectedPolicyRevision:0});
  assert.equal(paused.paused,true);assert.equal(paused.epoch,1);assert.equal(paused.revision,1);
  assert.equal((await f.store.diagnostics()).pausedGroups,1);
  assert.deepEqual(await f.store.send(f.sessions[0],'group-1',body),receipt);
  await assert.rejects(f.store.send(f.sessions[0],'group-1',{...body,operationId:'blocked'}),/group_paused/);
  await assert.rejects(f.store.adminSetPolicy('group-1',{paused:false,expectedPolicyRevision:0}),/group_policy_conflict/);
  await assert.rejects(f.store.adminSetPolicy('group-1',{paused:'false',expectedPolicyRevision:1}),/invalid_group_policy/);
  const restarted=new GroupStore(f.db);await restarted.initialize();
  assert.equal((await restarted.adminGet('group-1')).paused,true);
  assert.equal((await restarted.inbox(f.sessions[1],'group-1',0)).events.length,2);
  await restarted.commit(f.sessions[0],'group-1',1,{operationId:'rotate',title:'Friends',epoch:2,members:[f.members[0]],commit:wire,welcomes:{},claims:{}});
  const updated=await restarted.adminSetPolicy('group-1',{paused:false,expectedPolicyRevision:1});
  assert.equal(updated.epoch,2);assert.equal(updated.policyRevision,2);
  await restarted.send(f.sessions[0],'group-1',{operationId:'resumed',epoch:2,ciphertext:wire});
  await assert.rejects(restarted.send(f.sessions[1],'group-1',{operationId:'removed',epoch:2,ciphertext:wire}),/group_not_member/);
 }finally{f.db.close();}
});

test('expired-package cleanup preserves live claims, consumed tombstones and delivery history',async()=>{
 const f=fixture();try{
  await f.create();await f.publish(f.sessions[2],'expired');await f.publish(f.sessions[2],'reserved');await f.publish(f.sessions[2],'available');
  const past=new Date(Date.now()-60000).toISOString(),future=new Date(Date.now()+60000).toISOString();
  f.db.prepare('UPDATE mls_packages SET expires_at=? WHERE id=?').run(past,'expired');
  f.db.prepare('UPDATE mls_packages SET expires_at=?,claim_id=?,claim_expires_at=? WHERE id=?').run(past,'live-claim',future,'reserved');
  f.db.prepare('UPDATE mls_packages SET expires_at=? WHERE consumed=1').run(past);
  const before=await f.store.adminGet('group-1');
  assert.equal((await f.store.adminCleanupPackages()).removed,1);
  assert.equal((await f.store.adminCleanupPackages()).removed,0);
  assert.deepEqual(f.db.prepare('SELECT id FROM mls_packages ORDER BY id').all().map(r=>r.id),['available','package-b','reserved']);
  assert.deepEqual(await f.store.adminGet('group-1'),before);
  assert.equal((await f.store.diagnostics()).availableKeyPackages,1);
 }finally{f.db.close();}
});


test('operator cleanup is bounded to 1000 records per request',async()=>{
 const f=fixture();try{
  await f.store.initialize();const past=new Date(Date.now()-60000).toISOString();
  const insert=f.db.prepare('INSERT INTO mls_packages(id,device_id,account_id,payload_json,expires_at) VALUES(?,?,?,?,?)');
  for(let i=0;i<1005;i++) insert.run('expired-'+i,f.sessions[0].deviceId,f.sessions[0].accountId,'{}',past);
  assert.equal((await f.store.adminCleanupPackages()).removed,1000);
  assert.equal((await f.store.adminCleanupPackages()).removed,5);
 }finally{f.db.close();}
});


test('revoked invitation queues cannot block a fresh link and removed devices cannot claim they joined', async () => {
  const f=fixture(); try {
    await f.create(); await newcomer(f);
    const old=await f.store.createInvite(f.sessions[0],'group-1',{mode:'approval'});
    await f.store.requestJoin(f.sessions[2],old.token);
    const row=f.db.prepare('SELECT invite_hash FROM mls_group_join_requests').get()!;
    for (let i=0;i<256;i++) {
      f.db.prepare('INSERT INTO devices VALUES(?,?,NULL)').run('queued-'+i,'queued-account-'+i);
      f.db.prepare('INSERT INTO mls_group_join_requests VALUES(?,?,?,?,?,?,?)').run('group-1','queued-'+i,'queued-account-'+i,'chn:queued',row.invite_hash,'pending',new Date().toISOString());
    }
    const fresh=await f.store.createInvite(f.sessions[0],'group-1',{mode:'open'});
    assert.equal((await f.store.requestJoin(f.sessions[2],fresh.token)).status,'approved');
    f.db.prepare("UPDATE mls_group_join_requests SET status='joined' WHERE device_id='device-c'").run();
    assert.equal((await f.store.previewInvite(f.sessions[2],fresh.token)).status,'removed');
    await assert.rejects(f.store.requestJoin(f.sessions[2],fresh.token),/rejoin_requires_new_device/);
  } finally { f.db.close(); }
});
